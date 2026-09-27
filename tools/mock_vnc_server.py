#!/usr/bin/env python3
"""A small RFB 3.8 server used as the test target for vncviewer.koplugin.

There is no real VNC server available in the dev environment, so this fixture serves a
deterministic synthetic framebuffer in any of the encodings the plugin implements and logs
every client message it receives (one line per message, see ``--log``).

VNC Authentication is verified with OpenSSL's DES through ctypes -- an implementation
completely independent of the plugin's own DES, so it validates it.

The client's SetPixelFormat is honoured: the pattern is converted on the fly to any of
8/16/32 bpp, true-colour (channel maxima/shifts and byte order as requested) or, for
``true_colour=0``, to a 256-entry 3-3-2 colour map plus indices. The canonical format the Lua
client asks for (32bpp/24/LSB/true colour/255,255,255/0,8,16) keeps its exact legacy bytes.

usage: mock_vnc_server.py [--port 5900] [--width 800] [--height 600]
                          [--security none|vnc] [--password secret]
                          [--encoding raw|hextile|rre|copyrect|trle|zrle|tight|mixed]
                          [--pattern quadrants|gradient|checker] [--repaint SECONDS]
                          [--log FILE] [--resize-after N] [--once]
"""

import argparse
import base64
import binascii
import ctypes
import ctypes.util
import os
import socket
import struct
import sys
import time
import zlib

# ---------------------------------------------------------------- framing constants

RAW, COPYRECT, RRE, HEXTILE, TIGHT, TRLE, ZRLE, DESKTOP_SIZE = 0, 1, 2, 5, 7, 15, 16, -223

TIGHT_EXPLICIT_FILTER = 0x04
TIGHT_FILL = 0x08
TIGHT_JPEG = 0x09
TIGHT_NO_ZLIB = 0x0A
TIGHT_MIN_TO_COMPRESS = 12

JPEG_RECT = (8, 8, 32, 32)          # where the Tight cases put the JPEG sub-rect
JPEG_AVG = (199, 40, 120)           # decoded average of tools/tight_jpeg.b64

LOG_FH = None


def log(msg):
    line = str(msg)
    print(line, flush=True)
    if LOG_FH:
        LOG_FH.write(line + "\n")
        LOG_FH.flush()


def load_jpeg_blob():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tight_jpeg.b64")
    with open(path) as fh:
        b64 = "".join(l.strip() for l in fh if not l.startswith("#"))
    return base64.b64decode(b64)


# ---------------------------------------------------------------- DES via OpenSSL EVP
#
# VNC Authentication is verified with OpenSSL's DES -- an implementation completely
# independent of the plugin's own DES, so it validates it.
#
# NB: the low-level `DES_set_key_unchecked` symbol is a no-op under OpenSSL >= 3.0 (it
# returns 0 and leaves the key schedule untouched, verified on OpenSSL 3.6.3), so we go
# through EVP and the legacy provider instead.

class _OpenSSLDES:
    def __init__(self):
        self.lib = _load_libcrypto()
        lib = self.lib
        lib.OSSL_PROVIDER_load.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        lib.OSSL_PROVIDER_load.restype = ctypes.c_void_p
        lib.EVP_CIPHER_fetch.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
        lib.EVP_CIPHER_fetch.restype = ctypes.c_void_p
        lib.EVP_CIPHER_CTX_new.restype = ctypes.c_void_p
        lib.EVP_CIPHER_CTX_new.argtypes = []
        lib.EVP_CIPHER_CTX_free.argtypes = [ctypes.c_void_p]
        lib.EVP_CIPHER_CTX_set_padding.argtypes = [ctypes.c_void_p, ctypes.c_int]
        lib.EVP_EncryptInit_ex.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
                                           ctypes.c_char_p, ctypes.c_char_p]
        lib.EVP_EncryptUpdate.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                          ctypes.POINTER(ctypes.c_int), ctypes.c_char_p,
                                          ctypes.c_int]
        if not lib.OSSL_PROVIDER_load(None, b"legacy"):
            raise RuntimeError("could not load the OpenSSL 'legacy' provider (needed for DES)")
        self.cipher = lib.EVP_CIPHER_fetch(None, b"DES-ECB", None)
        if not self.cipher:
            raise RuntimeError("OpenSSL has no DES-ECB cipher")

    def encrypt_ecb(self, key8, data):
        """Encrypts `data` (a multiple of 8 bytes) in ECB mode with no padding."""
        lib = self.lib
        ctx = lib.EVP_CIPHER_CTX_new()
        if not ctx:
            raise RuntimeError("EVP_CIPHER_CTX_new failed")
        try:
            if lib.EVP_EncryptInit_ex(ctx, self.cipher, None, key8, None) != 1:
                raise RuntimeError("EVP_EncryptInit_ex failed")
            if lib.EVP_CIPHER_CTX_set_padding(ctx, 0) != 1:
                raise RuntimeError("EVP_CIPHER_CTX_set_padding failed")
            out = ctypes.create_string_buffer(len(data) + 8)
            outl = ctypes.c_int(0)
            if lib.EVP_EncryptUpdate(ctx, out, ctypes.byref(outl), data, len(data)) != 1:
                raise RuntimeError("EVP_EncryptUpdate failed")
            if outl.value != len(data):
                raise RuntimeError("EVP_EncryptUpdate produced %d bytes, wanted %d"
                                   % (outl.value, len(data)))
            return out.raw[:outl.value]
        finally:
            lib.EVP_CIPHER_CTX_free(ctx)


def _load_libcrypto():
    for name in (ctypes.util.find_library("crypto"), "libcrypto.so.3", "libcrypto.so"):
        if not name:
            continue
        try:
            return ctypes.CDLL(name)
        except OSError:
            continue
    raise RuntimeError("libcrypto not found")


_DES = None


def des_encrypt_ecb(key8, data):
    global _DES
    if _DES is None:
        _DES = _OpenSSLDES()
    return _DES.encrypt_ecb(key8, data)


def reverse_bits(b):
    r = 0
    for i in range(8):
        if b & (1 << i):
            r |= 1 << (7 - i)
    return r


def vnc_response(password, challenge):
    key = password.encode("utf-8")[:8].ljust(8, b"\x00")
    key = bytes(reverse_bits(b) for b in key)
    return des_encrypt_ecb(key, challenge[:16])


# ---------------------------------------------------------------- pixel format
#
# The mock always keeps its pattern in native RGB. The client's SetPixelFormat picks how it
# goes on the wire; the canonical format (the one the Lua client asks for) keeps the exact
# byte layout the mock has always served, so nothing about that case changes.

CANONICAL_FORMAT = (32, 24, 0, 1, 255, 255, 255, 0, 8, 16)


def is_canonical_format(pf):
    return tuple(pf) == CANONICAL_FORMAT


class PixelCodec:
    def __init__(self, pf):
        (self.bpp, self.depth, self.big_endian, self.true_colour,
         self.red_max, self.green_max, self.blue_max,
         self.red_shift, self.green_shift, self.blue_shift) = pf
        self.bytes_per_pixel = max(1, self.bpp // 8)
        if self.true_colour:
            sig = max(self.red_shift + self.red_max.bit_length(),
                      self.green_shift + self.green_max.bit_length(),
                      self.blue_shift + self.blue_max.bit_length())
            self.bytes_per_cpixel = max(1, (sig + 7) // 8)
        else:
            self.bytes_per_cpixel = self.bytes_per_pixel
        self.canonical = is_canonical_format(pf)
        self.byte_order = "big" if self.big_endian else "little"

    @classmethod
    def canonical(cls):
        return cls(CANONICAL_FORMAT)

    def value(self, rgb):
        """The pixel's integer value in the negotiated format."""
        r, g, b = rgb
        if not self.true_colour:                     # 3-3-2 index into the colour map
            return ((r >> 5) << 5) | ((g >> 5) << 2) | (b >> 6)
        rv = r if self.red_max == 255 else (r * self.red_max + 127) // 255
        gv = g if self.green_max == 255 else (g * self.green_max + 127) // 255
        bv = b if self.blue_max == 255 else (b * self.blue_max + 127) // 255
        return (rv << self.red_shift) | (gv << self.green_shift) | (bv << self.blue_shift)

    def _encode(self, rgb, nbytes):
        full = self.value(rgb).to_bytes(self.bytes_per_pixel, self.byte_order)
        if nbytes >= self.bytes_per_pixel:
            return full
        # A CPIXEL is the PIXEL with its padding bytes removed.
        return full[:nbytes] if self.byte_order == "little" else full[-nbytes:]

    def pixel(self, rgb):
        if self.canonical:
            return bytes(rgb) + b"\x00" * (self.bytes_per_pixel - 3)
        return self._encode(rgb, self.bytes_per_pixel)

    def cpixel(self, rgb):
        if self.canonical:
            return bytes(rgb)
        return self._encode(rgb, self.bytes_per_cpixel)


def colour_map_message():
    """SetColorMapEntries with 256 3-3-2 entries (16-bit values, so client >>8 is exact)."""
    out = bytearray(bytes([1, 0]) + struct.pack(">HH", 0, 256))
    for i in range(256):
        r = ((i >> 5) & 0x7) * 255 // 7
        g = ((i >> 2) & 0x7) * 255 // 7
        b = (i & 0x3) * 255 // 3
        out += struct.pack(">HHH", r * 257, g * 257, b * 257)
    return bytes(out)


# ---------------------------------------------------------------- synthetic framebuffer

class Framebuffer:
    def __init__(self, pattern, w, h):
        self.pattern = pattern
        self.w = w
        self.h = h
        self.codec = PixelCodec.canonical()

    def pixel(self, rgb):
        return self.codec.pixel(rgb)

    def cpixel(self, rgb):
        return self.codec.cpixel(rgb)

    def pix(self, x, y):
        p = self.pattern
        if p == "gradient":
            return (x % 256, y % 256, (x ^ y) % 256)
        if p == "quadrants":
            left, top = x < self.w // 2, y < self.h // 2
            if top and left:
                return (255, 0, 0)
            if top:
                return (0, 255, 0)
            if left:
                return (0, 0, 255)
            return (255, 255, 255)
        if p == "checker":
            c = 255 if ((x // 32 + y // 32) % 2 == 0) else 0
            return (c, c, c)
        raise ValueError("unknown pattern " + p)

    def rgb24(self, x0, y0, w, h):
        """Packed [R, G, B] rows."""
        out = bytearray()
        for y in range(y0, y0 + h):
            for x in range(x0, x0 + w):
                out += bytes(self.pix(x, y))
        return bytes(out)

    def pixel32(self, x0, y0, w, h):
        """Packed PIXELs for the negotiated format."""
        out = bytearray()
        for y in range(y0, y0 + h):
            for x in range(x0, x0 + w):
                out += self.pixel(self.pix(x, y))
        return bytes(out)


# ---------------------------------------------------------------- encoders

def encode_raw(fb, x0, y0, w, h):
    return fb.pixel32(x0, y0, w, h)


def encode_rre(fb, x0, y0, w, h):
    bg = fb.pix(x0, y0)
    subrects = []
    for y in range(y0, y0 + h):
        x = x0
        while x < x0 + w:
            col = fb.pix(x, y)
            if col == bg:
                x += 1
                continue
            start = x
            while x < x0 + w and fb.pix(x, y) == col:
                x += 1
            subrects.append((start - x0, y - y0, x - start, 1, col))
    out = bytearray(struct.pack(">I", len(subrects)))
    out += fb.pixel(bg)
    for (sx, sy, sw, sh, col) in subrects:
        out += fb.pixel(col) + struct.pack(">HHHH", sx, sy, sw, sh)
    return bytes(out)


class HextileEncoder:
    """Encodes 16x16 tiles, carrying background/foreground like a real server would."""

    def __init__(self, fb):
        self.fb = fb
        self.prev_bg = None
        self.prev_bg_ok = False
        self.prev_fg = None
        self.prev_fg_ok = False
        self.tile_index = 0

    def encode(self, x0, y0, w, h):
        out = bytearray()
        for ty in range(0, h, 16):
            th = min(16, h - ty)
            for tx in range(0, w, 16):
                tw = min(16, w - tx)
                self.tile_index += 1
                out += self._tile(x0 + tx, y0 + ty, tw, th)
        return bytes(out)

    def _tile(self, x0, y0, tw, th):
        tile = [[self.fb.pix(x0 + cx, y0 + cy) for cx in range(tw)] for cy in range(th)]
        bg = tile[0][0]
        runs = []
        for cy in range(th):
            cx = 0
            while cx < tw:
                col = tile[cy][cx]
                if col == bg:
                    cx += 1
                    continue
                start = cx
                while cx < tw and tile[cy][cx] == col:
                    cx += 1
                runs.append((start, cy, cx - start, col))

        # Force a raw tile every 5th tile so the client's raw path is exercised too.
        if self.tile_index % 5 == 4 or len(runs) > 200:
            out = bytearray([1])
            for cy in range(th):
                for cx in range(tw):
                    out += self.fb.pixel(tile[cy][cx])
            self.prev_bg_ok = False
            self.prev_fg_ok = False
            return bytes(out)

        mask = 0
        out = bytearray()
        if bg == self.prev_bg and self.prev_bg_ok:
            pass
        else:
            mask |= 2
            out += self.fb.pixel(bg)
            self.prev_bg = bg
        self.prev_bg_ok = True

        colors = set(r[3] for r in runs)
        if len(colors) == 1:
            fg = next(iter(colors))
            if not (fg == self.prev_fg and self.prev_fg_ok):
                mask |= 4
                out += self.fb.pixel(fg)
                self.prev_fg = fg
            self.prev_fg_ok = True
            if runs:
                mask |= 8
                out += bytes([len(runs)])
                for (sx, sy, sw, _) in runs:
                    out += bytes([(sx << 4) | sy, ((sw - 1) << 4) | 0])
        else:
            if runs:
                mask |= 8 | 16
                out += bytes([len(runs)])
                for (sx, sy, sw, col) in runs:
                    out += self.fb.pixel(col)
                    out += bytes([(sx << 4) | sy, ((sw - 1) << 4) | 0])
                self.prev_fg_ok = False
        return bytes([mask]) + bytes(out)


class TileEncoder:
    """TRLE (16x16 tiles) and ZRLE (64x64 tiles) encoder."""

    def __init__(self, fb, tile_size, allow_reuse):
        self.fb = fb
        self.tile = tile_size
        self.allow_reuse = allow_reuse
        self.prev_palette = None
        self.prev_palette_ok = False
        self.tile_index = 0
        self.zobj = zlib.compressobj(6)

    def encode(self, x0, y0, w, h):
        out = bytearray()
        for ty in range(0, h, self.tile):
            th = min(self.tile, h - ty)
            for tx in range(0, w, self.tile):
                tw = min(self.tile, w - tx)
                self.tile_index += 1
                out += self._tile(x0 + tx, y0 + ty, tw, th)
        return bytes(out)

    @staticmethod
    def _runs(flat):
        runs = []
        i = 0
        while i < len(flat):
            col = flat[i]
            j = i
            while j < len(flat) and flat[j] == col:
                j += 1
            runs.append((col, j - i))
            i = j
        return runs

    def _tile(self, x0, y0, tw, th):
        flat = []
        for cy in range(th):
            for cx in range(tw):
                flat.append(self.fb.pix(x0 + cx, y0 + cy))
        distinct = sorted(set(flat))
        if len(distinct) == 1:
            return bytes([1]) + self.fb.cpixel(distinct[0])

        if len(distinct) <= 16:
            palette = distinct
            can_reuse = self.allow_reuse and palette == self.prev_palette and self.prev_palette_ok
            idx = {c: i for i, c in enumerate(palette)}
            runs = [(idx[c], n) for (c, n) in self._runs(flat)]
            # 0 = packed palette, 1 = packed reuse, 2 = palette RLE, 3 = palette RLE reuse
            choice = self.tile_index % 4
            if choice == 1 and not can_reuse:
                choice = 0
            if choice == 3 and not can_reuse:
                choice = 2
            if choice == 0:
                self.prev_palette = palette
                self.prev_palette_ok = True
                return bytes([len(palette)]) + b"".join(self.fb.cpixel(c) for c in palette) \
                    + self._packed(tw, th, palette, flat)
            if choice == 1:
                return bytes([127]) + self._packed(tw, th, palette, flat)
            self.prev_palette = palette
            self.prev_palette_ok = True
            if choice == 3:
                return bytes([129]) + self._palette_rle(runs)
            # 130..255: the palette follows the subencoding byte, then the runs.
            return bytes([128 + len(palette)]) + b"".join(self.fb.cpixel(c) for c in palette) \
                + self._palette_rle(runs)

        # Too many colours for a palette: alternate raw and plain RLE.
        if self.tile_index % 2 == 0:
            return bytes([0]) + b"".join(self.fb.cpixel(c) for c in flat)
        runs = self._runs(flat)
        out = bytearray([128])
        for (col, n) in runs:
            out += self.fb.cpixel(col)
            out += self._run_length(n)
        return bytes(out)

    def _packed(self, tw, th, palette, flat):
        idx = {c: i for i, c in enumerate(palette)}
        psize = len(palette)
        bpp = 1 if psize == 2 else (2 if psize <= 4 else 4)
        out = bytearray()
        for cy in range(th):
            row = [idx[flat[cy * tw + cx]] for cx in range(tw)]
            bits = []
            for v in row:
                for b in range(bpp - 1, -1, -1):
                    bits.append((v >> b) & 1)
            while len(bits) % 8:
                bits.append(0)
            for i in range(0, len(bits), 8):
                byte = 0
                for b in bits[i:i + 8]:
                    byte = (byte << 1) | b
                out.append(byte)
        return bytes(out)

    @staticmethod
    def _run_length(n):
        body = bytearray()
        rem = n - 1
        while rem >= 255:
            body.append(255)
            rem -= 255
        body.append(rem)
        return bytes(body)

    def _palette_rle(self, runs):
        out = bytearray()
        for (i, n) in runs:
            if n == 1:
                out.append(i)
            else:
                out.append(i + 128)
                out += self._run_length(n)
        return bytes(out)

    def encode_zrle(self, x0, y0, w, h):
        tiled = self.encode(x0, y0, w, h)
        data = self.zobj.compress(tiled) + self.zobj.flush(zlib.Z_SYNC_FLUSH)
        return struct.pack(">I", len(data)) + data


class TightEncoder:
    """libvncclient-style Tight encoder (fill / jpeg / no-zlib / copy / palette / gradient)."""

    def __init__(self, fb, jpeg_blob):
        self.fb = fb
        self.jpeg_blob = jpeg_blob
        self.zobjs = [zlib.compressobj(6) for _ in range(4)]
        self.reset_pending = [False] * 4

    @staticmethod
    def _compact_len(n):
        if n < 0x80:
            return bytes([n])
        if n < 0x4000:
            return bytes([0x80 | (n & 0x7F), (n >> 7) & 0x7F])
        return bytes([0x80 | (n & 0x7F), 0x80 | ((n >> 7) & 0x7F), (n >> 14) & 0xFF])

    def _compress(self, stream_id, data):
        """Returns (reset_flag, compressed_bytes); the stream is flushed, never finished."""
        reset = self.reset_pending[stream_id]
        if reset:
            self.zobjs[stream_id] = zlib.compressobj(6)
            self.reset_pending[stream_id] = False
        comp = self.zobjs[stream_id].compress(data) + self.zobjs[stream_id].flush(zlib.Z_SYNC_FLUSH)
        return reset, comp

    def _ctl(self, sub, stream_id=0, reset=False):
        """One Tight control byte: high nibble = subencoding, low nibble = zlib reset flags."""
        b = ((sub & 0x0F) << 4) | (stream_id & 0x03)
        if reset:
            b |= 1 << (stream_id & 0x03)
        return bytes([b])

    def fill(self, x0, y0, w, h):
        return self._ctl(TIGHT_FILL) + self.fb.cpixel(self.fb.pix(x0, y0))

    def jpeg(self, x0, y0, w, h):
        return self._ctl(TIGHT_JPEG) + self._compact_len(len(self.jpeg_blob)) + self.jpeg_blob

    def no_zlib(self, x0, y0, w, h):
        raw = self.fb.rgb24(x0, y0, w, h)
        return self._ctl(TIGHT_NO_ZLIB) + self._compact_len(len(raw)) + raw

    def copy(self, x0, y0, w, h, stream_id=0, explicit=False, small=False):
        raw = self.fb.rgb24(x0, y0, w, h)
        high = stream_id | (TIGHT_EXPLICIT_FILTER if explicit else 0)
        if small or (w * 3) * h < TIGHT_MIN_TO_COMPRESS:
            return self._ctl(high) + (bytes([0]) if explicit else b"") + raw
        reset, comp = self._compress(stream_id, raw)
        return self._ctl(high, stream_id, reset=reset) + (bytes([0]) if explicit else b"") \
            + self._compact_len(len(comp)) + comp

    def reset_stream(self, stream_id):
        self.reset_pending[stream_id] = True

    def gradient(self, x0, y0, w, h, stream_id=2):
        # Mirrors libvncclient's FilterGradient24 (BPP=32, cutZeros): `prev`/`cur` hold the
        # *reconstructed* pixel values, and only the deltas go on the wire.
        data = bytearray()
        prev = [0] * (w * 3)
        for y in range(y0, y0 + h):
            cur = [0] * (w * 3)
            for x in range(w):
                for c in range(3):
                    v = self.fb.pix(x0 + x, y)[c]
                    if x == 0:
                        est = prev[c]
                    else:
                        est = prev[x * 3 + c] + cur[(x - 1) * 3 + c] - prev[(x - 1) * 3 + c]
                        est = max(0, min(255, est))
                    data.append((v - est) & 0xFF)
                    cur[x * 3 + c] = v
            prev = cur
        reset, comp = self._compress(stream_id, bytes(data))
        return self._ctl(stream_id | TIGHT_EXPLICIT_FILTER, stream_id, reset=reset) + bytes([2]) \
            + self._compact_len(len(comp)) + comp

    def palette(self, x0, y0, w, h, stream_id=1):
        pixels = [self.fb.pix(x0 + x, y0 + y) for y in range(h) for x in range(w)]
        distinct = sorted(set(pixels))
        n = max(2, min(256, len(distinct)))
        palette = distinct[:n]
        while len(palette) < n:
            palette.append(palette[-1])
        idx = {c: i for i, c in enumerate(palette)}
        if n == 2:
            data = bytearray()
            for y in range(h):
                bits = [idx[pixels[y * w + x]] for x in range(w)]
                while len(bits) % 8:
                    bits.append(0)
                for i in range(0, len(bits), 8):
                    byte = 0
                    for b in bits[i:i + 8]:
                        byte = (byte << 1) | b
                    data.append(byte)
        else:
            data = bytearray(idx[p] for p in pixels)
        reset, comp = self._compress(stream_id, bytes(data))
        return self._ctl(stream_id | TIGHT_EXPLICIT_FILTER, stream_id, reset=reset) + bytes([1]) \
            + bytes([n - 1]) + b"".join(self.fb.cpixel(c) for c in palette) \
            + self._compact_len(len(comp)) + comp


# ---------------------------------------------------------------- connection

class Connection:
    def __init__(self, sock):
        self.sock = sock
        self.buf = b""

    def read_exact(self, n):
        while len(self.buf) < n:
            data = self.sock.recv(65536)
            if not data:
                raise EOFError("client closed")
            self.buf += data
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def try_message(self):
        """Returns (type, payload_bytes) or None when no complete message is buffered."""
        if not self.buf:
            self.buf += self._poll()
            if not self.buf:
                return None
        t = self.buf[0]
        if t == 0:
            need = 20
        elif t == 2:
            if len(self.buf) < 4:
                return None
            need = 4 + 4 * struct.unpack(">H", self.buf[2:4])[0]
        elif t in (3, 4):
            need = 10 if t == 3 else 8
        elif t == 5:
            need = 6
        elif t == 6:
            if len(self.buf) < 8:
                return None
            need = 8 + struct.unpack(">I", self.buf[4:8])[0]
        else:
            raise ValueError("unknown client message type %d" % t)
        if len(self.buf) < need:
            return None
        out, self.buf = self.buf[:need], self.buf[need:]
        return t, out

    def _poll(self):
        import select
        r, _, _ = select.select([self.sock], [], [], 0.02)
        if not r:
            return b""
        data = self.sock.recv(65536)
        if not data:
            raise EOFError("client closed")
        return data


class MockServer:
    def __init__(self, args):
        self.args = args
        self.fb = Framebuffer(args.pattern, args.width, args.height)
        self.requests = 0
        self.resize_sent = False
        self.repaint_pos = 0
        self.last_repaint = 0.0
        self.pending_incremental = False
        self.jpeg_blob = load_jpeg_blob()
        self.advertised = set()

    # ------------------------------------------------------------ handshake

    def handshake(self, conn):
        log("CONNECT")
        conn.sock.sendall(b"RFB 003.008\n")
        version = conn.read_exact(12)
        if not version.startswith(b"RFB 003.00"):
            raise ValueError("bad client version %r" % version)
        client_minor = int(version[8:11])

        if self.args.security == "vnc":
            conn.sock.sendall(bytes([2, 1, 2]))
            chosen = conn.read_exact(1)[0]
            if chosen == 0:
                raise ValueError("client refused all security types")
            if chosen != 2:
                raise ValueError("client chose security type %d, expected 2" % chosen)
            challenge = os.urandom(16)
            conn.sock.sendall(challenge)
            resp = conn.read_exact(16)
            if resp == vnc_response(self.args.password, challenge):
                conn.sock.sendall(struct.pack(">I", 0))
                log("AUTH ok")
            else:
                conn.sock.sendall(struct.pack(">I", 1))
                reason = b"Authentication failure"
                conn.sock.sendall(struct.pack(">I", len(reason)) + reason)
                log("AUTH failed")
                raise EOFError("auth failed")
        else:
            conn.sock.sendall(bytes([1, 1]))
            chosen = conn.read_exact(1)[0]
            if chosen != 1:
                raise ValueError("client chose security type %d, expected 1" % chosen)
            if client_minor >= 8:
                conn.sock.sendall(struct.pack(">I", 0))
            log("AUTH ok")

        shared = conn.read_exact(1)[0]
        pf = struct.pack(">BBBBHHHBBB3x", 32, 24, 0, 1, 255, 255, 255, 0, 8, 16)
        name = b"mock-vnc"
        conn.sock.sendall(struct.pack(">HH", self.fb.w, self.fb.h) + pf
                          + struct.pack(">I", len(name)) + name)
        return shared

    # ------------------------------------------------------------ message handling

    def serve(self, conn):
        hextile = HextileEncoder(self.fb)
        trle = TileEncoder(self.fb, 16, allow_reuse=True)
        zrle = TileEncoder(self.fb, 64, allow_reuse=False)
        tight = TightEncoder(self.fb, self.jpeg_blob)
        encoders = {"hextile": hextile, "trle": trle, "zrle": zrle, "tight": tight}
        advertised = set()
        encoding_checked = False

        while True:
            if (self.args.repaint and self.pending_incremental
                    and time.monotonic() - self.last_repaint >= self.args.repaint):
                self.send_repaint(conn, zrle, trle, hextile, tight)
                self.last_repaint = time.monotonic()

            msg = conn.try_message()
            if msg is None:
                continue
            t, data = msg
            if t == 0:
                bpp, depth, big, true = struct.unpack(">BBBB", data[4:8])
                rmax, gmax, bmax = struct.unpack(">HHH", data[8:14])
                rshift, gshift, bshift = struct.unpack(">BBB", data[14:17])
                log("INPUT SetPixelFormat bpp=%d red_shift=%d green_shift=%d blue_shift=%d"
                    % (bpp, rshift, gshift, bshift))
                if bpp not in (8, 16, 32):
                    raise ValueError("unexpected pixel format %r" % (data[4:20],))
                pf = (bpp, depth, big, true, rmax, gmax, bmax, rshift, gshift, bshift)
                # Honour the requested format. The canonical one (what the Lua client asks
                # for) keeps the exact legacy byte layout -- PixelCodec special-cases it.
                self.fb.codec = (PixelCodec.canonical() if is_canonical_format(pf)
                                 else PixelCodec(pf))
                if not true:
                    conn.sock.sendall(colour_map_message())
            elif t == 2:
                count = struct.unpack(">H", data[2:4])[0]
                encs = list(struct.unpack(">%di" % count, data[4:4 + 4 * count]))
                advertised = set(encs)
                self.advertised = advertised
                log("INPUT SetEncodings %s" % ",".join(str(e) for e in encs))
                self.check_encodings(advertised)
                encoding_checked = True
            elif t == 3:
                inc, x, y, w, h = struct.unpack(">BHHHH", data[1:10])
                log("INPUT FramebufferUpdateRequest incremental=%d x=%d y=%d w=%d h=%d"
                    % (inc, x, y, w, h))
                if not encoding_checked:
                    raise ValueError("client requested an update before SetEncodings")
                self.requests += 1
                if self.args.resize_after and self.requests == self.args.resize_after:
                    self.send_resize(conn)
                    self.pending_incremental = False
                elif inc:
                    self.pending_incremental = True
                    if not self.args.repaint:
                        self.pending_incremental = False
                else:
                    self.pending_incremental = False
                    self.send_full(conn, x, y, w, h, encoders)
            elif t == 4:
                down = data[1]
                keysym = struct.unpack(">I", data[4:8])[0]
                log("INPUT KeyEvent down=%d keysym=0x%x" % (down, keysym))
            elif t == 5:
                mask = data[1]
                x, y = struct.unpack(">HH", data[2:6])
                log("INPUT PointerEvent mask=%d x=%d y=%d" % (mask, x, y))
            elif t == 6:
                length = struct.unpack(">I", data[4:8])[0]
                log("INPUT ClientCutText len=%d" % length)

    def check_encodings(self, advertised):
        need = {
            "raw": [RAW], "rre": [RRE], "hextile": [HEXTILE], "trle": [TRLE],
            "zrle": [ZRLE], "tight": [TIGHT], "copyrect": [COPYRECT],
            "mixed": [RAW, RRE, HEXTILE, TRLE, ZRLE],
        }.get(self.args.encoding, [])
        if self.args.resize_after:
            need = need + [DESKTOP_SIZE]
        missing = [e for e in need if e not in advertised]
        if missing:
            raise ValueError("client did not advertise %r (got %r)" % (missing, sorted(advertised)))

    # ------------------------------------------------------------ updates

    def _rect(self, enc, x, y, w, h, encoders):
        if enc == RAW:
            payload = encode_raw(self.fb, x, y, w, h)
        elif enc == RRE:
            payload = encode_rre(self.fb, x, y, w, h)
        elif enc == HEXTILE:
            payload = encoders["hextile"].encode(x, y, w, h)
        elif enc == TRLE:
            payload = encoders["trle"].encode(x, y, w, h)
        elif enc == ZRLE:
            payload = encoders["zrle"].encode_zrle(x, y, w, h)
        elif enc == TIGHT:
            payload = encoders["tight"].copy(x, y, w, h)
        else:
            raise ValueError("no encoder for %d" % enc)
        return struct.pack(">HHHHi", x, y, w, h, enc) + payload

    def send_full(self, conn, x, y, w, h, encoders):
        enc = self.args.encoding
        rects = []
        if enc == "copyrect":
            # Observable CopyRect: fill the left part, then shift it right by 64 pixels.
            # The source rectangle overlaps the destination, so a naive forward copy
            # corrupts the result -- the client must copy through a snapshot.
            shift = 64
            if self.fb.w <= 2 * shift:
                raise ValueError("framebuffer too narrow for the CopyRect case")
            rects.append(struct.pack(">HHHHi", 0, 0, self.fb.w - shift, self.fb.h, RAW)
                         + encode_raw(self.fb, 0, 0, self.fb.w - shift, self.fb.h))
            rects.append(struct.pack(">HHHHi", shift, 0, self.fb.w - shift, self.fb.h, COPYRECT)
                         + struct.pack(">HH", 0, 0))
        elif enc == "tight":
            rects += self._tight_rects(encoders["tight"])
        elif enc == "mixed":
            rects += self._mixed_rects(encoders)
        else:
            eid = {"raw": RAW, "rre": RRE, "hextile": HEXTILE, "trle": TRLE, "zrle": ZRLE}[enc]
            rects.append(self._rect(eid, x, y, w, h, encoders))
        conn.sock.sendall(bytes([0, 0]) + struct.pack(">H", len(rects)) + b"".join(rects))

    def _tight_rects(self, tight):
        rects = []
        fw, fh = self.fb.w, self.fb.h
        jx, jy, jw, jh = JPEG_RECT
        if fw < jx + jw or fh < jy + jh:
            raise ValueError("framebuffer too small for the Tight JPEG rect")
        # Copy filter, with a zlib stream reset on the first rect.
        tight.reset_stream(0)
        rects.append(struct.pack(">HHHHi", 0, 0, fw, fh, TIGHT) + tight.copy(0, 0, fw, fh, stream_id=0))
        # Explicit gradient filter.
        rects.append(struct.pack(">HHHHi", fw - 24, 8, 24, 16, TIGHT)
                     + tight.gradient(fw - 24, 8, 24, 16))
        # Explicit palette filter (1-bit or 8-bit depending on the region).
        rects.append(struct.pack(">HHHHi", fw - 16, fh - 16, 16, 16, TIGHT)
                     + tight.palette(fw - 16, fh - 16, 16, 16))
        # No-zlib (uncompressed) subencoding.
        rects.append(struct.pack(">HHHHi", 4, fh - 10, 20, 10, TIGHT) + tight.no_zlib(4, fh - 10, 20, 10))
        # A tiny rect that takes the "too small to compress" path (< 12 bytes).
        rects.append(struct.pack(">HHHHi", 0, fh - 1, 2, 1, TIGHT) + tight.copy(0, fh - 1, 2, 1, small=True))
        # Fill, when the JPEG rect happens to be uniform.
        if len(set(self.fb.pix(x, y) for x in range(jx, jx + jw) for y in range(jy, jy + jh))) == 1:
            rects.append(struct.pack(">HHHHi", jx, jy, jw, jh, TIGHT) + tight.fill(jx, jy, jw, jh))
        # JPEG last, so its (lossy) content is what the client ends up showing there.
        rects.append(struct.pack(">HHHHi", jx, jy, jw, jh, TIGHT) + tight.jpeg(jx, jy, jw, jh))
        log("JPEGRECT x=%d y=%d w=%d h=%d r=%d g=%d b=%d"
            % (jx, jy, jw, jh, JPEG_AVG[0], JPEG_AVG[1], JPEG_AVG[2]))
        return rects

    def _mixed_rects(self, encoders):
        plan = [e for e in (RAW, RRE, HEXTILE, TRLE, ZRLE, TIGHT) if e in self.advertised]
        band = max(1, self.fb.h // len(plan))
        rects = []
        y = 0
        for i, eid in enumerate(plan):
            h = self.fb.h - y if i == len(plan) - 1 else min(band, self.fb.h - y)
            if h <= 0:
                break
            rects.append(self._rect(eid, 0, y, self.fb.w, h, encoders))
            y += h
        return rects

    def send_resize(self, conn):
        self.fb.w += 32
        self.fb.h += 16
        log("RESIZE %d %d" % (self.fb.w, self.fb.h))
        conn.sock.sendall(bytes([0, 0]) + struct.pack(">H", 1)
                          + struct.pack(">HHHHi", 0, 0, self.fb.w, self.fb.h, DESKTOP_SIZE))
        self.resize_sent = True

    def send_repaint(self, conn, zrle, trle, hextile, tight):
        box = 40
        maxx = max(1, self.fb.w - box)
        maxy = max(1, self.fb.h - box)
        x = (self.repaint_pos * 16) % maxx
        y = (self.repaint_pos * 16) % maxy
        self.repaint_pos += 1
        self.pending_incremental = False
        encoders = {"hextile": hextile, "trle": trle, "zrle": zrle, "tight": tight}
        eid = {"raw": RAW, "rre": RRE, "hextile": HEXTILE, "trle": TRLE,
               "zrle": ZRLE, "tight": TIGHT, "mixed": RAW,
               "copyrect": RAW}[self.args.encoding]
        rect = self._rect(eid, x, y, box, box, encoders)
        conn.sock.sendall(bytes([0, 0]) + struct.pack(">H", 1) + rect)
        log("REPAINT x=%d y=%d" % (x, y))


def main():
    global LOG_FH
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=5900)
    ap.add_argument("--width", type=int, default=800)
    ap.add_argument("--height", type=int, default=600)
    ap.add_argument("--security", choices=["none", "vnc"], default="none")
    ap.add_argument("--password", default="secret")
    ap.add_argument("--encoding", default="raw",
                    choices=["raw", "hextile", "rre", "copyrect", "trle", "zrle", "tight", "mixed"])
    ap.add_argument("--pattern", default="gradient",
                    choices=["quadrants", "gradient", "checker"])
    ap.add_argument("--repaint", type=float, default=0)
    ap.add_argument("--log", default=None)
    ap.add_argument("--resize-after", type=int, default=0)
    ap.add_argument("--once", action="store_true", help="exit after the first connection")
    args = ap.parse_args()

    if args.log:
        LOG_FH = open(args.log, "a")

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", args.port))
    srv.listen(4)
    log("LISTENING port=%d" % args.port)

    while True:
        sock, _ = srv.accept()
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        conn = Connection(sock)
        try:
            server = MockServer(args)
            server.handshake(conn)
            server.serve(conn)
        except (EOFError, ConnectionResetError, BrokenPipeError, OSError) as exc:
            log("DISCONNECT (%s)" % exc)
        except Exception as exc:  # protocol/encoder bug: make it loud
            log("ERROR %s: %s" % (type(exc).__name__, exc))
            if args.once:
                raise
        finally:
            try:
                sock.close()
            except OSError:
                pass
        if args.once:
            break
        if LOG_FH:
            LOG_FH.flush()


if __name__ == "__main__":
    sys.exit(main())

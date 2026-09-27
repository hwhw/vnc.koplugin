#!/usr/bin/env python3
"""An independent RFB 3.8 client used as the test target for the plugin's VNC *server*.

This is the mirror image of tools/mock_vnc_server.py: it speaks RFB 3.8 as a client
(version/security handshake including VNC Authentication via OpenSSL's DES through
ctypes), sends SetPixelFormat/SetEncodings/FramebufferUpdateRequest, decodes the rectangles
it receives with its own decoders (Raw, CopyRect, RRE, Hextile, TRLE, ZRLE, Tight) into an
RGB24 framebuffer, and can drive the server with pointer/key/cut-text input.

It is self-checking: --expect-pattern / --expect-width / --expect-height make it a
self-contained assertion tool, and it prints one line of JSON on exit summarising the
decoded framebuffer (including a pixel SHA-256, so two clients' views can be compared).

usage: mock_vnc_client.py [--host 127.0.0.1] [--port 5900] [--security none|vnc]
                          [--password SECRET] [--encoding raw|rre|hextile|zrle|trle|tight]
                          [--encodings LIST] [--bpp N] [--depth N] [--red-shift N]
                          [--green-shift N] [--blue-shift N] [--red-max N] [--green-max N]
                          [--blue-max N] [--true-colour 0|1] [--requests N]
                          [--continuous-updates] [--linger SECONDS] [--probe X,Y] [--frame FILE.png]
                          [--expect-pattern NAME|none] [--expect-width W] [--expect-height H]
                          [--pointer X,Y:MASK] [--key KEYSYM:DOWN] [--cuttext TEXT]
                          [--log FILE] [--timeout SECONDS]

--encoding announces that one encoding (raw 0, rre 2, hextile 5, trle 15, zrle 16, tight 7);
--encodings overrides it with an explicit comma-separated list (e.g. 16,5,2,0). Without either
the client announces ZRLE, TRLE, Hextile, RRE, Raw and DesktopSize, in that order.

--bpp 8 without any explicit format option requests a non-true-colour (colour-map) 8bpp
format, so the server's SetColorMapEntries is exercised and applied to the decoded indices.

--pointer/--key/--cuttext actions are sent --linger seconds after the first decoded
FramebufferUpdate, 0.3s apart, and then the client exits 0. The last stdout line is always a
single JSON object: {"ok", "error", "width", "height", "encoding", "bpp", "updates", "rects",
"pixel_sha256", "probes", "frame_png", "continuous_updates", "pushed_updates"}. Exit status is
0 when ok, 1 otherwise (also on timeout), with the error also on stderr.

--continuous-updates switches the client to the Continuous Updates extension: right after the
first decoded update it sends EnableContinuousUpdates (client message 150) for the whole
framebuffer and then asks for nothing at all, so every later FramebufferUpdate has to be
pushed by the server (a screen change on the server side is what produces one). It stays
connected until at least one such pushed update arrives, and fails - exit 1 - if none does
within --linger (+ --timeout), i.e. if the server ignores the extension. The updates this
client was answered are counted in "updates"; the pushed ones in "pushed_updates".

Not implemented: TLS/VeNCrypt/SASL security types, and Tight's PNG sub-encoding (the plugin
never advertises TurboVNC's PNG pseudo-encoding, so a conforming server never sends it).
"""

import argparse
import ctypes
import ctypes.util
import hashlib
import io
import json
import os
import select
import socket
import struct
import sys
import time
import zlib

try:
    from PIL import Image
except ImportError:  # only needed for --frame and the Tight JPEG sub-encoding
    Image = None

# ---------------------------------------------------------------- framing constants

RAW, COPYRECT, RRE, HEXTILE, TIGHT, TRLE, ZRLE = 0, 1, 2, 5, 7, 15, 16
DESKTOP_SIZE, LASTRECT = -223, -224

ENCODING_IDS = {"raw": RAW, "copyrect": COPYRECT, "rre": RRE, "hextile": HEXTILE,
                "tight": TIGHT, "trle": TRLE, "zrle": ZRLE}
ENCODING_NAMES = {RAW: "raw", COPYRECT: "copyrect", RRE: "rre", HEXTILE: "hextile",
                  TIGHT: "tight", TRLE: "trle", ZRLE: "zrle",
                  DESKTOP_SIZE: "desktopsize", LASTRECT: "lastrect"}

TIGHT_EXPLICIT_FILTER = 0x04
TIGHT_FILL = 0x08
TIGHT_JPEG = 0x09
TIGHT_NO_ZLIB = 0x0A
TIGHT_MIN_TO_COMPRESS = 12

DEFAULT_ENCODINGS = [ZRLE, TRLE, HEXTILE, RRE, RAW, DESKTOP_SIZE]
ACTION_INTERVAL = 0.3

LOG_FH = None


def log(msg):
    line = str(msg)
    print(line, flush=True)
    if LOG_FH:
        LOG_FH.write(line + "\n")
        LOG_FH.flush()


class ProtocolError(Exception):
    pass


class LingerDone(Exception):
    pass


# ---------------------------------------------------------------- DES via OpenSSL EVP
#
# VNC Authentication needs DES-ECB over the 16-byte challenge with the password bytes
# bit-reversed as the key. OpenSSL is used deliberately: it is an implementation completely
# independent of the plugin's hand-rolled FFI DES, so this cross-validates it.
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
    """The 16-byte VNC Authentication reply for `challenge`."""
    key = password.encode("utf-8")[:8].ljust(8, b"\x00")
    key = bytes(reverse_bits(b) for b in key)
    return des_encrypt_ecb(key, challenge)


# ---------------------------------------------------------------- framebuffer

class Framebuffer:
    """The decoded remote framebuffer, always packed RGB24 (row-major, 3 bytes/pixel)."""

    def __init__(self, w, h):
        self.w = w
        self.h = h
        self.data = bytearray(w * h * 3)

    def resize(self, w, h):
        self.w = w
        self.h = h
        self.data = bytearray(w * h * 3)

    def in_bounds(self, x, y, w, h):
        return 0 <= x and 0 <= y and w >= 0 and h >= 0 and x + w <= self.w and y + h <= self.h

    def fill_rect(self, x, y, w, h, r, g, b):
        if w <= 0 or h <= 0:
            return
        x0, y0 = max(0, x), max(0, y)
        x1, y1 = min(self.w, x + w), min(self.h, y + h)
        if x0 >= x1 or y0 >= y1:
            return
        row = bytes((r, g, b)) * (x1 - x0)
        for yy in range(y0, y1):
            o = (yy * self.w + x0) * 3
            self.data[o:o + len(row)] = row

    def write_row(self, x, y, rgb):
        """`rgb` is 3*n bytes; clipped to the framebuffer."""
        if y < 0 or y >= self.h:
            return
        n = len(rgb) // 3
        x0, x1 = max(0, x), min(self.w, x + n)
        if x0 >= x1:
            return
        o = (y * self.w + x0) * 3
        self.data[o:o + (x1 - x0) * 3] = rgb[(x0 - x) * 3:(x1 - x) * 3]

    def get_pixel(self, x, y):
        o = (y * self.w + x) * 3
        return (self.data[o], self.data[o + 1], self.data[o + 2])

    def rgb24(self):
        return bytes(self.data)

    def sha256(self):
        return hashlib.sha256(bytes(self.data)).hexdigest()


# ---------------------------------------------------------------- pixel format

def _scale(v, mx):
    if mx <= 0:
        return 0
    return (v * 255) // mx


class PixelFormat:
    def __init__(self, bpp, depth, big_endian, true_colour,
                 red_max, green_max, blue_max, red_shift, green_shift, blue_shift):
        self.bpp = bpp
        self.depth = depth
        self.big_endian = big_endian
        self.true_colour = true_colour
        self.red_max = red_max
        self.green_max = green_max
        self.blue_max = blue_max
        self.red_shift = red_shift
        self.green_shift = green_shift
        self.blue_shift = blue_shift
        self.bytes_per_pixel = max(1, bpp // 8)
        if true_colour:
            sig = max(red_shift + red_max.bit_length(),
                      green_shift + green_max.bit_length(),
                      blue_shift + blue_max.bit_length())
            self.bytes_per_cpixel = max(1, (sig + 7) // 8)
        else:
            self.bytes_per_cpixel = self.bytes_per_pixel
        self.fast_rgb888 = (true_colour and bpp == 32 and big_endian == 0
                            and red_shift == 0 and green_shift == 8 and blue_shift == 16
                            and red_max == green_max == blue_max == 255)

    def block(self):
        return struct.pack(">BBBBHHHBBB3x", self.bpp, self.depth, self.big_endian,
                           self.true_colour, self.red_max, self.green_max, self.blue_max,
                           self.red_shift, self.green_shift, self.blue_shift)

    def unpack(self, raw, colormap):
        if not self.true_colour:
            return colormap.get(raw, (0, 0, 0))
        r = (raw >> self.red_shift) & self.red_max
        g = (raw >> self.green_shift) & self.green_max
        b = (raw >> self.blue_shift) & self.blue_max
        return (_scale(r, self.red_max), _scale(g, self.green_max), _scale(b, self.blue_max))


# ---------------------------------------------------------------- byte readers

class Connection:
    """Buffered socket reader; `on_wait` is polled whenever more bytes are needed."""

    def __init__(self, sock, on_wait=None):
        self.sock = sock
        self.buf = bytearray()
        self.on_wait = on_wait

    def read(self, n):
        while len(self.buf) < n:
            self._fill()
        out = bytes(self.buf[:n])
        del self.buf[:n]
        return out

    def _fill(self):
        if self.on_wait:
            self.on_wait()
        r, _, _ = select.select([self.sock], [], [], 0.02)
        if not r:
            return
        data = self.sock.recv(65536)
        if not data:
            raise EOFError("the server closed the connection")
        self.buf += data


class MemReader:
    """Same `read(n)` interface over an in-memory buffer (the inflated ZRLE bytes)."""

    def __init__(self, data):
        self.data = data
        self.pos = 0

    def read(self, n):
        if self.pos + n > len(self.data):
            raise ProtocolError("truncated ZRLE tile stream (want %d bytes at %d, have %d)"
                                % (n, self.pos, len(self.data) - self.pos))
        out = self.data[self.pos:self.pos + n]
        self.pos += n
        return out


def read_run_length(rd):
    """TRLE/Tight run length: 1 + sum of bytes, 255 means "keep adding"."""
    total = 0
    while True:
        b = rd.read(1)[0]
        if b == 255:
            total += 255
        else:
            return total + b + 1


def read_compact_len(rd):
    """Tight's 1..3 byte little-endian compact length."""
    b = rd.read(1)[0]
    n = b & 0x7F
    if b & 0x80:
        b = rd.read(1)[0]
        n |= (b & 0x7F) << 7
        if b & 0x80:
            b = rd.read(1)[0]
            n |= b << 14
    return n


# ---------------------------------------------------------------- the client

class MockClient:
    def __init__(self, args):
        self.args = args
        self.pf = self._build_pixel_format(args)
        self.colormap = {}
        self.fb = Framebuffer(0, 0)
        self.sock = None
        self.conn = None
        self.connected = False
        self.encodings = self._build_encodings(args)

        self.phase = "setup"
        self.setup_deadline = 0.0
        self.linger_end = 0.0
        self.hard_end = 0.0
        self.pending = 0
        self.next_action = None
        self.action_index = 0

        self.updates = 0
        self.rects = 0
        self.pushed_updates = 0
        self.continuous = False
        self.lossy_rects = []
        self.needs_resync = False
        self.error = None
        self.ok = True

        self.zrle_stream = zlib.decompressobj()
        self.tight_streams = {}
        # TRLE/ZRLE palettes persist for the whole connection (they are reset by a raw tile
        # only for Hextile; for TRLE the server may reuse the previous tile's palette).
        self.tile_state = {"trle": {}, "zrle": {}}

    # ------------------------------------------------------------ option plumbing

    @staticmethod
    def _build_pixel_format(args):
        bpp = args.bpp
        fmt_given = any(v is not None for v in
                        (args.depth, args.red_max, args.green_max, args.blue_max,
                         args.red_shift, args.green_shift, args.blue_shift))
        if args.true_colour is not None:
            true_colour = int(args.true_colour)
        else:
            # An 8bpp request with no explicit format is the non-true-colour (colour-map)
            # case; anything else is true-colour.
            true_colour = 0 if (bpp == 8 and not fmt_given) else 1

        if args.depth is not None:
            depth = args.depth
        else:
            depth = 24 if bpp == 32 else bpp

        if not true_colour:
            return PixelFormat(bpp, depth, 0, 0, 0, 0, 0, 0, 0, 0)

        defaults = {
            32: (255, 255, 255, 0, 8, 16),
            16: (31, 63, 31, 11, 5, 0),
            8: (7, 7, 3, 0, 3, 6),
        }.get(bpp, (255, 255, 255, 0, 8, 16))
        rmax = args.red_max if args.red_max is not None else defaults[0]
        gmax = args.green_max if args.green_max is not None else defaults[1]
        bmax = args.blue_max if args.blue_max is not None else defaults[2]
        rshift = args.red_shift if args.red_shift is not None else defaults[3]
        gshift = args.green_shift if args.green_shift is not None else defaults[4]
        bshift = args.blue_shift if args.blue_shift is not None else defaults[5]
        return PixelFormat(bpp, depth, 0, 1, rmax, gmax, bmax, rshift, gshift, bshift)

    @staticmethod
    def _build_encodings(args):
        if args.encodings:
            return [int(v.strip(), 0) for v in args.encodings.split(",") if v.strip()]
        if args.encoding:
            return [ENCODING_IDS[args.encoding]]
        return list(DEFAULT_ENCODINGS)

    def _encoding_label(self):
        if self.args.encoding:
            return self.args.encoding
        if self.args.encodings:
            return self.args.encodings
        return "auto"

    # ------------------------------------------------------------ io helpers

    def _on_wait(self):
        now = time.monotonic()
        if self.phase == "setup":
            if now >= self.setup_deadline:
                raise TimeoutError("timed out after %.0fs waiting for the server"
                                   % self.args.timeout)
            return
        self._pump_actions(now)
        if now >= self.hard_end:
            raise LingerDone()
        if now >= self.linger_end and self.pending == 0:
            if self.args.continuous_updates and not self.pushed_updates:
                # No request outstanding, so the only thing that can still produce an update is
                # the server pushing one: wait for it (up to hard_end) instead of declaring
                # success on a client that has simply been sitting there.
                return
            raise LingerDone()

    def _u8(self):
        return self.conn.read(1)[0]

    def _u16(self):
        return struct.unpack(">H", self.conn.read(2))[0]

    def _u32(self):
        return struct.unpack(">I", self.conn.read(4))[0]

    def _s32(self):
        return struct.unpack(">i", self.conn.read(4))[0]

    def _send(self, data):
        self.sock.sendall(data)

    # ------------------------------------------------------------ handshake

    def run(self):
        args = self.args
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.settimeout(args.timeout)
        try:
            self.sock.connect((args.host, args.port))
        except OSError as exc:
            raise ProtocolError("cannot connect to %s:%d: %s" % (args.host, args.port, exc))
        self.sock.settimeout(None)
        self.conn = Connection(self.sock, self._on_wait)
        self.connected = True
        log("CONNECT")

        self.setup_deadline = time.monotonic() + args.timeout
        self._handshake()
        self._send_pixel_format()
        self._send_encodings()
        self.fb.resize(self.width, self.height)
        self._request_update(0)

        while True:
            now = time.monotonic()
            if self.phase == "linger":
                self._pump_actions(now)
                if now >= self.hard_end or (now >= self.linger_end and self.pending == 0):
                    break
            try:
                self._handle_message()
            except LingerDone:
                break

        self._finish()

    def _handshake(self):
        version = self.conn.read(12)
        if not version.startswith(b"RFB ") or not version.endswith(b"\n"):
            raise ProtocolError("bad ProtocolVersion %r" % version)
        try:
            major = int(version[4:7])
            minor = int(version[8:11])
        except ValueError:
            raise ProtocolError("bad ProtocolVersion %r" % version)

        if (major, minor) == (3, 8):
            self._send(b"RFB 003.008\n")
            proto = 8
        elif (major, minor) == (3, 7):
            self._send(b"RFB 003.007\n")
            proto = 7
        else:
            self._send(b"RFB 003.003\n")
            proto = 3

        if proto >= 7:
            chosen = self._negotiate_security(proto)
        else:
            chosen = self._read_security_33()

        if chosen == 1:
            log("SECURITY none")
            if proto >= 7:
                status = self._u32()
                if status != 0:
                    reason = self._reason()
                    log("AUTH failed")
                    raise ProtocolError("server rejected the None security type: %s" % reason)
            log("AUTH ok")
        elif chosen == 2:
            log("SECURITY vnc")
            if not self.args.password:
                raise ProtocolError("VNC Authentication was selected but no --password was given")
            challenge = self.conn.read(16)
            self._send(vnc_response(self.args.password, challenge))
            status = self._u32()
            if status != 0:
                reason = self._reason() if proto >= 8 else ""
                log("AUTH failed")
                raise ProtocolError("authentication failed"
                                    + (": %s" % reason if reason else ""))
            log("AUTH ok")
        else:
            raise ProtocolError("server selected unsupported security type %d" % chosen)

        self._send(bytes([1]))  # ClientInit, shared
        self.width = self._u16()
        self.height = self._u16()
        self.conn.read(16)      # server PIXEL_FORMAT (we ask for our own right after)
        name = self.conn.read(self._u32()).decode("utf-8", "replace")
        log("SERVERINIT name=%s width=%d height=%d" % (name, self.width, self.height))

    def _negotiate_security(self, proto):
        count = self._u8()
        if count == 0:
            raise ProtocolError("the server refused the connection: %s" % self._reason())
        types = list(self.conn.read(count))
        if self.args.security == "vnc":
            if 2 not in types:
                raise ProtocolError("server offers no VNC Authentication security type "
                                    "(offered: %s)" % self._types(types))
            chosen = 2
        else:
            if 1 not in types:
                raise ProtocolError("server offers no None security type (offered: %s)"
                                    % self._types(types))
            chosen = 1
        self._send(bytes([chosen]))
        return chosen

    def _read_security_33(self):
        stype = self._u32()
        if stype == 0:
            raise ProtocolError("the server refused the connection: %s" % self._reason())
        if stype not in (1, 2):
            raise ProtocolError("server selected unsupported security type %d" % stype)
        return stype

    @staticmethod
    def _types(types):
        return ",".join(str(t) for t in types)

    def _reason(self):
        return self.conn.read(self._u32()).decode("utf-8", "replace")

    # ------------------------------------------------------------ client messages

    def _send_pixel_format(self):
        self._send(bytes([0, 0, 0, 0]) + self.pf.block())
        log("CLIENT SetPixelFormat bpp=%d depth=%d red_shift=%d green_shift=%d blue_shift=%d"
            % (self.pf.bpp, self.pf.depth, self.pf.red_shift, self.pf.green_shift,
               self.pf.blue_shift))

    def _send_encodings(self):
        encs = self.encodings
        self._send(bytes([2, 0]) + struct.pack(">H", len(encs))
                   + b"".join(struct.pack(">i", e) for e in encs))
        log("CLIENT SetEncodings %s" % ",".join(str(e) for e in encs))

    def _request_update(self, incremental):
        x, y, w, h = 0, 0, self.fb.w, self.fb.h
        self._send(struct.pack(">BBHHHH", 3, incremental, x, y, w, h))
        self.pending += 1
        log("CLIENT FramebufferUpdateRequest incremental=%d x=%d y=%d w=%d h=%d"
            % (incremental, x, y, w, h))

    def send_pointer(self, x, y, mask):
        self._send(struct.pack(">BBHH", 5, mask, x, y))
        log("CLIENT PointerEvent mask=%d x=%d y=%d" % (mask, x, y))

    def send_key(self, keysym, down):
        self._send(struct.pack(">BBHI", 4, down, 0, keysym))
        log("CLIENT KeyEvent keysym=0x%x down=%d" % (keysym, down))

    def send_cut_text(self, text):
        data = text.encode("utf-8")
        self._send(struct.pack(">B3xI", 6, len(data)) + data)
        log("CLIENT ClientCutText len=%d" % len(data))

    def send_enable_continuous_updates(self, enable, x=None, y=None, w=None, h=None):
        """EnableContinuousUpdates (150). With enable set the server has to push instead of
        being asked, so no FramebufferUpdateRequest follows; with it cleared the server must
        acknowledge with EndOfContinuousUpdates and go back to answering requests."""
        if x is None:
            x, y = 0, 0
        if w is None:
            w, h = self.fb.w, self.fb.h
        self._send(struct.pack(">BBHHHH", 150, 1 if enable else 0, x, y, w, h))
        self.continuous = bool(enable)
        log("CLIENT EnableContinuousUpdates enable=%d x=%d y=%d w=%d h=%d"
            % (1 if enable else 0, x, y, w, h))

    # ------------------------------------------------------------ queued input

    def _pump_actions(self, now):
        if self.next_action is None:
            return
        while self.action_index < len(self.args.actions) and now >= self.next_action:
            self._send_action(self.args.actions[self.action_index])
            self.action_index += 1
            self.next_action += ACTION_INTERVAL

    def _send_action(self, action):
        kind = action[0]
        if kind == "pointer":
            self.send_pointer(action[1], action[2], action[3])
        elif kind == "key":
            self.send_key(action[1], action[2])
        else:
            self.send_cut_text(action[1])

    # ------------------------------------------------------------ server messages

    def _handle_message(self):
        t = self._u8()
        if t == 0:
            self._handle_framebuffer_update()
        elif t == 1:
            self._handle_colormap()
        elif t == 2:
            log("SERVER Bell")
        elif t == 3:
            self._handle_cut_text()
        elif t == 150:
            # EndOfContinuousUpdates: the server will not push any more, so asking again is the
            # only way to get an update. One byte, the type alone.
            self.continuous = False
            log("SERVER EndOfContinuousUpdates")
        else:
            raise ProtocolError("unknown server message %d" % t)

    def _handle_framebuffer_update(self):
        self._u8()  # padding
        nrects = self._u16()
        log("SERVER FramebufferUpdate nrects=%d" % nrects)
        for _ in range(nrects):
            x, y, w, h, enc = struct.unpack(">HHHHi", self.conn.read(12))
            if enc == LASTRECT:
                log("SERVER LastRect")
                break
            self._decode_rect(x, y, w, h, enc)
            self.rects += 1
        self.updates += 1
        if self.pending == 0:
            # Nothing of ours is outstanding: the server sent this on its own.
            self.pushed_updates += 1
            log("SERVER FramebufferUpdate pushed (no request outstanding)")
        self.pending = max(0, self.pending - 1)
        self._after_update()

    def _after_update(self):
        now = time.monotonic()
        if self.updates == 1:
            self.phase = "linger"
            self.linger_end = now + max(0.0, self.args.linger)
            self.hard_end = self.linger_end + max(5.0, self.args.timeout)
            self.next_action = now
            if self.args.continuous_updates:
                # The extension's client side, as a viewer does it: once the framebuffer size is
                # known, ask to be kept up to date without asking (and never ask again).
                self.send_enable_continuous_updates(True)
        if self.needs_resync:
            # The framebuffer was reallocated by DesktopSize: resynchronise non-incrementally.
            self.needs_resync = False
            self._request_update(0)
            if self.args.continuous_updates:
                # ... and re-ask for the new geometry: a viewer follows a resize with a fresh
                # EnableContinuousUpdates (the old region is the old size).
                self.send_enable_continuous_updates(True)
        elif self.updates <= self.args.requests and not self.args.continuous_updates:
            # With the extension on there is nothing to ask for: the server pushes.
            self._request_update(1)

    def _handle_colormap(self):
        self._u8()  # padding
        first = self._u16()
        count = self._u16()
        data = self.conn.read(count * 6)
        for i in range(count):
            r, g, b = struct.unpack(">HHH", data[i * 6:i * 6 + 6])
            self.colormap[first + i] = (r >> 8, g >> 8, b >> 8)
        log("SERVER SetColorMapEntries first=%d count=%d" % (first, count))

    def _handle_cut_text(self):
        self.conn.read(3)  # padding
        length = self._u32()
        self.conn.read(length)
        log("SERVER ServerCutText len=%d" % length)

    # ------------------------------------------------------------ rectangle decoding

    def _decode_rect(self, x, y, w, h, enc):
        if enc == DESKTOP_SIZE:
            self.fb.resize(w, h)
            self.needs_resync = True
            log("SERVER DesktopSize width=%d height=%d" % (w, h))
            return
        if not self.fb.in_bounds(x, y, w, h):
            raise ProtocolError("rect %dx%d at (%d,%d) does not fit the %dx%d framebuffer"
                                % (w, h, x, y, self.fb.w, self.fb.h))
        if enc == RAW:
            self._decode_raw(x, y, w, h)
        elif enc == COPYRECT:
            src_x, src_y = self._u16(), self._u16()
            self._decode_copyrect(x, y, w, h, src_x, src_y)
        elif enc == RRE:
            self._decode_rre(x, y, w, h)
        elif enc == HEXTILE:
            self._decode_hextile(x, y, w, h)
        elif enc == TRLE:
            self._decode_tiles(self.tile_state["trle"], self.conn, x, y, w, h, 16)
        elif enc == ZRLE:
            self._decode_zrle(x, y, w, h)
        elif enc == TIGHT:
            self._decode_tight(x, y, w, h)
        else:
            raise ProtocolError("unsupported encoding %d" % enc)
        log("DECODED x=%d y=%d w=%d h=%d encoding=%s"
            % (x, y, w, h, ENCODING_NAMES.get(enc, str(enc))))

    def _read_pixel(self):
        return self._unpack(self.conn.read(self.pf.bytes_per_pixel))

    def _read_cpixel(self):
        return self._unpack(self.conn.read(self.pf.bytes_per_cpixel))

    def _unpack(self, data):
        order = "big" if self.pf.big_endian else "little"
        return self.pf.unpack(int.from_bytes(data, order), self.colormap)

    def _decode_pixels(self, data, count, cpixel=False):
        stride = self.pf.bytes_per_cpixel if cpixel else self.pf.bytes_per_pixel
        if self.pf.fast_rgb888:
            if cpixel:
                return data[:count * 3]
            out = bytearray(count * 3)
            for i in range(count):
                out[i * 3:i * 3 + 3] = data[i * 4:i * 4 + 3]
            return bytes(out)
        out = bytearray(count * 3)
        order = "big" if self.pf.big_endian else "little"
        for i in range(count):
            raw = int.from_bytes(data[i * stride:(i + 1) * stride], order)
            r, g, b = self.pf.unpack(raw, self.colormap)
            out[i * 3] = r
            out[i * 3 + 1] = g
            out[i * 3 + 2] = b
        return bytes(out)

    def _decode_raw(self, x, y, w, h):
        ps = self.pf.bytes_per_pixel
        for row in range(h):
            data = self.conn.read(w * ps)
            self.fb.write_row(x, y + row, self._decode_pixels(data, w))

    def _decode_copyrect(self, x, y, w, h, src_x, src_y):
        if not self.fb.in_bounds(src_x, src_y, w, h):
            raise ProtocolError("CopyRect source %dx%d at (%d,%d) is outside the framebuffer"
                                % (w, h, src_x, src_y))
        rows = []
        for row in range(h):
            o = ((src_y + row) * self.fb.w + src_x) * 3
            rows.append(bytes(self.fb.data[o:o + w * 3]))
        for row in range(h):
            self.fb.write_row(x, y + row, rows[row])

    def _decode_rre(self, x, y, w, h):
        n = self._u32()
        br, bg, bb = self._read_pixel()
        self.fb.fill_rect(x, y, w, h, br, bg, bb)
        for _ in range(n):
            r, g, b = self._read_pixel()
            sx, sy, sw, sh = struct.unpack(">HHHH", self.conn.read(8))
            self.fb.fill_rect(x + sx, y + sy, sw, sh, r, g, b)

    def _decode_hextile(self, x, y, w, h):
        bg = fg = None
        for ty in range(0, h, 16):
            th = min(16, h - ty)
            for tx in range(0, w, 16):
                tw = min(16, w - tx)
                mask = self._u8()
                if mask & 1:  # Raw
                    ps = self.pf.bytes_per_pixel
                    for row in range(th):
                        data = self.conn.read(tw * ps)
                        self.fb.write_row(x + tx, y + ty + row, self._decode_pixels(data, tw))
                    bg = fg = None
                    continue
                if mask & 2:  # BackgroundSpecified
                    bg = self._read_pixel()
                elif bg is None:
                    raise ProtocolError("Hextile: background not specified at tile (%d,%d)"
                                        % (tx, ty))
                if mask & 4:  # ForegroundSpecified
                    if mask & 16:
                        raise ProtocolError("Hextile: ForegroundSpecified with "
                                            "SubrectsColoured at tile (%d,%d)" % (tx, ty))
                    fg = self._read_pixel()
                self.fb.fill_rect(x + tx, y + ty, tw, th, *bg)
                if mask & 8:  # AnySubrects
                    count = self._u8()
                    coloured = bool(mask & 16)
                    for _ in range(count):
                        if coloured:
                            col = self._read_pixel()
                        else:
                            if fg is None:
                                raise ProtocolError("Hextile: subrect without a foreground "
                                                    "at tile (%d,%d)" % (tx, ty))
                            col = fg
                        xy, wh = self._u8(), self._u8()
                        sx, sy = xy >> 4, xy & 0xF
                        sw, sh = (wh >> 4) + 1, (wh & 0xF) + 1
                        self.fb.fill_rect(x + tx + sx, y + ty + sy, sw, sh, *col)
                    if coloured:
                        fg = None

    # -- TRLE / ZRLE shared tile decoder

    def _decode_zrle(self, x, y, w, h):
        length = self._u32()
        data = self.conn.read(length)
        try:
            inflated = self.zrle_stream.decompress(data)
        except zlib.error as exc:
            raise ProtocolError("ZRLE: zlib error %s while inflating %d bytes at rect "
                                "(%d,%d,%d,%d)" % (exc, length, x, y, w, h))
        self._decode_tiles(self.tile_state["zrle"], MemReader(inflated), x, y, w, h, 64)

    def _decode_tiles(self, state, rd, x, y, w, h, tile_size):
        for ty in range(0, h, tile_size):
            th = min(tile_size, h - ty)
            for tx in range(0, w, tile_size):
                tw = min(tile_size, w - tx)
                self._decode_tile(state, rd, x + tx, y + ty, tw, th)

    def _decode_tile(self, state, rd, dx, dy, tw, th):
        cp = self.pf.bytes_per_cpixel
        sub = rd.read(1)[0]
        if sub == 0:  # raw CPIXELs
            for row in range(th):
                data = rd.read(tw * cp)
                self.fb.write_row(dx, dy + row, self._decode_pixels(data, tw, cpixel=True))
            return
        if sub == 1:  # solid
            self.fb.fill_rect(dx, dy, tw, th, *self._unpack(rd.read(cp)))
            return

        pal = None
        palette_size = None
        rle = False
        read_palette = False
        if 2 <= sub <= 16:
            palette_size = sub
            read_palette = True
        elif sub == 127:  # packed palette, reused
            pal, palette_size = state.get("palette"), state.get("palette_size")
            if pal is None:
                raise ProtocolError("TRLE: palette reuse (127) without a previous palette")
        elif sub == 128:  # plain RLE
            rle = True
        elif sub == 129:  # palette RLE, reused
            pal, palette_size = state.get("palette"), state.get("palette_size")
            if pal is None:
                raise ProtocolError("TRLE: palette reuse (129) without a previous palette")
            rle = True
        elif sub >= 130:
            palette_size = sub - 128
            read_palette = True
            rle = True
        else:
            raise ProtocolError("unsupported TRLE subencoding %d" % sub)

        if palette_size is not None and palette_size < 2:
            raise ProtocolError("unsupported TRLE subencoding %d" % sub)

        if read_palette:
            pal = [self._unpack(rd.read(cp)) for _ in range(palette_size)]
            state["palette"], state["palette_size"] = pal, palette_size

        if not rle:
            self._decode_packed_palette(rd, dx, dy, tw, th, pal, palette_size)
            return

        npix = tw * th
        done = 0
        while done < npix:
            if sub == 128:
                r, g, b = self._unpack(rd.read(cp))
                length = read_run_length(rd)
            else:
                idx = rd.read(1)[0]
                if idx >= 128:
                    idx -= 128
                    length = read_run_length(rd)
                else:
                    length = 1
                if idx >= len(pal):
                    raise ProtocolError("TRLE: palette index %d out of range (%d entries) "
                                        "at tile (%d,%d)" % (idx, len(pal), dx, dy))
                r, g, b = pal[idx]
            if length <= 0 or done + length > npix:
                raise ProtocolError("TRLE: run of %d overflows tile (%d/%d pixels) at "
                                    "tile (%d,%d)" % (length, done, npix, dx, dy))
            self._write_tile_run(dx, dy, tw, th, done, length, r, g, b)
            done += length

    def _decode_packed_palette(self, rd, dx, dy, tw, th, pal, palette_size):
        bpp = 1 if palette_size == 2 else (2 if palette_size <= 4 else 4)
        row_bytes = (tw * bpp + 7) // 8
        mask = (1 << bpp) - 1
        for row in range(th):
            data = rd.read(row_bytes)
            for col in range(tw):
                bitpos = col * bpp
                byte = data[bitpos // 8]
                v = (byte >> (8 - bpp - (bitpos % 8))) & mask
                if v >= len(pal):
                    raise ProtocolError("TRLE: palette index %d out of range (%d entries) at "
                                        "tile (%d,%d) col %d" % (v, palette_size, dx, dy, col))
                r, g, b = pal[v]
                self.fb.fill_rect(dx + col, dy + row, 1, 1, r, g, b)

    def _write_tile_run(self, dx, dy, tw, th, start, count, r, g, b):
        limit = tw * th
        if start + count > limit:
            count = limit - start
        idx = start
        while count > 0:
            col = idx % tw
            n = min(count, tw - col)
            self.fb.fill_rect(dx + col, dy + idx // tw, n, 1, r, g, b)
            idx += n
            count -= n

    # -- Tight

    def _tight_stream(self, stream_id):
        s = self.tight_streams.get(stream_id)
        if s is None:
            s = zlib.decompressobj()
            self.tight_streams[stream_id] = s
        return s

    def _decode_tight(self, x, y, w, h):
        ctl = self._u8()
        for i in range(4):
            if ctl & (1 << i):
                self.tight_streams.pop(i, None)
        ctl >>= 4

        cp = self.pf.bytes_per_cpixel
        if ctl == TIGHT_FILL:
            self.fb.fill_rect(x, y, w, h, *self._unpack(self.conn.read(cp)))
            return
        if ctl == TIGHT_JPEG:
            return self._tight_jpeg(x, y, w, h)
        if ctl > TIGHT_NO_ZLIB:
            raise ProtocolError("unsupported Tight subencoding 0x%02X" % ctl)

        uncompressed = ctl == TIGHT_NO_ZLIB
        stream_id = ctl & 0x03
        filter_id = 0
        if not uncompressed and (ctl & TIGHT_EXPLICIT_FILTER):
            filter_id = self._u8()

        pal = None
        num_colors = None
        if filter_id == 0:
            bits = 24
        elif filter_id == 1:
            num_colors = self._u8() + 1
            if num_colors < 2:
                raise ProtocolError("Tight: palette with fewer than 2 colours")
            pal = []
            for _ in range(num_colors):
                pal.append(self._unpack(self.conn.read(cp)))
            bits = 1 if num_colors == 2 else 8
        elif filter_id == 2:
            if w > 4096:
                raise ProtocolError("Tight: gradient rect width %d exceeds 4096" % w)
            bits = 24
        else:
            raise ProtocolError("unsupported Tight filter %d" % filter_id)

        row_size = (w * bits + 7) // 8
        raw_size = row_size * h
        if raw_size < TIGHT_MIN_TO_COMPRESS:
            data = self.conn.read(raw_size)
        else:
            length = read_compact_len(self.conn)
            comp = self.conn.read(length)
            if uncompressed:
                data = comp
            else:
                try:
                    data = self._tight_stream(stream_id).decompress(comp)
                except zlib.error as exc:
                    raise ProtocolError("Tight: zlib error %s while inflating %d bytes at "
                                        "rect (%d,%d,%d,%d)" % (exc, length, x, y, w, h))

        if filter_id == 0 or uncompressed:
            self._tight_copy(x, y, w, h, data)
        elif filter_id == 1:
            self._tight_palette(x, y, w, h, data, pal, num_colors)
        else:
            self._tight_gradient(x, y, w, h, data)

    def _tight_copy(self, x, y, w, h, data):
        if len(data) < w * h * 3:
            raise ProtocolError("Tight: copy filter got %d bytes, need %d"
                                % (len(data), w * h * 3))
        for row in range(h):
            self.fb.write_row(x, y + row, data[row * w * 3:(row + 1) * w * 3])

    def _tight_palette(self, x, y, w, h, data, pal, num_colors):
        if num_colors == 2:
            row_bytes = (w + 7) // 8
            if len(data) < row_bytes * h:
                raise ProtocolError("Tight: palette(2) got %d bytes, need %d"
                                    % (len(data), row_bytes * h))
            for row in range(h):
                base = row * row_bytes
                for col in range(w):
                    bitpos = col
                    byte = data[base + bitpos // 8]
                    idx = (byte >> (7 - (bitpos % 8))) & 1
                    self.fb.fill_rect(x + col, y + row, 1, 1, *pal[idx])
        else:
            if len(data) < w * h:
                raise ProtocolError("Tight: palette(%d) got %d bytes, need %d"
                                    % (num_colors, len(data), w * h))
            for row in range(h):
                base = row * w
                for col in range(w):
                    idx = data[base + col]
                    if idx >= num_colors:
                        raise ProtocolError("Tight: palette index %d out of range (%d entries)"
                                            % (idx, num_colors))
                    self.fb.fill_rect(x + col, y + row, 1, 1, *pal[idx])

    def _tight_gradient(self, x, y, w, h, data):
        if len(data) < w * h * 3:
            raise ProtocolError("Tight: gradient got %d bytes, need %d"
                                % (len(data), w * h * 3))
        prev = [0] * (w * 3)
        di = 0
        for row in range(h):
            cur = [0] * (w * 3)
            for c in range(3):
                cur[c] = (prev[c] + data[di]) & 0xFF
                di += 1
            out = bytearray(cur[:3])
            for col in range(1, w):
                for c in range(3):
                    est = prev[col * 3 + c] + cur[(col - 1) * 3 + c] - prev[(col - 1) * 3 + c]
                    est = max(0, min(255, est))
                    v = (est + data[di]) & 0xFF
                    di += 1
                    cur[col * 3 + c] = v
                out += bytes(cur[col * 3:col * 3 + 3])
            self.fb.write_row(x, y + row, bytes(out))
            prev = cur

    def _tight_jpeg(self, x, y, w, h):
        if Image is None:
            raise ProtocolError("Tight: JPEG payload but Pillow is not available")
        length = read_compact_len(self.conn)
        blob = self.conn.read(length)
        try:
            img = Image.open(io.BytesIO(blob)).convert("RGB")
        except Exception as exc:
            raise ProtocolError("Tight: cannot decode the JPEG payload: %s" % exc)
        if img.size != (w, h):
            raise ProtocolError("Tight: JPEG is %dx%d, rect is %dx%d"
                                % (img.size[0], img.size[1], w, h))
        raw = img.tobytes()
        for row in range(h):
            self.fb.write_row(x, y + row, raw[row * w * 3:(row + 1) * w * 3])
        self.lossy_rects.append((x, y, w, h))

    # ------------------------------------------------------------ assertions / output

    def _finish(self):
        args = self.args
        if args.frame:
            self._write_frame(args.frame)
        if args.expect_width is not None and self.fb.w != args.expect_width:
            self._fail("framebuffer width is %d, expected %d" % (self.fb.w, args.expect_width))
        if args.expect_height is not None and self.fb.h != args.expect_height:
            self._fail("framebuffer height is %d, expected %d" % (self.fb.h, args.expect_height))
        if args.continuous_updates and not self.pushed_updates:
            # The whole point of the extension: with no request outstanding, an update can only
            # come from the server pushing it.
            self._fail("continuous updates: no FramebufferUpdate was pushed (the server kept "
                       "answering requests only), but none was asked for either")
        if args.expect_pattern and args.expect_pattern != "none":
            self._check_pattern(args.expect_pattern)

    def _fail(self, msg):
        self.ok = False
        if self.error is None:
            self.error = msg

    def _write_frame(self, path):
        if Image is None:
            self._fail("--frame needs Pillow")
            return
        img = Image.frombytes("RGB", (self.fb.w, self.fb.h), self.fb.rgb24())
        img.save(path)

    def _check_pattern(self, pattern):
        w, h = self.fb.w, self.fb.h
        skip = bytearray(w * h)
        for (lx, ly, lw, lh) in self.lossy_rects:
            for yy in range(max(0, ly), min(h, ly + lh)):
                base = yy * w
                for xx in range(max(0, lx), min(w, lx + lw)):
                    skip[base + xx] = 1
        tol = self.args.tolerance
        mismatch = 0
        first = None
        data = self.fb.data
        for yy in range(h):
            rowbase = yy * w
            for xx in range(w):
                if skip[rowbase + xx]:
                    continue
                want = expected_pixel(pattern, xx, yy, w, h)
                o = (rowbase + xx) * 3
                got = (data[o], data[o + 1], data[o + 2])
                if (abs(got[0] - want[0]) > tol or abs(got[1] - want[1]) > tol
                        or abs(got[2] - want[2]) > tol):
                    mismatch += 1
                    if first is None:
                        first = (xx, yy, got, want)
        if mismatch:
            self._fail("pattern %s mismatch: %d pixels differ, first at (%d,%d): got %s, "
                       "want %s" % (pattern, mismatch, first[0], first[1], first[2], first[3]))

    def result(self, ok, error):
        probes = {}
        for (px, py) in self.args.probe:
            if self.fb.w > 0 and self.fb.h > 0:
                x = min(max(px, 0), self.fb.w - 1)
                y = min(max(py, 0), self.fb.h - 1)
                probes["%d,%d" % (px, py)] = list(self.fb.get_pixel(x, y))
            else:
                probes["%d,%d" % (px, py)] = None
        return {
            "ok": bool(ok),
            "error": error,
            "width": self.fb.w,
            "height": self.fb.h,
            "encoding": self._encoding_label(),
            "bpp": self.pf.bpp,
            "updates": self.updates,
            "rects": self.rects,
            "continuous_updates": bool(self.args.continuous_updates),
            "pushed_updates": self.pushed_updates,
            "pixel_sha256": self.fb.sha256(),
            "probes": probes,
            "frame_png": self.args.frame,
        }

    def close(self):
        if self.connected:
            log("DISCONNECT")
            self.connected = False
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None


# ---------------------------------------------------------------- expected patterns

def expected_pixel(pattern, x, y, w, h):
    if pattern == "gradient":
        return (x % 256, y % 256, (x ^ y) % 256)
    if pattern == "quadrants":
        left, top = x < w // 2, y < h // 2
        if top and left:
            return (255, 0, 0)
        if top:
            return (0, 255, 0)
        if left:
            return (0, 0, 255)
        return (255, 255, 255)
    if pattern == "checker":
        c = 255 if ((x // 32 + y // 32) % 2 == 0) else 0
        return (c, c, c)
    raise ValueError("unknown pattern " + pattern)


# ---------------------------------------------------------------- CLI

class _Action(argparse.Action):
    """Appends --pointer/--key/--cuttext to one ordered list."""

    def __call__(self, parser, namespace, values, option_string=None):
        actions = list(getattr(namespace, "actions", []) or [])
        if self.dest == "pointer":
            xy, mask = values.split(":", 1)
            x, y = xy.split(",", 1)
            actions.append(("pointer", int(x), int(y), int(mask, 0)))
        elif self.dest == "key":
            ksym, down = values.split(":", 1)
            actions.append(("key", int(ksym, 0), int(down, 0)))
        else:
            actions.append(("cuttext", values))
        setattr(namespace, "actions", actions)


def build_parser():
    ap = argparse.ArgumentParser(description="An independent RFB 3.8 VNC client fixture.")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=5900)
    ap.add_argument("--security", choices=["none", "vnc"], default="none")
    ap.add_argument("--password", default="secret")
    ap.add_argument("--encoding", choices=sorted(ENCODING_IDS), default=None,
                    help="announce this single encoding")
    ap.add_argument("--encodings", default=None,
                    help="explicit comma-separated SetEncodings list, e.g. 16,5,2,0")
    ap.add_argument("--bpp", type=int, default=32, choices=[8, 16, 32])
    ap.add_argument("--depth", type=int, default=None)
    ap.add_argument("--red-shift", type=int, default=None)
    ap.add_argument("--green-shift", type=int, default=None)
    ap.add_argument("--blue-shift", type=int, default=None)
    ap.add_argument("--red-max", type=int, default=None)
    ap.add_argument("--green-max", type=int, default=None)
    ap.add_argument("--blue-max", type=int, default=None)
    ap.add_argument("--true-colour", type=int, default=None, choices=[0, 1],
                    help="force true-colour (1) or colour-map (0) mode; default: 0 for a bare "
                         "--bpp 8, 1 otherwise")
    ap.add_argument("--requests", type=int, default=0,
                    help="incremental FramebufferUpdateRequests after the initial one")
    ap.add_argument("--continuous-updates", action="store_true",
                    help="enable Continuous Updates (client message 150) after the first update "
                         "and send no further FramebufferUpdateRequests, so later updates can "
                         "only arrive pushed; fails if none does")
    ap.add_argument("--linger", type=float, default=2.0,
                    help="seconds to stay connected after the first decoded update")
    ap.add_argument("--probe", action="append", default=[], metavar="X,Y")
    ap.add_argument("--frame", default=None, metavar="FILE.png")
    ap.add_argument("--expect-pattern", default="none",
                    choices=["quadrants", "gradient", "checker", "none"])
    ap.add_argument("--expect-width", type=int, default=None)
    ap.add_argument("--expect-height", type=int, default=None)
    ap.add_argument("--tolerance", type=int, default=0,
                    help="per-channel tolerance when comparing --expect-pattern")
    ap.add_argument("--pointer", action=_Action, dest="pointer", metavar="X,Y:MASK")
    ap.add_argument("--key", action=_Action, dest="key", metavar="KEYSYM:DOWN")
    ap.add_argument("--cuttext", action=_Action, dest="cuttext", metavar="TEXT")
    ap.add_argument("--log", default=None)
    ap.add_argument("--timeout", type=float, default=10.0)
    ap.set_defaults(actions=[])
    return ap


def _parse_probes(parser, raw):
    probes = []
    for item in raw:
        try:
            x, y = item.split(",", 1)
            probes.append((int(x), int(y)))
        except ValueError:
            parser.error("bad --probe %r, want X,Y" % item)
    return probes


def main():
    global LOG_FH
    parser = build_parser()
    args = parser.parse_args()
    args.probe = _parse_probes(parser, args.probe)

    if args.log:
        LOG_FH = open(args.log, "a")

    client = MockClient(args)
    ok = True
    error = None
    try:
        client.run()
    except LingerDone:
        pass
    except Exception as exc:  # protocol errors, timeouts, closed sockets: report, never trace
        ok = False
        error = "%s: %s" % (type(exc).__name__, exc)
    finally:
        client.close()

    if ok and not client.ok:
        ok = False
        error = client.error
    if not ok and error is None:
        error = client.error or "unknown error"

    if not ok:
        print(error, file=sys.stderr)
    print(json.dumps(client.result(ok, error)))
    if LOG_FH:
        LOG_FH.close()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

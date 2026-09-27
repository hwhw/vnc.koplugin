--[[--
Server-side rectangle encoders: the pixel-format conversion from KOReader's screen to whatever
format a client asked for, plus Raw, RRE, Hextile and ZRLE encoders.

The screen a client sees is `Screen.bb`, whose BlitBuffer type differs from device to device
(`BB8` on most e-ink, `BBRGB16/24/32` elsewhere). Rather than knowing every one of those layouts,
each rectangle is first blitted into a reusable `TYPE_BBRGB24` buffer - the C blitter does all
cross-format work - which leaves exactly one layout to handle here: three bytes `[r, g, b]` per
pixel (the same layout this plugin's client side relies on).

From there a rectangle is turned into
  * a `uint32_t` array of pixel *values* in the client's format (what the encoders compare), and
  * a byte string of those pixels as they go on the wire (what Raw sends).

The pixel format is the client's, per RFC 6143 §7.6.2: channel values are scaled to the client's
maxima and placed at its shifts, with the bytes ordered by its big-endian flag. Clients that ask
for a colour-mapped format get the fixed 3-3-2 map in @{Enc.COLOUR_MAP}.

@module vnc.serverenc
]]

local BB = require("ffi/blitbuffer")
local ffi = require("ffi")
local ZStream = require("vnc/zstream")
local Util = require("vnc/util")
local logger = require("logger")

local Enc = {}
Enc.__index = Enc

Enc.RAW = 0
Enc.RRE = 2
Enc.HEXTILE = 5
Enc.ZRLE = 16

Enc.HEXTILE_SIZE = 16
Enc.ZRLE_TILE = 64

--- The pixel format a client sees if it never sends SetPixelFormat (and what ServerInit
--- announces): 32bpp true colour with RGB in the low address bytes, i.e. what this plugin's own
--- client asks for.
Enc.DEFAULT_FORMAT = {
    bits_per_pixel = 32, depth = 24, big_endian = 0, true_colour = 1,
    red_max = 255, green_max = 255, blue_max = 255,
    red_shift = 0, green_shift = 8, blue_shift = 16,
}

--- The 3-3-2 colour map served to colour-mapped clients (256 entries of `{r, g, b}`, 0..255).
Enc.COLOUR_MAP = {}
for i = 0, 255 do
    local r = math.floor((i / 32) % 8)
    local g = math.floor((i / 4) % 8)
    local b = i % 4
    Enc.COLOUR_MAP[i + 1] = {
        math.floor(r * 255 / 7 + 0.5),
        math.floor(g * 255 / 7 + 0.5),
        math.floor(b * 255 / 3 + 0.5),
    }
end

--- The colour map entry index for a pixel (inverse of @{Enc.COLOUR_MAP}).
local function map_index(r, g, b)
    return math.floor(r * 7 / 255 + 0.5) * 32
        + math.floor(g * 7 / 255 + 0.5) * 4
        + math.floor(b * 3 / 255 + 0.5)
end

function Enc.new()
    return setmetatable({
        -- Never nil: an encoder is always able to convert, and ServerInit announces this format
        -- until the client asks for another one.
        fmt = Enc.DEFAULT_FORMAT,
        encodings = { Enc.RAW },
        -- reuse buffers across rectangles; a full-screen rectangle is the worst case
        bb24 = nil,
        out = nil,
        values = nil,
        pixel_buf = ffi.new("uint8_t[8]"),
        zstream = nil,
        values_size = 0,             -- pixels the buffer holds (0 = nothing allocated yet)
        out_len = 0,                 -- bytes the packed-pixel buffer holds
        cpixel_bytes = nil,          -- which of the 4 bytes of a 32bpp pixel carry the channels
        lut = { ffi.new("uint32_t[256]"), ffi.new("uint32_t[256]"), ffi.new("uint32_t[256]") },
    }, Enc)
end

--- Frees the reusable buffers (the zlib stream and the temp BlitBuffer).
function Enc:free()
    if self.bb24 then self.bb24:free() self.bb24 = nil end
    if self.zstream then self.zstream:free() self.zstream = nil end
    self.out, self.values = nil, nil
end

-- ---------------------------------------------------------------- pixel format

--- Adopts the client's pixel format (as parsed from SetPixelFormat).
function Enc:set_pixel_format(fmt)
    self.fmt = fmt
    local true_colour = fmt.true_colour ~= 0
    if true_colour then
        local maxima = { fmt.red_max, fmt.green_max, fmt.blue_max }
        local shifts = { fmt.red_shift, fmt.green_shift, fmt.blue_shift }
        for channel = 1, 3 do
            local lut, max, shift = self.lut[channel], maxima[channel], shifts[channel]
            for v = 0, 255 do
                lut[v] = math.floor(v * max / 255 + 0.5) * 2 ^ shift
            end
        end
        -- For a 32bpp/depth<=24 format the CPIXEL is the pixel with its padding byte removed;
        -- the padding is whichever byte no channel occupies (RFC 6143 §7.7.6).
        if fmt.bits_per_pixel == 32 then
            local used = { false, false, false, false }
            for channel = 1, 3 do
                local byte = math.floor(shifts[channel] / 8)
                if byte >= 0 and byte < 4 then used[byte + 1] = true end
            end
            local cpixel = {}
            for i = 1, 4 do
                if used[i] then cpixel[#cpixel + 1] = i - 1 end
            end
            self.cpixel_bytes = (#cpixel == 3) and cpixel or nil
        else
            self.cpixel_bytes = nil
        end
    else
        self.cpixel_bytes = nil
    end
    logger.dbg("vnc: server encoder for", fmt.bits_per_pixel, "bpp,",
        true_colour and "true colour" or "colour mapped")
end

--- The client's encoding preference, filtered to what we can produce.
function Enc:set_encodings(encodings)
    self.encodings = encodings
end

--- Whether the client's list will need the per-pixel `values` array.
---
--- The list is in preference order and Raw is mandatory for every client, so the first entry of
--- the encodings we can actually reach decides: an encoder after a Raw entry never runs, and Raw
--- itself is happy with the byte string. Skipping the array matters for a Raw client - building it
--- is a pass over every pixel of the rectangle, and it is 4 bytes per pixel of allocation.
--- @tparam table|nil encodings
--- @treturn boolean
function Enc.needs_values(encodings)
    for _, encoding in ipairs(encodings or {}) do
        if encoding == Enc.RAW then return false end
        if encoding == Enc.ZRLE or encoding == Enc.HEXTILE or encoding == Enc.RRE then
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------- conversion

local function ensure_buffers(self, w, h, need_values)
    local bpp = math.floor(self.fmt.bits_per_pixel / 8)
    if self.bb24 == nil or self.bb24:getWidth() < w or self.bb24:getHeight() < h then
        if self.bb24 then self.bb24:free() end
        self.bb24 = BB.new(w, h, BB.TYPE_BBRGB24)
    end
    if need_values ~= false and (self.values == nil or (self.values_size or 0) < w * h) then
        -- FFI arrays are 0-based while the encoders index pixels 1..count, so one extra slot.
        self.values = ffi.new("uint32_t[?]", w * h + 1)
        self.values_size = w * h
    end
    local need = w * h * bpp
    if self.out == nil or (self.out_len or 0) < need then
        self.out = ffi.new("uint8_t[?]", need)
        self.out_len = need
    end
    return bpp
end

--[[--
The byte-aligned RGB copy: the RGB24 plane is already the pixel (only a 32bpp format's padding byte
differs), so the bytes go straight across. Four plain loops rather than one with the layout tests
inside: the tests are constant for the whole rectangle, and a loop that carries them does not
compile as well (measured 25 ns/pixel against 2-4 ns/pixel here).

Each helper is `(data, stride, out, [values,] w, h)`; the caller has already blitted the rectangle
into `self.bb24`, so `data`/`stride` describe that RGB24 buffer.
]]
local function rgb32_into(data, stride, out, w, h)          -- 32bpp, no values array
    for y = 0, h - 1 do
        local p = data + y * stride
        local o = y * w * 4
        for x = 0, w - 1 do
            out[o], out[o + 1], out[o + 2], out[o + 3] = p[0], p[1], p[2], 0
            p = p + 3
            o = o + 4
        end
    end
end

local function rgb32_values_into(data, stride, out, values, w, h)
    for y = 0, h - 1 do
        local p = data + y * stride
        local o = y * w * 4
        local vi = y * w + 1
        for x = 0, w - 1 do
            local r, g, b = p[0], p[1], p[2]
            out[o], out[o + 1], out[o + 2], out[o + 3] = r, g, b, 0
            values[vi + x] = r + g * 256 + b * 65536
            p = p + 3
            o = o + 4
        end
    end
end

local function rgb24_into(data, stride, out, w, h)          -- 24bpp, no values array
    for y = 0, h - 1 do
        local p = data + y * stride
        local o = y * w * 3
        for x = 0, w - 1 do
            out[o], out[o + 1], out[o + 2] = p[0], p[1], p[2]
            p = p + 3
            o = o + 3
        end
    end
end

local function rgb24_values_into(data, stride, out, values, w, h)
    for y = 0, h - 1 do
        local p = data + y * stride
        local o = y * w * 3
        local vi = y * w + 1
        for x = 0, w - 1 do
            local r, g, b = p[0], p[1], p[2]
            out[o], out[o + 1], out[o + 2] = r, g, b
            values[vi + x] = r + g * 256 + b * 65536
            p = p + 3
            o = o + 3
        end
    end
end

--[[--
Converts one screen rectangle into the client's pixel format.

Returns the byte string as it goes on the wire. When `need_values` is true, `self.values`
additionally holds one entry per pixel (the same value, unpacked into a Lua number) for the
encoders that have to compare pixels; when it is false, `self.values` is left as it was (an
encoding that does not need it never reads it, and the array is not even allocated).
]]
--- `need_values` may be false when the client's first encoding is Raw (c.f.,
--- @{Enc.needs_values}): the byte string is all that encoding needs, and the per-pixel array is a
--- whole extra pass and four bytes per pixel of allocation.
---
--- @tparam BlitBuffer source the screen being served
--- @tparam table rect `{x, y, w, h}` in screen coordinates
--- @tparam[opt=true] boolean need_values
--- @treturn string pixels, number count
function Enc:convert(source, rect, need_values)
    if need_values == nil then need_values = true end
    local w, h = rect.w, rect.h
    local bpp = ensure_buffers(self, w, h, need_values)
    local fmt = self.fmt
    local true_colour = fmt.true_colour ~= 0

    -- One cross-format blit, then everything below only ever sees [r, g, b] triples.
    self.bb24:blitFrom(source, 0, 0, rect.x, rect.y, w, h)
    local stride = self.bb24.stride
    local data = ffi.cast("const uint8_t*", self.bb24.data)

    local out, values = self.out, self.values
    local count = w * h

    -- The layout every viewer asks for (and the one ServerInit announces): 8 bits per channel, in
    -- byte order, so the RGB24 plane is *already* the pixel - only a 32bpp format's padding byte
    -- differs. Copy the bytes straight across instead of looking each channel up in a LUT and
    -- re-assembling the value with divisions; the general loop below stays for every other format.
    local byte_aligned = true_colour and fmt.big_endian == 0 and fmt.red_max == 255
        and fmt.green_max == 255 and fmt.blue_max == 255 and fmt.red_shift == 0
        and fmt.green_shift == 8 and fmt.blue_shift == 16 and (bpp == 3 or bpp == 4)
    if byte_aligned then
        if bpp == 4 then
            if need_values then
                rgb32_values_into(data, stride, out, values, w, h)
            else
                rgb32_into(data, stride, out, w, h)
            end
        elseif need_values then
            rgb24_values_into(data, stride, out, values, w, h)
        else
            rgb24_into(data, stride, out, w, h)
        end
        return ffi.string(out, count * bpp), count
    end

    if true_colour then
        local R, G, B = self.lut[1], self.lut[2], self.lut[3]
        local rs, gs, bs = fmt.red_shift, fmt.green_shift, fmt.blue_shift
        local be = fmt.big_endian ~= 0
        local i, pi = 0, 0
        for y = 0, h - 1 do
            local p = data + y * stride
            for _ = 0, w - 1 do
                local v = R[p[0]] + G[p[1]] + B[p[2]]
                p = p + 3
                pi = pi + 1
                -- May be nil: a client whose first encoding is Raw asked for the bytes only
                -- (c.f., @{Enc.needs_values}), and no encoder that reads the array can run then.
                if values then values[pi] = v end   -- 1-based, matching the encoders' loops
                if bpp == 4 then
                    -- build the little-endian bytes, then reverse for big-endian clients
                    local b0, b1 = v % 256, math.floor(v / 256) % 256
                    local b2, b3 = math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256
                    if be then
                        out[i] = b3 out[i + 1] = b2 out[i + 2] = b1 out[i + 3] = b0
                    else
                        out[i] = b0 out[i + 1] = b1 out[i + 2] = b2 out[i + 3] = b3
                    end
                elseif bpp == 3 then
                    local b0, b1 = v % 256, math.floor(v / 256) % 256
                    local b2 = math.floor(v / 65536) % 256
                    if be then
                        out[i] = b2 out[i + 1] = b1 out[i + 2] = b0
                    else
                        out[i] = b0 out[i + 1] = b1 out[i + 2] = b2
                    end
                elseif bpp == 2 then
                    local b0, b1 = v % 256, math.floor(v / 256) % 256
                    if be then
                        out[i] = b1 out[i + 1] = b0
                    else
                        out[i] = b0 out[i + 1] = b1
                    end
                else
                    out[i] = v % 256
                end
                i = i + bpp
            end
        end
    else
        -- colour mapped (8bpp): the 3-3-2 index of Enc.COLOUR_MAP
        local i, pi = 0, 0
        for y = 0, h - 1 do
            local p = data + y * stride
            for _ = 0, w - 1 do
                local idx = map_index(p[0], p[1], p[2])
                p = p + 3
                pi = pi + 1
                if values then values[pi] = idx end  -- 1-based; nil for a Raw-only client
                out[i] = idx
                i = i + 1
            end
        end
    end

    return ffi.string(out, count * bpp), count
end

--- The bytes of one pixel value (used for the few pixels an encoder emits individually).
function Enc:pixel_bytes(v)
    local bpp = math.floor(self.fmt.bits_per_pixel / 8)
    local b = self.pixel_buf
    if bpp == 4 then
        b[0], b[1] = v % 256, math.floor(v / 256) % 256
        b[2], b[3] = math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256
        if self.fmt.big_endian ~= 0 then b[0], b[1], b[2], b[3] = b[3], b[2], b[1], b[0] end
    elseif bpp == 3 then
        b[0], b[1] = v % 256, math.floor(v / 256) % 256
        b[2] = math.floor(v / 65536) % 256
        if self.fmt.big_endian ~= 0 then b[0], b[1], b[2] = b[2], b[1], b[0] end
    elseif bpp == 2 then
        b[0], b[1] = v % 256, math.floor(v / 256) % 256
        if self.fmt.big_endian ~= 0 then b[0], b[1] = b[1], b[0] end
    else
        b[0] = v % 256
    end
    return ffi.string(b, bpp)
end

--- The CPIXEL bytes of one pixel value (ZRLE/TRLE omit a 32bpp format's padding byte).
function Enc:cpixel_bytes_of(v)
    if not self.cpixel_bytes then
        return self:pixel_bytes(v)
    end
    local b = self.pixel_buf
    b[0], b[1] = v % 256, math.floor(v / 256) % 256
    b[2], b[3] = math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256
    local cp = self.cpixel_bytes
    return string.char(b[cp[1]], b[cp[2]], b[cp[3]])
end

-- ---------------------------------------------------------------- encoders

--[[--
Encodes one rectangle with the best encoding the client announced (its list is in preference
order), falling back to Raw.
]]
--- `converted` (optional) is a conversion of this same rectangle, in this encoder's pixel
--- format, made by another encoder ({ pixels = <string>, count = <number>, values = <array|nil> }).
--- The server hands one over when several clients of the same format are being served in the same
--- tick, so the per-pixel conversion is done once rather than once per client. It is only used
--- when it carries what this client's encodings need.
---
--- @treturn number encoding, string payload
function Enc:encode(source, rect, converted)
    local want_values = Enc.needs_values(self.encodings)
    local pixels, count, values
    if converted and (converted.values ~= nil or not want_values) then
        pixels, count, values = converted.pixels, converted.count, converted.values
    else
        pixels, count = self:convert(source, rect, want_values)
        -- The encoders compare pixels, so they work on the per-pixel value array; only Raw uses
        -- the byte string itself.
        values = self.values
    end
    for _, encoding in ipairs(self.encodings) do
        if encoding == Enc.ZRLE then
            local payload = self:encode_zrle(values, count, rect.w, rect.h)
            if payload then return Enc.ZRLE, payload end
        elseif encoding == Enc.HEXTILE then
            local payload = self:encode_hextile(values, count, rect.w, rect.h)
            if payload then return Enc.HEXTILE, payload end
        elseif encoding == Enc.RRE then
            local payload = self:encode_rre(values, count, rect.w, rect.h)
            if payload then return Enc.RRE, payload end
        elseif encoding == Enc.RAW then
            return Enc.RAW, pixels
        end
    end
    return Enc.RAW, pixels
end

--- The most frequent pixel value of a range, with its count.
local function dominant(values, from, to, scratch)
    local counts = scratch.counts
    local distinct = 0
    local best, best_count = values[from], 0
    for i = from, to do
        local v = values[i]
        local c = counts[v]
        if c == nil then
            c = 0
            distinct = distinct + 1
        end
        c = c + 1
        counts[v] = c
        if c > best_count then best, best_count = v, c end
    end
    -- clear for the next caller without allocating a new table
    for i = from, to do counts[values[i]] = nil end
    return best, best_count, distinct
end

--- Groups one row into runs of equal values, skipping the background.
--- @treturn table, number array of `{x, y, w, value}` (one pixel tall) and its length
local function row_runs(values, w, y, background, scratch)
    local runs = scratch.runs
    local n = 0
    local base = y * w
    local x = 0
    while x < w do
        local v = values[base + x + 1]
        local run = 1
        while x + run < w and values[base + x + run + 1] == v do
            run = run + 1
        end
        if v ~= background then
            n = n + 1
            local r = runs[n]
            if not r then r = {} runs[n] = r end
            r.x, r.y, r.w, r.value = x, y, run, v
        end
        x = x + run
    end
    return runs, n
end

local function new_scratch(w, h)
    return { counts = {}, runs = {} }
end

--[[--
RRE: one background pixel, then subrectangles of non-background pixels with their own pixel.

Runs are taken per row and extended downwards while the rows below match, which is what makes
this worthwhile on the large flat areas a reader UI has. If the result would not be smaller than
Raw, Raw is used instead (returning nil).
]]
function Enc:encode_rre(values, count, w, h)
    local scratch = self.scratch or new_scratch(w, h)
    self.scratch = scratch
    local background = dominant(values, 1, count, scratch)

    local subrects = {}
    local y = 0
    while y < h do
        local runs, n = row_runs(values, w, y, background, scratch)
        for i = 1, n do
            local r = runs[i]
            local height = 1
            -- extend downwards while the same run exists on the next row
            while y + height < h do
                local base = (y + height) * w
                local same = true
                for dx = 0, r.w - 1 do
                    if values[base + r.x + dx + 1] ~= r.value then same = false break end
                end
                if not same then break end
                height = height + 1
            end
            subrects[#subrects + 1] = { x = r.x, y = y, w = r.w, h = height, value = r.value }
        end
        y = y + 1
    end

    local bpp = math.floor(self.fmt.bits_per_pixel / 8)
    local estimated = 4 + bpp + #subrects * (bpp + 8)
    if estimated >= count * bpp then return nil end

    local out = Util.writer()
    out:u32(#subrects)
    out:raw(self:pixel_bytes(background))
    for _, s in ipairs(subrects) do
        out:raw(self:pixel_bytes(s.value))
        out:u16(s.x):u16(s.y):u16(s.w):u16(s.h)
    end
    return out:tostring()
end

--[[--
Hextile: 16x16 tiles. Uniform tiles cost one pixel, tiles with a dominant colour cost that plus
subrectangles, and anything that would not pay off is sent Raw.
]]
function Enc:encode_hextile(values, count, w, h)
    local scratch = self.scratch or new_scratch(w, h)
    self.scratch = scratch
    local out = Util.writer()
    local background, foreground          -- carried between tiles, per RFC 6143 §7.7.4
    local first_tile = true               -- ... but never assumed at the start of a rectangle

    local ty = 0
    while ty < h do
        local th = math.min(Enc.HEXTILE_SIZE, h - ty)
        local tx = 0
        while tx < w do
            local tw = math.min(Enc.HEXTILE_SIZE, w - tx)

            -- gather the tile's values
            local tile = scratch.tile
            if not tile then tile = {} scratch.tile = tile end
            local n = 0
            for y = 0, th - 1 do
                local base = (ty + y) * w + tx
                for x = 0, tw - 1 do
                    n = n + 1
                    tile[n] = values[base + x + 1]
                end
            end
            -- One call answers both questions: `bg` is the tile's most frequent value and
            -- `uniform_count` its count, which is the whole tile exactly when it is uniform. The
            -- second pass over the same range would recompute the first one's answer.
            local bg, uniform_count = dominant(tile, 1, n, scratch)
            local mask = 0
            local payload = Util.writer()

            if uniform_count == n then
                if first_tile or bg ~= background then
                    mask = mask + 2                          -- BackgroundSpecified
                    payload:raw(self:pixel_bytes(bg))
                end
                background = bg
                -- A tile with no subrects is entirely background.
            else
                -- subrectangles: one per run of equal pixels, keeping the tile's own geometry
                if first_tile or bg ~= background then
                    mask = mask + 2
                    payload:raw(self:pixel_bytes(bg))
                    background = bg
                end

                local runs = {}
                for y = 0, th - 1 do
                    local x = 0
                    while x < tw do
                        local v = tile[y * tw + x + 1]
                        local run = 1
                        while x + run < tw and tile[y * tw + x + run + 1] == v do run = run + 1 end
                        if v ~= background then
                            runs[#runs + 1] = { x = x, y = y, w = run, value = v }
                        end
                        x = x + run
                    end
                end

                -- if every subrect shares one colour, an uncoloured (foreground) tile is smaller
                local single = runs[1] and runs[1].value or nil
                for i = 2, #runs do
                    if runs[i].value ~= single then single = nil break end
                end
                if single then
                    -- Always specify it: the semantic is "carried over unless specified", but a
                    -- decoder that has not seen a foreground yet would have to reject the tile.
                    mask = mask + 4                          -- ForegroundSpecified
                    payload:raw(self:pixel_bytes(single))
                    foreground = single
                end
                if #runs > 0 then
                    local coloured = not single
                    mask = mask + 8                          -- AnySubrects
                    if coloured then mask = mask + 16 end    -- SubrectsColoured
                    payload:u8(#runs)
                    for _, r in ipairs(runs) do
                        if coloured then payload:raw(self:pixel_bytes(r.value)) end
                        payload:u8(((r.x % 16) * 16) + (r.y % 16))
                        payload:u8((((r.w - 1) % 16) * 16))
                    end
                end
            end
            out:u8(mask):raw(payload:tostring())
            first_tile = false
            tx = tx + tw
        end
        ty = ty + th
    end
    return out:tostring()
end

-- ---------------------------------------------------------------- ZRLE

--- Packs palette indices, MSB first, one row at a time, padded to whole bytes.
local function pack_indices(out, indices, w, bits)
    local per_byte = math.floor(8 / bits)
    local x = 0
    while x < w do
        local byte = 0
        for i = 0, per_byte - 1 do
            local idx = indices[x + i + 1]
            byte = byte * 2 ^ bits + (idx or 0)
        end
        out:u8(byte)
        x = x + per_byte
    end
end

--- One TRLE tile (the subencoding ZRLE is built from), for a 64x64 (or smaller) tile.
local function zrle_tile(self, out, tile, tw, th, scratch)
    local n = tw * th
    -- One call answers all three: the most frequent value, its count (the tile is solid exactly
    -- when that count is the whole tile) and how many distinct values there are.
    local uniform, uniform_count, distinct = dominant(tile, 1, n, scratch)
    if uniform_count == n then
        out:u8(1)                                            -- solid
        out:raw(self:cpixel_bytes_of(uniform))
        return
    end

    if distinct <= 16 then
        -- packed palette: subencoding = palette size, palette, then packed indices
        local palette = scratch.palette
        if not palette then palette = {} scratch.palette = palette end
        local index_of = scratch.index_of
        if not index_of then index_of = {} scratch.index_of = index_of end
        local size = 0
        for i = 1, n do
            local v = tile[i]
            if index_of[v] == nil then
                size = size + 1
                palette[size] = v
                index_of[v] = size
            end
        end
        out:u8(size)
        for i = 1, size do out:raw(self:cpixel_bytes_of(palette[i])) end
        local bits = (size == 2) and 1 or (size <= 4 and 2 or 4)
        local indices = scratch.indices
        if not indices then indices = {} scratch.indices = indices end
        for y = 0, th - 1 do
            for x = 0, tw - 1 do
                indices[x + 1] = index_of[tile[y * tw + x + 1]] - 1
            end
            pack_indices(out, indices, tw, bits)
        end
        for i = 1, size do index_of[palette[i]] = nil end
    else
        -- plain RLE: runs of equal pixels, length = 1 + sum of the length bytes (255 repeats)
        out:u8(128)
        local i = 1
        while i <= n do
            local v = tile[i]
            local run = 1
            while i + run <= n and tile[i + run] == v do run = run + 1 end
            out:raw(self:cpixel_bytes_of(v))
            local len = run - 1
            while len >= 255 do
                out:u8(255)
                len = len - 255
            end
            out:u8(len)
            i = i + run
        end
    end
end

--[[--
ZRLE: the rectangle's TRLE-style tile stream, compressed through the connection's zlib stream
with a Z_SYNC_FLUSH at the end, prefixed by its length.
]]
function Enc:encode_zrle(values, count, w, h)
    local scratch = self.scratch or new_scratch(w, h)
    self.scratch = scratch
    if not self.zstream then
        self.zstream = ZStream.new_deflate()
    end

    local raw = Util.writer()
    local tile = scratch.zrle_tile
    if not tile then tile = {} scratch.zrle_tile = tile end

    local tile_size = Enc.ZRLE_TILE
    local ty = 0
    while ty < h do
        local th = math.min(tile_size, h - ty)
        local tx = 0
        while tx < w do
            local tw = math.min(tile_size, w - tx)
            local n = 0
            for y = 0, th - 1 do
                local base = (ty + y) * w + tx
                for x = 0, tw - 1 do
                    n = n + 1
                    tile[n] = values[base + x + 1]
                end
            end
            zrle_tile(self, raw, tile, tw, th, scratch)
            tx = tx + tw
        end
        ty = ty + th
    end

    local compressed, err = self.zstream:deflate(raw:tostring())
    if not compressed then
        logger.warn("vnc: ZRLE compression failed:", err)
        return nil
    end
    local out = Util.writer()
    out:u32(#compressed):raw(compressed)
    return out:tostring()
end

return Enc

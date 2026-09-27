--[[--
Client pixel format and fast pixel-write helpers.

We ask the server for 32 bpp / depth 24 / little-endian true colour with
`red_shift=0, green_shift=8, blue_shift=16`. On the wire that puts R in the lowest
address byte, so

  * a 4-byte PIXEL (Raw/Hextile/RRE/Tight fill) is `[R, G, B, X]`
  * a 3-byte CPIXEL (TRLE/ZRLE/Tight) is `[R, G, B]`

and both map **directly** onto KOReader's `TYPE_BBRGB24` (`ColorRGB24 = {r, g, b}`), with no
byte swapping anywhere.

@module vnc.pxfmt
]]

local ffi = require("ffi")

local PxFmt = {}

--- The 16-byte PIXEL_FORMAT we send in SetPixelFormat.
PxFmt.PIXEL_FORMAT = {
    bits_per_pixel = 32,
    depth = 24,
    big_endian = 0,
    true_colour = 1,
    red_max = 255,
    green_max = 255,
    blue_max = 255,
    red_shift = 0,
    green_shift = 8,
    blue_shift = 16,
}

PxFmt.COLOR_DEPTH = 24
PxFmt.BYTES_PER_PIXEL = 4      -- PIXEL on the wire: [R, G, B, 0]
PxFmt.BYTES_PER_CPIXEL = 3     -- CPIXEL (TRLE/ZRLE/Tight): [R, G, B]

local uint8_t = ffi.typeof("uint8_t")
local uint8_ptr = ffi.typeof("uint8_t*")

--[[--
Writes one RGB pixel at `(x, y)` of BlitBuffer `vp` (`TYPE_BBRGB24`).
]]
function PxFmt.write_pixel(vp, x, y, r, g, b)
    local p = ffi.cast(uint8_ptr, vp.data) + y * vp.stride + x * 3
    p[0] = r
    p[1] = g
    p[2] = b
end

--[[--
Copies `count` packed `[R, G, B]` pixels from `row_ptr` to `vp` starting at `(x, y)`.
]]
function PxFmt.write_pixel_buffer(vp, x, y, row_ptr, count)
    local dst = ffi.cast(uint8_ptr, vp.data) + y * vp.stride + x * 3
    ffi.copy(dst, row_ptr, count * 3)
end

local fill_row, fill_row_len = nil, 0

--[[--
Fills a rect of `vp` with a solid colour, directly through the data pointer.
]]
function PxFmt.fill_rect(vp, x, y, w, h, r, g, b)
    if w <= 0 or h <= 0 then return end
    local base = ffi.cast(uint8_ptr, vp.data)
    local stride = vp.stride
    if w == 1 then
        for j = y, y + h - 1 do
            local p = base + j * stride + x * 3
            p[0], p[1], p[2] = r, g, b
        end
        return
    end
    if fill_row_len < w * 3 then
        fill_row = ffi.new("uint8_t[?]", w * 3)
        fill_row_len = w * 3
    end
    local row = fill_row
    for i = 0, w - 1 do
        row[i * 3] = r
        row[i * 3 + 1] = g
        row[i * 3 + 2] = b
    end
    for j = y, y + h - 1 do
        ffi.copy(base + j * stride + x * 3, row, w * 3)
    end
end

--[[--
Reads one PIXEL (4 bytes) from a big-endian byte string at 0-based offset, returning r, g, b.
]]
function PxFmt.pixel_from_string(s, off)
    return s:byte(off + 1), s:byte(off + 2), s:byte(off + 3)
end

PxFmt.uint8_t = uint8_t

return PxFmt

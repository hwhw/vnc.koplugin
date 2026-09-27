--[[--
Low-level helpers for the RFB protocol layer.

Byte reader/writer for the **protocol fields** (everything in RFB is big-endian on the
wire, with the sole exception of pixel payloads, which follow the negotiated
@{vncviewer.pxfmt|PIXEL_FORMAT}). Pixel data is never touched by these helpers.

@module vncviewer.util
]]

local ffi = require("ffi")
local bit = require("bit")

local lshift, rshift = bit.lshift, bit.rshift

local Util = {}

--[[--
Byte reader over an abstract transport.

`io.read(n)` must return exactly `n` bytes; it may yield (coroutine) or block, it is the
transport's business. All multi-byte accessors are big-endian.
]]
function Util.reader(io)
    return setmetatable({ io = io }, { __index = Util.Reader })
end

Util.Reader = {}

function Util.Reader:bytes(n)
    local s = self.io.read(n)
    if not s or #s ~= n then
        error(string.format("transport returned %d bytes, wanted %d", s and #s or -1, n), 2)
    end
    return s
end

function Util.Reader:u8()
    return self:bytes(1):byte(1)
end

function Util.Reader:u16()
    local a, b = self:bytes(2):byte(1, 2)
    return a * 256 + b
end

function Util.Reader:u32()
    local a, b, c, d = self:bytes(4):byte(1, 4)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

function Util.Reader:s32()
    local v = self:u32()
    if v >= 0x80000000 then v = v - 0x100000000 end
    return v
end

--[[--
Byte writer building client -> server messages. `:tostring()` yields the wire bytes.
]]
function Util.writer()
    return setmetatable({ buf = {} }, { __index = Util.Writer })
end

Util.Writer = {}

function Util.Writer:u8(v)
    self.buf[#self.buf + 1] = string.char(v % 256)
end

function Util.Writer:u16(v)
    v = v % 65536
    self.buf[#self.buf + 1] = string.char(math.floor(v / 256), v % 256)
end

function Util.Writer:u32(v)
    v = v % 4294967296
    local a = math.floor(v / 16777216) % 256
    local b = math.floor(v / 65536) % 256
    local c = math.floor(v / 256) % 256
    self.buf[#self.buf + 1] = string.char(a, b, c, v % 256)
end

function Util.Writer:raw(s)
    self.buf[#self.buf + 1] = s
end

function Util.Writer:tostring()
    return table.concat(self.buf)
end

--[[--
Splits a string into UTF-8 characters.

Reuses `util.splitToChars` from `frontend/util.lua` (loaded lazily so the protocol layer
stays usable in a bare LuaJIT harness).
]]
function Util.split_chars(str)
    if not Util._splitToChars then
        Util._splitToChars = require("util").splitToChars
    end
    return Util._splitToChars(str)
end

--[[--
A reader over an in-memory byte string (used for ZRLE's inflated tile stream).
]]
function Util.mem_reader(str)
    local pos = 1
    return Util.reader({
        read = function(n)
            local s = str:sub(pos, pos + n - 1)
            pos = pos + n
            return s
        end,
    })
end

--[[--
Bounding union of two `{x, y, w, h}` rects (either may be nil).
]]
function Util.union_rect(a, b)
    if not a then return b end
    if not b then return a end
    local x1 = math.min(a.x, b.x)
    local y1 = math.min(a.y, b.y)
    local x2 = math.max(a.x + a.w, b.x + b.w)
    local y2 = math.max(a.y + a.h, b.y + b.h)
    return { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

--[[--
Intersection of a `{x, y, w, h}` rect with another; nil when they do not overlap.
]]
function Util.intersect_rect(a, b)
    local x1 = math.max(a.x, b.x)
    local y1 = math.max(a.y, b.y)
    local x2 = math.min(a.x + a.w, b.x + b.w)
    local y2 = math.min(a.y + a.h, b.y + b.h)
    if x2 <= x1 or y2 <= y1 then return nil end
    return { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

--[[--
Coerces the many ways a boolean can arrive (real booleans, 0/1, "0"/"1" from URI or
Dispatcher callers) into a `0`/`1` wire bit.
]]
function Util.bool_to_bit(value)
    if value == nil or value == false or value == 0 or value == "0" or value == "" then
        return 0
    end
    return 1
end

--- Big-endian 16-bit read from a Lua string at 0-based byte offset.
function Util.get_u16be(s, off)
    local a, b = s:byte(off + 1, off + 2)
    return a * 256 + b
end

--- Big-endian 32-bit read from a Lua string at 0-based byte offset.
function Util.get_u32be(s, off)
    local a, b, c, d = s:byte(off + 1, off + 4)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

Util.lshift, Util.rshift = lshift, rshift
Util.ffi = ffi

return Util

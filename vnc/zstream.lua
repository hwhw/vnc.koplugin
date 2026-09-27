--[[--
Stateful zlib wrapper: `inflate` for the RFB client, `deflate` for the RFB server.

KOReader's @{ffi.zlib} only exposes the one-shot `uncompress()`, which cannot be used for
RFB: ZRLE and Tight keep **one zlib stream alive for the whole connection**, and a tile's
compressed block never ends the stream (the server flushes with `Z_SYNC_FLUSH`). So we
cdef the streaming `z_stream` API here and keep one stream per RFB zlib stream id.

`ZStream.new()` makes an inflating stream, `ZStream.new_deflate(level)` a deflating one; both
survive the whole connection and neither ends the stream on a flush.

@module vnc.zstream
]]

local ffi = require("ffi")
require("ffi/loadlib")

ffi.cdef[[
typedef struct z_stream_s {
  const uint8_t *next_in; unsigned int avail_in; unsigned long total_in;
  uint8_t *next_out; unsigned int avail_out; unsigned long total_out; const char *msg;
  void *state; void *(*zalloc)(void*,unsigned,unsigned); void (*zfree)(void*,void*); void *opaque;
  int data_type; unsigned long adler; unsigned long reserved;
} z_stream;
int inflateInit_(z_stream*, const char*, int);
int inflate(z_stream*, int);
int inflateEnd(z_stream*);
int deflateInit_(z_stream*, int, const char*, int);
int deflate(z_stream*, int);
int deflateEnd(z_stream*);
]]

-- Same call as ffi/zlib.lua, so Android's monolibtic redirection of "z" keeps working.
local libz = ffi.loadlib("z", 1)

local Z_OK = 0
local Z_STREAM_END = 1
local Z_BUF_ERROR = -5
local Z_SYNC_FLUSH = 2
local Z_DEFAULT_COMPRESSION = -1

local z_stream_p = ffi.typeof("z_stream*")
local z_stream_sz = ffi.sizeof("z_stream")

-- zlib only compares the major version ("1"), the minor/patch part is informational.
local ZLIB_VERSION_STR = "1.2.11"

local ZStream = {}
ZStream.__index = ZStream

ZStream.Z_OK = Z_OK
ZStream.Z_STREAM_END = Z_STREAM_END
ZStream.Z_BUF_ERROR = Z_BUF_ERROR
ZStream.Z_SYNC_FLUSH = Z_SYNC_FLUSH

--- Creates a stream with `inflateInit_` already called.
function ZStream.new()
    local self = setmetatable({ mode = "inflate" }, ZStream)
    self.strm = ffi.new("z_stream[1]")
    local res = libz.inflateInit_(self.strm, ZLIB_VERSION_STR, z_stream_sz)
    assert(res == Z_OK, "inflateInit_ failed: " .. tostring(res))
    self.active = true
    return self
end

--- Creates a stream with `deflateInit_` already called (used by the server's ZRLE encoder).
--- @tparam[opt=-1] number level zlib compression level
function ZStream.new_deflate(level)
    local self = setmetatable({ mode = "deflate" }, ZStream)
    self.strm = ffi.new("z_stream[1]")
    self.level = level or Z_DEFAULT_COMPRESSION
    local res = libz.deflateInit_(self.strm, self.level, ZLIB_VERSION_STR, z_stream_sz)
    assert(res == Z_OK, "deflateInit_ failed: " .. tostring(res))
    self.active = true
    return self
end

--- Ends the stream and starts a fresh one (RFB zlib "reset stream" control bit).
function ZStream:reset()
    if self.mode == "deflate" then
        self:free()
        local res = libz.deflateInit_(self.strm, self.level, ZLIB_VERSION_STR, z_stream_sz)
        assert(res == Z_OK, "deflateInit_ failed: " .. tostring(res))
        self.active = true
        return
    end
    if self.active then
        libz.inflateEnd(self.strm)
        self.active = false
    end
    local res = libz.inflateInit_(self.strm, ZLIB_VERSION_STR, z_stream_sz)
    assert(res == Z_OK, "inflateInit_ failed: " .. tostring(res))
    self.active = true
end

--[[--
Feeds `data` (may be nil/empty for a bare drain) and returns every byte the stream produced.

The stream is *not* finished: ZRLE/Tight blocks end with a sync flush, not with a stream
end, so we drain until the input is consumed and no more output can be produced.
]]
--- @tparam string|nil data
--- @treturn string|nil, string|nil output, or nil plus an error message
function ZStream:inflate(data)
    local strm = self.strm[0]
    strm.next_in = data and ffi.cast("const uint8_t*", data) or nil
    strm.avail_in = data and #data or 0

    local chunks = {}
    local bufsize = 65536
    local iterations = 0
    while true do
        iterations = iterations + 1
        if iterations > 24 then
            return nil, "zlib produced an unreasonable amount of output (possible loop)"
        end
        local buf = ffi.new("uint8_t[?]", bufsize)
        strm.next_out = buf
        strm.avail_out = bufsize
        local res = libz.inflate(strm, Z_SYNC_FLUSH)
        local produced = bufsize - strm.avail_out
        if produced > 0 then
            chunks[#chunks + 1] = ffi.string(buf, produced)
        end
        if res == Z_STREAM_END then
            break
        elseif res ~= Z_OK and res ~= Z_BUF_ERROR then
            return nil, string.format("zlib error %d (%s)", res,
                strm.msg ~= nil and ffi.string(strm.msg) or "no message")
        end
        if strm.avail_out == 0 then
            -- Output buffer was filled: grow and keep going (there may be input left).
            bufsize = bufsize * 2
        elseif strm.avail_in == 0 then
            -- Input consumed, stream still open at a flush point: done.
            break
        elseif produced == 0 then
            -- No progress possible (Z_BUF_ERROR with data left): stop to avoid spinning.
            break
        end
    end
    return table.concat(chunks)
end

--[[--
Feeds `data` and returns the bytes zlib produced, ending with a `Z_SYNC_FLUSH` marker.

That marker is what an RFB zlib stream needs at the end of every ZRLE/Tight block: the stream
stays open (and keeps its compression history) but everything written so far becomes available to
the decoder.
]]
--- @tparam string data
--- @treturn string|nil, string|nil output, or nil plus an error message
function ZStream:deflate(data)
    local strm = self.strm[0]
    strm.next_in = ffi.cast("const uint8_t*", data)
    strm.avail_in = #data

    local chunks = {}
    local bufsize = 65536
    local iterations = 0
    while true do
        iterations = iterations + 1
        if iterations > 64 then
            return nil, "zlib deflate did not settle (possible loop)"
        end
        local buf = ffi.new("uint8_t[?]", bufsize)
        strm.next_out = buf
        strm.avail_out = bufsize
        local res = libz.deflate(strm, Z_SYNC_FLUSH)
        local produced = bufsize - strm.avail_out
        if produced > 0 then
            chunks[#chunks + 1] = ffi.string(buf, produced)
        end
        if res ~= Z_OK then
            return nil, string.format("zlib error %d (%s)", res,
                strm.msg ~= nil and ffi.string(strm.msg) or "no message")
        end
        -- With Z_SYNC_FLUSH, deflate consumes all input and leaves the output buffer unfilled
        -- once the flush marker has been written.
        if strm.avail_in == 0 and strm.avail_out > 0 then
            return table.concat(chunks)
        end
        if strm.avail_out == 0 then
            bufsize = bufsize * 2
        end
    end
end

--- Releases the stream.
function ZStream:free()
    if self.active then
        if self.mode == "deflate" then
            libz.deflateEnd(self.strm)
        else
            libz.inflateEnd(self.strm)
        end
        self.active = false
    end
    self.strm = nil
end

return ZStream

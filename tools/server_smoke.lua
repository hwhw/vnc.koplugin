#!/usr/bin/env luajit
--[[--
Standalone test harness for the vnc **server** side: the pixel-format conversion and the
Raw/RRE/Hextile/ZRLE encoders in @{vnc.serverenc}.

Everything here is in-process: each encoding is produced by the server encoder and immediately
decoded by the (independently written) client decoders in @{vnc.encodings}, then compared
pixel by pixel against the plane that was encoded. That makes the server's wire format testable
without a server, a socket or a client - and it is the same contract the client side is tested
against a real RFB server.

Run with KOReader's own LuaJIT from the KOReader root:

  cd /usr/lib/koreader
  PLUGIN=~/.config/koreader/plugins/vnc.koplugin
  LUA_PATH="$PLUGIN/?.lua;./common/?.lua;./common/?/init.lua;;" \
  LUA_CPATH="./common/?.so;;" \
  ./luajit "$PLUGIN/tools/server_smoke.lua"
]]

dofile("setupkoenv.lua")

-- Like the UI suite: KOReader's widget stack, its settings singletons and a data directory are
-- needed here too, because the runtime checks serve the real screen and inject real input.
local lfs = require("libs/libkoreader-lfs")
local data_dir = os.getenv("KO_HOME") or "/tmp/vncv_server_home"
if lfs.attributes(data_dir, "mode") ~= "directory" then
    lfs.mkdir(data_dir)
end
if lfs.attributes(data_dir .. "/cache", "mode") ~= "directory" then
    lfs.mkdir(data_dir .. "/cache")
end
_G.G_reader_settings = require("luasettings"):open(data_dir .. "/server_smoke_settings.lua")
_G.G_reader_settings:flush()
_G.G_defaults = require("luasettings"):wrap(dofile("defaults.lua"))

local Device = require("device")
require("document/canvascontext"):init(Device)

local ffi = require("ffi")

local BB = require("ffi/blitbuffer")

local Encodings = require("vnc/encodings")
local Protocol = require("vnc/protocol")
local RfbServer = require("vnc/rfbserver")
local ServerEnc = require("vnc/serverenc")
local Screen = Device.screen
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Util = require("vnc/util")

-- Unbuffered: a crash in a check must not swallow the reports that came before it.
io.stdout:setvbuf("no")

local checks, failures = 0, 0

local function check(name, fn)
    checks = checks + 1
    local ok, err = pcall(fn)
    if ok then
        print("ok - " .. name)
    else
        failures = failures + 1
        print(string.format("FAIL: %s: %s", name, tostring(err)))
    end
end

local function assert_true(cond, msg)
    if not cond then error(msg or "assertion failed", 2) end
end

-- ---------------------------------------------------------------- helpers

--- A plane filled with a pattern that exercises every encoder path:
--- flat areas, two/four/nine-colour tiles (the packed-palette bit widths), a gradient and noise.
local function put(bb, x, y, r, g, b)
    local data = ffi.cast("uint8_t*", bb.data) + y * bb.stride + x * 3
    data[0], data[1], data[2] = r, g, b
end

local function get(bb, x, y)
    local data = ffi.cast("uint8_t*", bb.data) + y * bb.stride + x * 3
    return data[0], data[1], data[2]
end

local function pattern_plane(w, h)
    local bb = BB.new(w, h, BB.TYPE_BBRGB24)
    local colors = {
        { 255, 0, 0 }, { 0, 255, 0 }, { 0, 0, 255 }, { 255, 255, 255 },
        { 0, 0, 0 }, { 255, 255, 0 }, { 0, 255, 255 }, { 255, 0, 255 }, { 128, 128, 128 },
    }
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local tile = math.floor(x / 64) + math.floor(y / 64) * math.ceil(w / 64)
            local r, g, b
            if tile == 0 then
                r, g, b = 255, 0, 0                                  -- solid
            elseif tile == 1 then
                local c = colors[(x + y) % 2 + 1]                     -- 2 colours -> 1 bit palette
                r, g, b = c[1], c[2], c[3]
            elseif tile == 2 then
                local c = colors[(math.floor(x / 2) % 2) + (math.floor(y / 2) % 2) * 2 + 1]
                r, g, b = c[1], c[2], c[3]                            -- 4 colours -> 2 bit palette
            elseif tile == 3 then
                local c = colors[(math.floor(x / 3) % 3) + (math.floor(y / 3) % 3) * 3 + 1]
                r, g, b = c[1], c[2], c[3]                            -- 9 colours -> 4 bit palette
            elseif tile == 4 then
                r, g, b = x % 256, (x + y) % 256, y % 256             -- gradient -> RLE
            else
                r, g, b = (x * 7 + y * 13) % 256, (x * 3 + y * 5) % 256, (x + y * 2) % 256
            end
            put(bb, x, y, r, g, b)
        end
    end
    return bb
end

local function pixels_equal(a, b, w, h)
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local ar, ag, ab = get(a, x, y)
            local br, bg, bb2 = get(b, x, y)
            if ar ~= br or ag ~= bg or ab ~= bb2 then
                return false, string.format("(%d,%d): %d,%d,%d vs %d,%d,%d", x, y, ar, ag, ab, br, bg, bb2)
            end
        end
    end
    return true
end

--- Whether `rects` covers the rectangle (0,0,w,h) exactly - no gap, no overlap.
---
--- A client that asked for a region is owed every pixel of it, but the server may carry a large
--- rectangle there as several (c.f., `Server.ENCODE_RECT_LIMIT`, which keeps the encoders that walk
--- every pixel from handing one rectangle to the whole screen's worth of work at once), so the
--- checks that care about *which region* arrived assert coverage rather than one rectangle.
--- @treturn boolean, string|nil
local function rects_cover(rects, w, h)
    local spans = {}
    for y = 0, h - 1 do spans[y] = {} end
    for _, r in ipairs(rects) do
        if r.x < 0 or r.y < 0 or r.w <= 0 or r.h <= 0 or r.x + r.w > w or r.y + r.h > h then
            return false, string.format("rectangle %d,%d %dx%d is not inside %dx%d",
                r.x, r.y, r.w, r.h, w, h)
        end
        for y = r.y, r.y + r.h - 1 do
            local row = spans[y]
            row[#row + 1] = { r.x, r.x + r.w }
        end
    end
    for y = 0, h - 1 do
        local row = spans[y]
        table.sort(row, function(a, b) return a[1] < b[1] end)
        local next_x = 0
        for _, span in ipairs(row) do
            if span[1] ~= next_x then
                return false, string.format("row %d is covered up to x=%d, the next rectangle starts at %d",
                    y, next_x, span[1])
            end
            next_x = span[2]
        end
        if next_x ~= w then
            return false, string.format("row %d is covered up to x=%d of %d", y, next_x, w)
        end
    end
    return true
end

--- The client pixel format this plugin's own client negotiates (32bpp, RGB in the low bytes).
local CLIENT_FORMAT = {
    bits_per_pixel = 32, depth = 24, big_endian = 0, true_colour = 1,
    red_max = 255, green_max = 255, blue_max = 255,
    red_shift = 0, green_shift = 8, blue_shift = 16,
}

local function encode(encoding, src, fmt, rect)
    local enc = ServerEnc.new()
    enc:set_pixel_format(fmt or CLIENT_FORMAT)
    enc:set_encodings({ encoding })
    local got_encoding, payload = enc:encode(src, rect or { x = 0, y = 0, w = src:getWidth(), h = src:getHeight() })
    return got_encoding, payload, enc
end

--- Decodes `payload` with the client-side decoders into a fresh plane of w x h.
local function decode(encoding, payload, w, h, streams)
    local dst = BB.new(w, h, BB.TYPE_BBRGB24)
    local ctx = {
        encoding = encoding,
        r = Util.mem_reader(payload),
        vp = dst:viewport(0, 0, w, h),
        plane = dst,
        x = 0, y = 0, w = w, h = h,
        streams = streams or Encodings.new_streams(),
    }
    local ok, err = Encodings.decode(ctx)
    assert_true(ok, "decoding failed: " .. tostring(err))
    return dst
end

-- ---------------------------------------------------------------- pixel formats

check("format_32bpp_matches_the_client_layout", function()
    local src = BB.new(3, 1, BB.TYPE_BBRGB24)
    put(src, 0, 0, 255, 0, 0)
    put(src, 1, 0, 0, 255, 0)
    put(src, 2, 0, 0, 0, 255)
    local encoding, payload, enc = encode(ServerEnc.RAW, src)
    assert_true(encoding == ServerEnc.RAW, "Raw expected")
    assert_true(payload == string.char(0xFF, 0, 0, 0, 0, 0xFF, 0, 0, 0, 0, 0xFF, 0),
        "32bpp RGB in the low bytes with a zero pad byte, got " ..
        (payload:gsub(".", function(c) return string.format("%02X", c:byte()) end)))
    enc:free()
    src:free()
end)

check("format_16bpp_565", function()
    local src = BB.new(3, 1, BB.TYPE_BBRGB24)
    put(src, 0, 0, 255, 0, 0)
    put(src, 1, 0, 0, 255, 0)
    put(src, 2, 0, 0, 0, 255)
    local fmt = {
        bits_per_pixel = 16, depth = 16, big_endian = 0, true_colour = 1,
        red_max = 31, green_max = 63, blue_max = 31,
        red_shift = 11, green_shift = 5, blue_shift = 0,
    }
    local _, payload, enc = encode(ServerEnc.RAW, src, fmt)
    -- F800 / 07E0 / 001F, little endian
    assert_true(payload == string.char(0x00, 0xF8, 0xE0, 0x07, 0x1F, 0x00), "565 little endian, got " ..
        (payload:gsub(".", function(c) return string.format("%02X", c:byte()) end)))
    enc:free()
    src:free()
end)

check("format_16bpp_big_endian_555", function()
    local src = BB.new(1, 1, BB.TYPE_BBRGB24)
    put(src, 0, 0, 255, 0, 0)
    local fmt = {
        bits_per_pixel = 16, depth = 15, big_endian = 1, true_colour = 1,
        red_max = 31, green_max = 31, blue_max = 31,
        red_shift = 10, green_shift = 5, blue_shift = 0,
    }
    local _, payload, enc = encode(ServerEnc.RAW, src, fmt)
    assert_true(payload == string.char(0x7C, 0x00), "7C00 big endian, got " ..
        (payload:gsub(".", function(c) return string.format("%02X", c:byte()) end)))
    enc:free()
    src:free()
end)

check("format_24bpp", function()
    local src = BB.new(2, 1, BB.TYPE_BBRGB24)
    put(src, 0, 0, 0x12, 0x34, 0x56)
    put(src, 1, 0, 255, 255, 255)
    local fmt = {
        bits_per_pixel = 24, depth = 24, big_endian = 0, true_colour = 1,
        red_max = 255, green_max = 255, blue_max = 255,
        red_shift = 16, green_shift = 8, blue_shift = 0,
    }
    local _, payload, enc = encode(ServerEnc.RAW, src, fmt)
    -- red_shift=16 puts red in the most significant byte, so the little-endian bytes of #123456
    -- are 56 34 12 (this is what a 24bpp client asking for RGB-by-shift sees).
    assert_true(payload == string.char(0x56, 0x34, 0x12, 0xFF, 0xFF, 0xFF), "24bpp, got " ..
        (payload:gsub(".", function(c) return string.format("%02X", c:byte()) end)))
    enc:free()
    src:free()
end)

check("format_8bpp_colour_map", function()
    local src = BB.new(3, 1, BB.TYPE_BBRGB24)
    put(src, 0, 0, 255, 0, 0)
    put(src, 1, 0, 0, 255, 0)
    put(src, 2, 0, 0, 0, 255)
    local fmt = {
        bits_per_pixel = 8, depth = 8, big_endian = 0, true_colour = 0,
        red_max = 7, green_max = 7, blue_max = 3,
        red_shift = 5, green_shift = 2, blue_shift = 0,
    }
    local _, payload, enc = encode(ServerEnc.RAW, src, fmt)
    -- 3-3-2 indices: red 224, green 28, blue 3
    assert_true(payload == string.char(224, 28, 3), "3-3-2 indices, got " ..
        (payload:gsub(".", function(c) return string.format("%02X", c:byte()) end)))
    local map = ServerEnc.COLOUR_MAP
    assert_true(#map == 256, "the colour map must have 256 entries")
    assert_true(map[225][1] == 255 and map[225][2] == 0 and map[225][3] == 0, "entry 224 is red")
    assert_true(map[29][2] == 255 and map[29][1] == 0, "entry 28 is green")
    assert_true(map[4][3] == 255 and map[4][1] == 0, "entry 3 is blue")
    enc:free()
    src:free()
end)

--- `convert` can be asked for the byte string alone: a client whose first encoding is Raw does not
--- need the per-pixel array, and building it is a second pass over every pixel and four bytes per
--- pixel of allocation. The bytes must be the same either way - and no array may be allocated -
--- for *every* format, not just the byte-aligned one the fast path handles: a layout the fast path
--- does not take still has to write the array only when it is there (it used to write it blindly,
--- which is what the 16bpp/24bpp/colour-map checks caught).
check("converting_without_the_pixel_array_matches_every_format", function()
    local formats = {
        { "32bpp", CLIENT_FORMAT },
        { "32bpp big endian", { bits_per_pixel = 32, depth = 24, big_endian = 1, true_colour = 1,
            red_max = 255, green_max = 255, blue_max = 255,
            red_shift = 0, green_shift = 8, blue_shift = 16 } },
        { "16bpp 565", { bits_per_pixel = 16, depth = 16, big_endian = 0, true_colour = 1,
            red_max = 31, green_max = 63, blue_max = 31,
            red_shift = 11, green_shift = 5, blue_shift = 0 } },
        { "16bpp big endian 555", { bits_per_pixel = 16, depth = 15, big_endian = 1,
            true_colour = 1, red_max = 31, green_max = 31, blue_max = 31,
            red_shift = 10, green_shift = 5, blue_shift = 0 } },
        { "24bpp", { bits_per_pixel = 24, depth = 24, big_endian = 0, true_colour = 1,
            red_max = 255, green_max = 255, blue_max = 255,
            red_shift = 16, green_shift = 8, blue_shift = 0 } },
        { "24bpp big endian", { bits_per_pixel = 24, depth = 24, big_endian = 1, true_colour = 1,
            red_max = 255, green_max = 255, blue_max = 255,
            red_shift = 0, green_shift = 8, blue_shift = 16 } },
        { "8bpp colour map", { bits_per_pixel = 8, depth = 8, big_endian = 0, true_colour = 0,
            red_max = 7, green_max = 7, blue_max = 3,
            red_shift = 5, green_shift = 2, blue_shift = 0 } },
    }
    local src = pattern_plane(7, 5)
    local rect = { x = 0, y = 0, w = 7, h = 5 }
    for _, entry in ipairs(formats) do
        local name, fmt = entry[1], entry[2]
        local wanted = ServerEnc.new()
        wanted:set_pixel_format(fmt)
        local bytes_wanted = wanted:convert(src, rect, true)
        assert_true(wanted.values ~= nil, name .. ": the array must be built when it is wanted")
        local unwanted = ServerEnc.new()
        unwanted:set_pixel_format(fmt)
        local bytes_unwanted = unwanted:convert(src, rect, false)
        assert_true(bytes_unwanted == bytes_wanted, string.format(
            "%s: the bytes must not depend on whether the per-pixel array is built (%d vs %d bytes)",
            name, #bytes_unwanted, #bytes_wanted))
        assert_true(unwanted.values == nil, name .. ": no array may be allocated when it is not wanted")
        wanted:free()
        unwanted:free()
    end
    src:free()
end)

-- ---------------------------------------------------------------- encoders

for _, case in ipairs({
    { name = "raw", encoding = ServerEnc.RAW, expect = ServerEnc.RAW },
    { name = "rre", encoding = ServerEnc.RRE, expect = ServerEnc.RRE },
    { name = "hextile", encoding = ServerEnc.HEXTILE, expect = ServerEnc.HEXTILE },
    { name = "zrle", encoding = ServerEnc.ZRLE, expect = ServerEnc.ZRLE },
}) do
    check("encoding_" .. case.name .. "_round_trip", function()
        local w, h = 192, 128
        local src = pattern_plane(w, h)
        local encoding, payload = encode(case.encoding, src)
        -- RRE legitimately falls back to Raw when subrectangles would not be smaller (this
        -- pattern has gradient and noise tiles); the round trip below is what must hold.
        assert_true(encoding == case.expect or (case.encoding == ServerEnc.RRE and encoding == ServerEnc.RAW),
            string.format("expected encoding %d, got %d", case.expect, encoding))
        local dst = decode(encoding, payload, w, h)
        local same, detail = pixels_equal(src, dst, w, h)
        assert_true(same, "decoded pixels differ: " .. tostring(detail))
        dst:free()
        src:free()
        print(string.format("     %s: %d bytes for %dx%d", case.name, #payload, w, h))
    end)
end

check("rre_beats_raw_on_flat_content", function()
    -- A reader UI is mostly flat areas and text: RRE must choose its subrectangles there and be
    -- smaller than Raw.
    local w, h = 128, 96
    local src = BB.new(w, h, BB.TYPE_BBRGB24)
    for y = 0, h - 1 do for x = 0, w - 1 do put(src, x, y, 255, 255, 255) end end
    for _, rect in ipairs({ { 8, 8, 60, 6 }, { 8, 20, 100, 4 }, { 40, 40, 30, 30 } }) do
        for y = rect[2], rect[2] + rect[4] - 1 do
            for x = rect[1], rect[1] + rect[3] - 1 do put(src, x, y, 0, 0, 0) end
        end
    end
    local encoding, payload = encode(ServerEnc.RRE, src)
    assert_true(encoding == ServerEnc.RRE, "RRE must win on flat content, got " .. encoding)
    assert_true(#payload < w * h * 4 / 4, "RRE must be much smaller than Raw, got " .. #payload)
    local dst = decode(encoding, payload, w, h)
    local same, detail = pixels_equal(src, dst, w, h)
    assert_true(same, "decoded pixels differ: " .. tostring(detail))
    dst:free()
    src:free()
end)

check("zrle_stream_continuity", function()
    -- One encoder (and therefore one zlib stream) across several rectangles, decoded in order by
    -- one client decoder state: this is what breaks if either side mishandles Z_SYNC_FLUSH.
    local enc = ServerEnc.new()
    enc:set_pixel_format(CLIENT_FORMAT)
    enc:set_encodings({ ServerEnc.ZRLE })
    local streams = Encodings.new_streams()
    local w, h = 96, 64
    local src = pattern_plane(w, h)
    for i = 1, 6 do
        local rect = { x = 0, y = 0, w = w, h = h }
        local encoding, payload = enc:encode(src, rect)
        assert_true(encoding == ServerEnc.ZRLE, "ZRLE expected on pass " .. i)
        local dst = decode(encoding, payload, w, h, streams)
        local same, detail = pixels_equal(src, dst, w, h)
        assert_true(same, string.format("pass %d differs: %s", i, tostring(detail)))
        dst:free()
    end
    enc:free()
    src:free()
end)

check("encoders_fall_back_to_raw_for_one_pixel_rects", function()
    -- The encoders must never produce something bigger than Raw for a tiny rectangle; at the very
    -- least they must stay correct.
    local src = BB.new(1, 1, BB.TYPE_BBRGB24)
    put(src, 0, 0, 0x20, 0x40, 0x60)
    for _, encoding in ipairs({ ServerEnc.RRE, ServerEnc.HEXTILE, ServerEnc.ZRLE }) do
        local got, payload = encode(encoding, src)
        local dst = decode(got, payload, 1, 1)
        local same = pixels_equal(src, dst, 1, 1)
        assert_true(same, "1x1 rect through encoding " .. encoding)
        dst:free()
    end
    src:free()
end)

check("encoder_survives_reuse", function()
    -- The server reuses one encoder for the whole connection: buffers must not leak state between
    -- rectangles of different sizes.
    local enc = ServerEnc.new()
    enc:set_pixel_format(CLIENT_FORMAT)
    enc:set_encodings({ ServerEnc.ZRLE, ServerEnc.HEXTILE, ServerEnc.RRE, ServerEnc.RAW })
    local streams = Encodings.new_streams()
    for _, size in ipairs({ { 192, 128 }, { 5, 3 }, { 64, 64 }, { 1, 7 }, { 130, 20 } }) do
        local w, h = size[1], size[2]
        local src = pattern_plane(w, h)
        local encoding, payload = enc:encode(src, { x = 0, y = 0, w = w, h = h })
        local dst = decode(encoding, payload, w, h, streams)
        local same, detail = pixels_equal(src, dst, w, h)
        assert_true(same, string.format("%dx%d (%d) differs: %s", w, h, encoding, tostring(detail)))
        dst:free()
        src:free()
    end
    enc:free()
end)

--- Waits that must not depend on how fast the server reads: see @{pump_until} and
--- @{step_for} - both are defined here because the first check below uses them.
--- Pumps `step` until `cond()` holds, bounded by `seconds` of *wall clock*.
---
--- Never by a poll count: what one poll gets through depends on the server's own pacing (how much
--- it reads per poll, how long a poll's work takes, what the client sent in one write), so a count
--- that happens to match one machine's speed is what makes a check fail on a slower one. The poll
--- count comes back so a check can put it in its message.
--- @treturn boolean, number whether the condition held, and the polls it took
local function pump_until(step, seconds, cond)
    local socket = require("socket")
    local deadline = socket.gettime() + (seconds or 5)
    local polls = 0
    while true do
        polls = polls + 1
        step()
        if cond() then return true, polls end
        if socket.gettime() >= deadline then return false, polls end
        socket.sleep(0.01)
    end
end

--- Runs `step` for `seconds` of wall clock. For a check that asserts something did *not* happen:
--- the wait has to be long enough for it to have happened, and that is a matter of time, not of a
--- poll count.
local function step_for(step, seconds)
    local socket = require("socket")
    local deadline = socket.gettime() + seconds
    while socket.gettime() < deadline do step() end
end

-- ---------------------------------------------------------------- the server protocol and runtime

--- A side of the in-process byte pump: an object with `step()`, plus what it has written.
local function side(obj)
    return { obj = obj, out = {}, out_len = 0, want = nil }
end

local function take_bytes(from, n)
    local parts, got = {}, 0
    while got < n do
        local chunk = table.remove(from.out, 1)
        assert_true(chunk ~= nil, "the peer wrote less than it was asked for")
        local want = math.min(#chunk, n - got)
        parts[#parts + 1] = chunk:sub(1, want)
        got = got + want
        if want < #chunk then table.insert(from.out, 1, chunk:sub(want + 1)) end
    end
    from.out_len = from.out_len - n
    return table.concat(parts)
end

--- Alternates steps until both sides are blocked (or the client is done).
local function pump(server, client, limit)
    for _ = 1, limit or 2000 do
        local progressed = false
        for _, pair in ipairs({ { server, client }, { client, server } }) do
            local me, peer = pair[1], pair[2]
            if me.done or me.failed then goto continue end
            if me.want == nil or peer.out_len >= me.want then
                local data = nil
                if me.want then data = take_bytes(peer, me.want) end
                me.want = nil
                local kind, arg = me.obj:step(data)
                if kind == "need" then
                    me.want = arg
                elseif kind == "done" then
                    me.done = true
                elseif kind == nil then
                    me.failed = tostring(arg)
                end
                progressed = true
            end
            ::continue::
        end
        if client.done or not progressed then return end
    end
end

check("server_protocol_serves_our_own_client", function()
    -- rfbserver + serverenc driven byte-for-byte against the client protocol: the same wire
    -- contract the socket path uses, without sockets.
    local w, h = 96, 64
    local src = pattern_plane(w, h)

    --- A server bound to a fresh byte-collecting side (the side exists before the closures).
    local function make_server(password)
        local st = side(nil)
        local enc = ServerEnc.new()
        enc:set_pixel_format(CLIENT_FORMAT)
        enc:set_encodings({ ServerEnc.ZRLE, ServerEnc.HEXTILE, ServerEnc.RAW })
        st.obj = RfbServer.new({
            io = {
                read = function(n) return coroutine.yield("need", n) end,
                write = function(data)
                    st.out[#st.out + 1] = data
                    st.out_len = st.out_len + #data
                end,
            },
            password = password or "",
            name = "test",
            get_size = function() return w, h end,
            get_rects = function(_, region)
                return { { x = region.x, y = region.y, w = region.w, h = region.h } }
            end,
            encode = function(_, rect) return enc:encode(src, rect) end,
        })
        return st
    end

    local function make_client(password)
        local st = side(nil)
        st.obj = Protocol.new({
            io = {
                read = function(n) return coroutine.yield("need", n) end,
                write = function(data)
                    st.out[#st.out + 1] = data
                    st.out_len = st.out_len + #data
                end,
            },
            password = password,
            get_plane = function() return st.plane end,
        })
        st.plane = BB.new(w, h, BB.TYPE_BBRGB24)
        return st
    end

    local srv_side = make_server(nil)
    local cli_side = make_client(nil)
    local client = cli_side.obj

    local requested = false
    for steps = 1, 4000 do
        pump(srv_side, cli_side, 1)
        if client.width and not requested then
            requested = true
            client:request_update(false, 0, 0, w, h)
        end
        if cli_side.done or cli_side.failed then break end
    end
    assert_true(not cli_side.failed, "the client failed: " .. tostring(cli_side.failed))
    assert_true(not srv_side.failed, "the server failed: " .. tostring(srv_side.failed))
    assert_true(client.width == w and client.height == h,
        string.format("the client must learn the screen size (got %s)", tostring(client.width)))
    local same, detail = pixels_equal(src, cli_side.plane, w, h)
    assert_true(same, "the decoded frame differs from the served plane: " .. tostring(detail))

    -- VNC Authentication: the right password gets through, a wrong one is refused
    local ok_side = make_server("secret")
    local ok_client = make_client("secret")
    pump(ok_side, ok_client, 400)
    assert_true(ok_client.obj.width == w, "a correct password must get through")
    assert_true(not ok_client.failed, "and not fail: " .. tostring(ok_client.failed))

    local bad_side = make_server("secret")
    local bad_client = make_client("wrong")
    pump(bad_side, bad_client, 400)
    assert_true(bad_client.failed ~= nil, "a wrong password must fail the handshake")

    cli_side.plane:free()
    ok_client.plane:free()
    src:free()
end)

check("server_serves_the_screen_over_a_socket", function()
    -- The real runtime: listener, poll task, capture hook, encoder - and a client that speaks the
    -- protocol by hand over TCP.
    local Server = require("vnc/server")
    local socket = require("socket")
    require("ffi/linux_input_h")

    local settings = { ip = "127.0.0.1", port = 5900, password = "" }
    local server
    -- find a free port
    for port = 5911, 5999 do
        server = Server.new{ settings = { ip = "127.0.0.1", port = port, password = "" } }
        local ok = server:start()
        if ok then settings.port = port break end
        server = nil
    end
    assert_true(server ~= nil, "could not bind a test port")

    local ok, err = pcall(function()
        local bb = Screen.bb
        assert_true(bb ~= nil, "no framebuffer to serve")
        bb:paintRect(0, 0, bb:getWidth(), bb:getHeight(), BB.COLOR_BLACK)
        local rw, rh = math.min(64, bb:getWidth()), math.min(48, bb:getHeight())
        bb:paintRect(8, 8, rw, rh, BB.COLOR_WHITE)
        server:_record_dirty("full", nil)      -- as a refresh would

        local cli = assert(socket.tcp())
        cli:settimeout(3)
        assert(cli:connect("127.0.0.1", settings.port))
        cli:settimeout(0.2)
        cli:setoption("tcp-nodelay", true)         -- c.f., connect_client: a write must be readable
        local function expect(n)
            -- Bounded by wall clock and by the condition (bytes arrived), never by a poll count:
            -- how much one poll reads is the server's business. The socket timeout is lowered
            -- while pumping so the loop is not throttled by it (c.f., connect_client).
            local timeout = cli:gettimeout()
            cli:settimeout(0.02)
            local deadline = socket.gettime() + 5
            local polls, data, e = 0, nil, nil
            while socket.gettime() < deadline do
                data, e = cli:receive(n)
                if data then break end
                if e ~= "timeout" then break end
                server:_poll()
                polls = polls + 1
            end
            cli:settimeout(timeout)
            assert_true(data ~= nil, string.format(
                "short read of %d bytes after %d poll(s) in 5 s: %s", n, polls, tostring(e)))
            return data
        end

        -- Lets the server produce what it already has (it is polled, nothing was sent to it): a
        -- wall-clock settle rather than a poll count - `expect` below waits for each reply for as
        -- long as it takes.
        local function pump_server(seconds)
            step_for(function() server:_poll() end, seconds or 0.05)
        end
        -- A small positive timeout: non-blocking sends on a fresh socket can be dropped
        -- silently, and expect() below treats "timeout" as "pump the server and retry".

        pump_server()
        assert_true(expect(12) == "RFB 003.008\n", "the server must announce 3.8")
        cli:send("RFB 003.008\n")
        local count = expect(1):byte()
        local types = expect(count)
        assert_true(types:byte(1) == 1, "no password means the None security type")
        cli:send(string.char(1))                   -- pick None
        -- 3.8 answers the security choice even for None (RFC 6143 7.1.2)
        local result = expect(4)
        assert_true(result == "\0\0\0\0", "SecurityResult must be 0 (ok)")
        cli:send(string.char(1))                   -- ClientInit, shared
        pump_server()
        local init = expect(20)                  -- width, height, 16-byte PIXEL_FORMAT
        local sw = init:byte(1) * 256 + init:byte(2)
        local sh = init:byte(3) * 256 + init:byte(4)
        assert_true(sw == bb:getWidth() and sh == bb:getHeight(),
            string.format("ServerInit geometry %dx%d", sw, sh))
        assert_true(init:byte(5) == 32 and init:byte(6) == 24, "32bpp/depth 24 by default")
        local name_len = expect(4)
        expect(name_len:byte(1) * 16777216 + name_len:byte(2) * 65536 + name_len:byte(3) * 256 + name_len:byte(4))

        cli:send(string.char(0) .. "\0\0\0" ..                     -- SetPixelFormat
            string.char(32, 24, 0, 1) ..
            string.char(0, 255, 0, 255, 0, 255) ..
            string.char(0, 8, 16) .. "\0\0\0")
        cli:send(string.char(2, 0, 0, 1) ..                            -- SetEncodings: Raw
            string.char(0, 0, 0, 0))
        pump_server()
        cli:send(string.char(3, 0) .. string.char(0, 0, 0, 0) ..       -- FramebufferUpdateRequest
            string.char(math.floor(sw / 256), sw % 256, math.floor(sh / 256), sh % 256))
        pump_server()

        local head = expect(4)
        assert_true(head:byte(1) == 0, "expected a FramebufferUpdate, got message " .. head:byte(1))
        local nrects = head:byte(3) * 256 + head:byte(4)
        assert_true(nrects >= 1, "expected at least one rectangle")

        local plane = BB.new(sw, sh, BB.TYPE_BBRGB24)
        for _ = 1, nrects do
            local r = expect(12)
            local x = r:byte(1) * 256 + r:byte(2)
            local y = r:byte(3) * 256 + r:byte(4)
            local w = r:byte(5) * 256 + r:byte(6)
            local h = r:byte(7) * 256 + r:byte(8)
            local enc = r:byte(9) * 16777216 + r:byte(10) * 65536 + r:byte(11) * 256 + r:byte(12)
            assert_true(enc == 0, "Raw was the only encoding announced, got " .. enc)
            local payload = expect(w * h * 4)
            local dst = plane:viewport(0, 0, sw, sh)
            local ctx = { encoding = 0, r = Util.mem_reader(payload), vp = dst, plane = plane,
                          x = x, y = y, w = w, h = h, streams = Encodings.new_streams() }
            local decoded, derr = Encodings.decode(ctx)
            assert_true(decoded, "decoding failed: " .. tostring(derr))
        end

        -- what the client sees must match the screen: white inside the painted rectangle,
        -- black outside it (works for any framebuffer type, including grey e-ink ones)
        local function px(x, y)
            local d = ffi.cast("uint8_t*", plane.data) + y * plane.stride + x * 3
            return d[0], d[1], d[2]
        end
        local r1, g1, b1 = px(16, 16)
        assert_true(r1 > 200 and g1 > 200 and b1 > 200, "the white rectangle must come through")
        local r2, g2, b2 = px(sw - 4, sh - 4)
        assert_true(r2 < 60 and g2 < 60 and b2 < 60, "and the black area too")
        plane:free()
        cli:close()
    end)

    server:stop()
    assert_true(not server:is_running(), "stop must take the server down")
    if not ok then error(err, 0) end
end)

--- Reads exactly `n` bytes from a test socket, pumping `server` while it waits.
---
--- Unlike the `pump_and_read` closures used elsewhere in this file, this one *keeps* what a
--- short read did return (LuaSocket hands those bytes back only in its third value): a reader
--- that drops them silently swallows a message it did not expect in full and shifts every later
--- read by that many bytes, which turns "the server sent something unexpected" into "some later
--- assertion reads the wrong bytes". Use this when a check asserts on the exact bytes a message
--- carries, or on nothing being sent at all.
---
--- The socket timeout is lowered for the wait: the server parses one *byte* of a client message
--- per poll (`want = min(pending - rx_len, READ_CHUNK)`), so a ten-byte client message needs about
--- ten polls before anything can come back, and at the 0.2 s timeout the other readers use that is
--- already two seconds of waiting.
--- @treturn string exactly `n` bytes
local function recv_exact(cli, n, server)
    return table.concat(parts)
end


--- @treturn string exactly `n` bytes
local function recv_exact(cli, n, server)
    local socket = require("socket")
    local parts, got = {}, 0
    local deadline = socket.gettime() + 10
    local timeout = cli:gettimeout()
    cli:settimeout(0.05)
    while got < n do
        server:_poll()
        local data, err, partial = cli:receive(n - got)
        data = data or partial
        if data and #data > 0 then
            parts[#parts + 1] = data
            got = got + #data
        end
        if err and err ~= "timeout" then
            cli:settimeout(timeout)
            error("socket error: " .. tostring(err), 0)
        end
        assert_true(socket.gettime() <= deadline,
            string.format("short read: %d of %d bytes arrived", got, n))
    end
    cli:settimeout(timeout)
    return table.concat(parts)
end

--- Everything the server sends within `seconds`, pumped while waiting; "" when it sends nothing.
--- A short read is kept, so a message that is already halfway in is not lost (which is what makes
--- this usable as "nothing arrived" evidence), and the socket timeout is lowered for the same
--- reason as in @{recv_exact}: the poll is what makes the server produce anything at all.
local function drain_socket(cli, seconds, server)
    local socket = require("socket")
    local parts = {}
    local timeout = cli:gettimeout()
    cli:settimeout(0.05)
    local deadline = socket.gettime() + seconds
    while socket.gettime() < deadline do
        server:_poll()
        local data, err, partial = cli:receive(4096)
        data = data or partial
        if data and #data > 0 then parts[#parts + 1] = data end
        if err and err ~= "timeout" then break end
    end
    cli:settimeout(timeout)
    return table.concat(parts)
end

check("server_serves_a_second_incremental_update", function()
    -- The first (non-incremental) update is easy; what matters afterwards is that a *change* to
    -- the screen reaches a client that has asked again incrementally.
    local Server = require("vnc/server")
    local socket = require("socket")

    local server, port
    for candidate = 5931, 5999 do
        local s = Server.new{ settings = { ip = "127.0.0.1", port = candidate, password = "" } }
        if s:start() then server, port = s, candidate break end
    end
    assert_true(server ~= nil, "could not bind a test port")

    local ok, err = pcall(function()
        local bb = Screen.bb
        bb:paintRect(0, 0, bb:getWidth(), bb:getHeight(), BB.COLOR_BLACK)
        server:_record_dirty("full", nil)

        local cli = assert(socket.tcp())
        cli:settimeout(0.2)
        assert(cli:connect("127.0.0.1", port))
        local function pump_and_read(n)
            -- Wall clock and the condition, not a poll count (c.f., pump_until), and a short
            -- socket timeout while pumping so the read timeout does not throttle the loop.
            local timeout = cli:gettimeout()
            cli:settimeout(0.02)
            local deadline = socket.gettime() + 5
            local polls, data, e = 0, nil, nil
            while socket.gettime() < deadline do
                data, e = cli:receive(n)
                if data then break end
                if e ~= "timeout" then break end
                server:_poll()
                polls = polls + 1
            end
            cli:settimeout(timeout)
            assert_true(data ~= nil, string.format(
                "short read of %d after %d poll(s) in 5 s: %s", n, polls, tostring(e)))
            return data
        end
        pump_and_read(12)                                   -- version
        cli:send("RFB 003.008\n")
        local count = pump_and_read(1):byte()
        pump_and_read(count)
        cli:send(string.char(1))                            -- None
        pump_and_read(4)                                    -- SecurityResult
        cli:send(string.char(1))                            -- ClientInit
        pump_and_read(20)                                   -- ServerInit geometry + format
        local name_len = pump_and_read(4)
        pump_and_read(name_len:byte(1) * 16777216 + name_len:byte(2) * 65536
            + name_len:byte(3) * 256 + name_len:byte(4))
        cli:send(string.char(0) .. "\0\0\0" .. string.char(32, 24, 0, 1) ..
            string.char(0, 255, 0, 255, 0, 255) .. string.char(0, 8, 16) .. "\0\0\0")
        local use_zrle = os.getenv("VNC_TEST_ZRLE") == "1"
        if use_zrle then
            -- ZRLE (16) keeps one zlib stream per connection, so a second rect exercises the
            -- encoder's stream state across updates.
            cli:send(string.char(2, 0, 0, 1) .. string.char(0, 0, 0, 16))
        else
            cli:send(string.char(2, 0, 0, 1) .. string.char(0, 0, 0, 0))   -- SetEncodings: Raw
        end
        local sw, sh = bb:getWidth(), bb:getHeight()
        local streams = Encodings.new_streams()
        local function request(incremental)
            cli:send(string.char(3, incremental and 1 or 0) ..
                string.char(0, 0, 0, 0) ..
                string.char(math.floor(sw / 256), sw % 256, math.floor(sh / 256), sh % 256))
        end
        local function read_update()
            local head = pump_and_read(4)
            assert_true(head:byte(1) == 0, "expected a FramebufferUpdate")
            local nrects = head:byte(3) * 256 + head:byte(4)
            print(string.format("     [upd] nrects=%d", nrects))
            for _ = 1, nrects do
                local r = pump_and_read(12)
                local w = r:byte(5) * 256 + r:byte(6)
                local h = r:byte(7) * 256 + r:byte(8)
                local enc = r:byte(9) * 16777216 + r:byte(10) * 65536 + r:byte(11) * 256 + r:byte(12)
                print(string.format("     [rect] %d,%d %dx%d enc=%d", r:byte(1) * 256 + r:byte(2),
                    r:byte(3) * 256 + r:byte(4), w, h, enc))
                if enc == 16 then
                    local len_field = pump_and_read(4)
                    local n = len_field:byte(1) * 16777216 + len_field:byte(2) * 65536
                        + len_field:byte(3) * 256 + len_field:byte(4)
                    assert_true(n > 0, "a ZRLE rectangle must carry compressed data")
                    local compressed = pump_and_read(n)
                    -- The decoder reads the length itself, so hand it the whole rectangle payload,
                    -- through one persistent zlib stream for the connection.
                    local plane = Screen.bb
                    local vp = plane:viewport(0, 0, bb:getWidth(), bb:getHeight())
                    local decoded, derr = Encodings.decode{
                        encoding = 16, r = Util.mem_reader(len_field .. compressed), vp = vp,
                        plane = plane,
                        x = r:byte(1) * 256 + r:byte(2), y = r:byte(3) * 256 + r:byte(4),
                        w = w, h = h, streams = streams,
                    }
                    assert_true(decoded, "ZRLE decoding failed: " .. tostring(derr))
                else
                    pump_and_read(w * h * 4)                -- Raw payload
                end
            end
            return nrects
        end

        request(false)
        assert_true(read_update() >= 1, "the first update must carry the screen")

        -- A client that has just asked for an update and got nothing (nothing had changed) must
        -- still have its *later* messages - its keystrokes - acted upon immediately. If they only
        -- arrive together with the next real update, a viewer's input looks dead until something
        -- on the server happens to change.
        do
            local seen_key = false
            local original_input_event = UIManager.handleInputEvent
            UIManager.handleInputEvent = function(_, ev)
                if tostring(ev.handler) == "onKeyPress" then seen_key = true end
            end
            local ok_held, held_err = pcall(function()
                -- Nothing dirty: the request is *held* (not answered), so the keystroke behind it
                -- is only acted on if the message loop keeps reading while it is held - which is
                -- the whole point of holding it in the connection's state instead of suspending the
                -- protocol coroutine (c1e3806). This waits for that by wall clock, not a poll count.
                request(true)
                cli:send(string.char(4, 1, 0, 0) .. string.char(0, 0, 0xFF, 0x54))  -- KeyEvent Down
                local acted, polls = pump_until(function() server:_poll() end, 2,
                    function() return seen_key end)
                assert_true(acted, string.format(
                    "a keystroke must be acted on while an update request is held (%d poll(s) "
                    .. "in 2 s)", polls))
            end)
            UIManager.handleInputEvent = original_input_event
            if not ok_held then error(held_err, 0) end
        end

        -- Keys and pointer events over the wire must reach KOReader's input handling.
        local injected = {}
        local original_input_event = UIManager.handleInputEvent
        UIManager.handleInputEvent = function(_, ev)
            injected[#injected + 1] = tostring(ev.handler)
        end
        local ok_input, input_err = pcall(function()
            cli:send(string.char(4, 1, 0, 0) .. string.char(0, 0, 0xFF, 0x54))   -- KeyEvent: Down, down
            cli:send(string.char(4, 0, 0, 0) .. string.char(0, 0, 0xFF, 0x54))   -- KeyEvent: Down, up
            cli:send(string.char(5, 1, 0, 100, 0, 80))                          -- PointerEvent: press
            cli:send(string.char(5, 0, 0, 100, 0, 80))                          -- PointerEvent: release
            local saw_key, saw_gesture = false, false
            local function scan()
                for _, h in ipairs(injected) do
                    if h == "onKeyPress" or h == "onKeyRelease" then saw_key = true end
                    if h == "onGesture" then saw_gesture = true end
                end
                return saw_key and saw_gesture
            end
            local arrived, polls = pump_until(function() server:_poll() end, 2, scan)
            assert_true(arrived, string.format(
                "a KeyEvent and a PointerEvent over the wire must both become KOReader input events"
                .. " (%d poll(s) in 2 s, got %s)", polls, table.concat(injected, ",")))
            assert_true(#injected > 0, "no KOReader input event came out of the socket path")
            assert_true(saw_key, "a KeyEvent over the wire must become a KOReader key event, got "
                .. table.concat(injected, ","))
            assert_true(saw_gesture, "a PointerEvent over the wire must become a KOReader gesture, "
                .. "got " .. table.concat(injected, ","))

            -- Messages a real viewer sends that RFC 6143 does not define. A server that closes
            -- the connection on one of them looks like a viewer whose input stops working as soon
            -- as it is resized or its clipboard changes.
            cli:send(string.char(248) .. "\0\0\0" .. string.char(0x80, 0, 0, 1) .. string.char(0))  -- Fence, reply requested (9 bytes)
            cli:send(string.char(251, 0) .. string.char(0, 200, 0, 150) .. string.char(1, 0) ..
                string.char(0, 0, 0, 1) ..                         -- screen id
                string.char(0, 0) .. string.char(0, 0) .. string.char(0, 200) .. string.char(0, 150) ..
                string.char(0, 0, 0, 1))                           -- flags
            cli:send(string.char(150, 1) .. string.char(0, 0, 0, 0, 0, 200, 0, 150))
            cli:send(string.char(6, 0, 0, 0) .. string.char(0, 0, 0, 2) .. "hi")
            -- The request this check left held must *not* have been answered: an answer would be
            -- the first thing on the wire (four zero bytes), so reading the Fence reply first - and
            -- asserting it is a Fence reply - is what says it was not.
            local fence = recv_exact(cli, 9, server)      -- type + 3 padding + flags + length
            assert_true(fence:byte(1) == 248, "a Fence request must be answered, got " .. fence:byte(1))
            -- Enabling Continuous Updates is not answered: from here on the server pushes what
            -- changes inside the region named (see
            -- server_pushes_a_change_to_a_client_that_enabled_continuous_updates), so the Fence
            -- reply must be the last thing on the wire.
            assert_true(#drain_socket(cli, 0.2, server) == 0,
                "enabling continuous updates must not be answered")
            -- The rest of this check is about the request/response path, so give the extension up
            -- again; the disable is acknowledged with the one-byte EndOfContinuousUpdates.
            cli:send(string.char(150, 0) .. string.char(0, 0, 0, 0, 0, 200, 0, 150))
            local eocu = recv_exact(cli, 1, server)
            assert_true(eocu == string.char(150),
                "disabling continuous updates must be answered with EndOfContinuousUpdates, got byte "
                .. tostring(eocu:byte(1)))

            -- ... and the session must still take input afterwards
            injected = {}
            cli:send(string.char(4, 1, 0, 0) .. string.char(0, 0, 0xFF, 0x54))   -- KeyEvent: Down
            local function saw_key_press()
                for _, h in ipairs(injected) do
                    if h == "onKeyPress" then return true end
                end
                return false
            end
            local still_alive, polls = pump_until(function() server:_poll() end, 2, saw_key_press)
            assert_true(still_alive, string.format(
                "the session must still take input after non-RFC client messages (it closed after"
                .. " %d poll(s) in 2 s)", polls))
            -- (The pointer path is asserted in server_injects_client_input, where the gesture
            -- detector's state is deterministic; here it is enough that the message was consumed
            -- and produced no error while the session stayed up.)
        end)
        UIManager.handleInputEvent = original_input_event
        if not ok_input then error(input_err, 0) end

        -- Both changes are recorded *first*, then the request is sent: what is asserted is that a
        -- request made after them is answered with both, in one update.
        --
        -- The ordering used to be the other way round - ask, sleep a little, then change - when an
        -- incremental request with nothing to report was answered with an empty update at once, so
        -- "empty update first" was as likely as the change. A request that has nothing to report is
        -- held now (c.f. an_idle_incremental_request_is_held_until_something_changes), so the
        -- request below is answered by exactly these two changes; the drain before them is what
        -- makes sure nothing else (a sign of life from an earlier hold) can be mistaken for it.
        drain_socket(cli, 0.2, server)
        bb:paintRect(8, 8, 32, 24, BB.COLOR_WHITE)
        bb:paintRect(64, 64, 16, 16, BB.COLOR_WHITE)
        server:_record_dirty("partial", { x = 8, y = 8, w = 32, h = 24 })
        server:_record_dirty("partial", { x = 64, y = 64, w = 16, h = 16 })
        request(true)
        -- Two rectangles in one update: each header must be followed by its own data.
        assert_true(read_update() >= 2,
            "both changed rectangles must arrive in one update")
        cli:close()
    end)

    server:stop()
    if not ok then error(err, 0) end
end)

-- ---------------------------------------------------------------- a client that asks incrementally

--- The SetEncodings message announcing the one encoding these checks use: Raw, or ZRLE under
--- VNC_TEST_ZRLE=1 like the other socket checks. `encoding` names a specific one for a check that
--- has to pin an encoder (all four are single-byte encoding numbers).
local function set_encodings_wire(encoding)
    if encoding == nil then
        encoding = os.getenv("VNC_TEST_ZRLE") == "1" and 16 or 0
    end
    return string.char(2, 0, 0, 1) .. string.char(0, 0, 0, encoding)
end

--- Connects a raw socket client, completes the handshake (No security) and announces
--- `encodings_wire` (a whole SetEncodings message). Returns the socket plus `request()` (builds a
--- FramebufferUpdateRequest) and `read_update(plane)`, which reads one FramebufferUpdate, decodes
--- every rectangle into `plane` and returns the rectangle count and their headers.
---
--- `pump` (optional) is how the server is advanced while a read is pending: the default services
--- the sockets directly. A check that has to prove the *UI loop* is what keeps a session alive
--- passes a function that drives `UIManager:handleInput()` instead, so nothing but the scheduled
--- poll task ever touches the server.
local function connect_client(server, port, encodings_wire, pump)
    local socket = require("socket")
    local step = pump or function() server:_poll() end
    local cli = assert(socket.tcp())
    cli:settimeout(0.2)
    assert(cli:connect("127.0.0.1", port))
    -- Nagle would let a write sit in this client's kernel until the peer's delayed ACK (tens of ms
    -- on loopback), so "the write has been sent" would not mean "the server can read it" - and the
    -- checks that assert what one poll must read need it to mean that. A viewer that cares about
    -- latency turns it off for the same reason.
    cli:setoption("tcp-nodelay", true)
    local function pump_and_read(n)
        -- Wall clock and the condition, not a poll count (c.f., pump_until) - and while waiting,
        -- read with a short socket timeout: at the session's 0.2 s the loop would spend most of its
        -- deadline asleep inside `receive`, so how many times it got to pump in five seconds (and
        -- so whether it got through a slower reader's messages) would depend on that timeout
        -- rather than on the server. A timed-out read still hands back the bytes it did get (its
        -- third value) and they are kept: a payload bigger than one receive's worth - a full-screen
        -- Raw rectangle is megabytes - arrives over several of them, and dropping them would shift
        -- every later read by the number of bytes lost.
        local timeout = cli:gettimeout()
        cli:settimeout(0.02)
        local deadline = socket.gettime() + 5
        local polls, parts, got, e = 0, {}, 0, nil
        while socket.gettime() < deadline do
            local data, err, partial = cli:receive(n - got)
            data = data or partial
            if data and #data > 0 then
                parts[#parts + 1] = data
                got = got + #data
            end
            e = err
            if got >= n then break end
            if err and err ~= "timeout" then break end
            step()
            polls = polls + 1
        end
        cli:settimeout(timeout)
        assert_true(got == n, string.format(
            "short read of %d after %d poll(s) in 5 s, got %d: %s", n, polls, got, tostring(e)))
        return table.concat(parts)
    end

    assert_true(pump_and_read(12) == "RFB 003.008\n", "the server must announce 3.8")
    cli:send("RFB 003.008\n")
    local count = pump_and_read(1):byte()
    pump_and_read(count)
    cli:send(string.char(1))                        -- pick the None security type
    pump_and_read(4)                                -- SecurityResult
    cli:send(string.char(1))                        -- ClientInit, shared
    pump_and_read(20)                               -- ServerInit geometry + pixel format
    local name_len = pump_and_read(4)
    pump_and_read(name_len:byte(1) * 16777216 + name_len:byte(2) * 65536
        + name_len:byte(3) * 256 + name_len:byte(4))
    cli:send(string.char(0) .. "\0\0\0" .. string.char(32, 24, 0, 1) ..
        string.char(0, 255, 0, 255, 0, 255) .. string.char(0, 8, 16) .. "\0\0\0")
    cli:send(encodings_wire)

    local streams = Encodings.new_streams()
    local function request(incremental, x, y, w, h)
        return string.char(3, incremental and 1 or 0) ..
            string.char(math.floor(x / 256), x % 256, math.floor(y / 256), y % 256) ..
            string.char(math.floor(w / 256), w % 256, math.floor(h / 256), h % 256)
    end
    local function read_update(plane)
        local head = pump_and_read(4)
        assert_true(head:byte(1) == 0,
            "expected a FramebufferUpdate, got message " .. head:byte(1))
        local nrects = head:byte(3) * 256 + head:byte(4)
        local rects = {}
        for i = 1, nrects do
            local r = pump_and_read(12)
            local rect = {
                x = r:byte(1) * 256 + r:byte(2),
                y = r:byte(3) * 256 + r:byte(4),
                w = r:byte(5) * 256 + r:byte(6),
                h = r:byte(7) * 256 + r:byte(8),
                enc = r:byte(9) * 16777216 + r:byte(10) * 65536 + r:byte(11) * 256 + r:byte(12),
            }
            local ctx = {
                encoding = rect.enc, plane = plane,
                -- the decoders write at the origin of the viewport they are given, so it is the
                -- rectangle itself (this is how the client's own protocol.lua drives them)
                vp = plane:viewport(rect.x, rect.y, rect.w, rect.h),
                x = rect.x, y = rect.y, w = rect.w, h = rect.h, streams = streams,
            }
            local called, decoded, derr
            if rect.enc == 16 then
                local len_field = pump_and_read(4)
                local n = len_field:byte(1) * 16777216 + len_field:byte(2) * 65536
                    + len_field:byte(3) * 256 + len_field:byte(4)
                assert_true(n > 0, "a ZRLE rectangle must carry compressed data")
                ctx.r = Util.mem_reader(len_field .. pump_and_read(n))
            elseif rect.enc == 0 then
                ctx.r = Util.mem_reader(pump_and_read(rect.w * rect.h * 4))
            elseif rect.enc == 2 or rect.enc == 5 then
                -- RRE and Hextile carry no length field: their payload ends exactly where the
                -- decoder has consumed the rectangle (its subrectangles, its tiles). So the
                -- decoder reads the payload straight off the socket, through the same reader
                -- interface the client's protocol hands it.
                ctx.r = Util.reader{ read = pump_and_read }
            else
                assert_true(false, "unexpected rectangle encoding " .. rect.enc)
            end
            called, decoded, derr = pcall(Encodings.decode, ctx)
            assert_true(called and decoded,
                "decoding a rectangle failed: " .. tostring(called and derr or decoded))
            rects[i] = rect
        end
        return nrects, rects
    end
    return { sock = cli, request = request, read_update = read_update,
             -- `send` and `polls` let a check drive the socket and the server a *bounded* number
             -- of times, which is what makes a "within one or two polls" assertion possible:
             -- `read_update` above pumps until something arrives, so it cannot tell a poll from a
             -- hundred.
             send = function(bytes) cli:send(bytes) end,
             polls = function(n) for _ = 1, n or 1 do step() end end,
             step = step }
end

check("server_sends_a_change_after_the_first_full_update", function()
    -- The reported shape: the client takes the first full frame and then never gets another one,
    -- although the screen keeps changing and the capture keeps recording it. One way into that
    -- state is a client message that arrives in more than one TCP segment - a 10-byte request can
    -- be split, and a clipboard or an encoding list certainly can. The bytes that did arrive must
    -- be kept when the rest does not follow within the socket timeout: throwing them away shifts
    -- every later message by the number of bytes lost, so requests are read from the wrong
    -- offset, their region covers nothing, and every change answers "nothing new" for good while
    -- the connection stays up and input still works.
    local Server = require("vnc/server")
    local socket = require("socket")

    local server, port
    for candidate = 5941, 5949 do
        local s = Server.new{ settings = { ip = "127.0.0.1", port = candidate, password = "" } }
        if s:start() then server, port = s, candidate break end
    end
    assert_true(server ~= nil, "could not bind a test port")

    local ok, err = pcall(function()
        local bb = Screen.bb
        local sw, sh = bb:getWidth(), bb:getHeight()
        bb:paintRect(0, 0, sw, sh, BB.COLOR_BLACK)
        server:_record_dirty("full", nil)

        local client = connect_client(server, port, set_encodings_wire())
        local cli = client.sock
        local plane = BB.new(sw, sh, BB.TYPE_BBRGB24)

        -- take the first full update
        cli:send(client.request(false, 0, 0, sw, sh))
        assert_true(client.read_update(plane) >= 1, "the first full update must carry the screen")

        -- the screen changes and the refresh hook records it
        bb:paintRect(8, 8, 32, 24, BB.COLOR_WHITE)
        server:_record_dirty("partial", { x = 8, y = 8, w = 32, h = 24 })

        -- ... and the client asks for it, with its message split inside the x field: the server
        -- reads the one byte it has, waits for the other, and must not drop the one it read.
        local msg = client.request(true, 0, 0, sw, sh)
        cli:send(msg:sub(1, 3))
        -- Wait for the *state* the check is about - the server holds the three bytes it was given
        -- and is waiting for the rest of the message (type, incremental and one byte of x are in
        -- hand, two bytes of x are owed) - rather than for a number of polls. Three polls used to
        -- be enough to walk it to the x field, and how many it takes is the server's own business.
        local function mid_message()
            for _, record in pairs(server.clients) do
                if record.rx_len == 1 and record.pending == 2 then return true end
            end
            return false
        end
        local waiting, polls = pump_until(function() server:_poll() end, 2, mid_message)
        assert_true(waiting, string.format(
            "a half-received request must leave the server waiting for the rest of it, with the"
            .. " bytes it did get kept (%d poll(s) in 2 s)", polls))
        cli:send(msg:sub(4))

        assert_true(client.read_update(plane) >= 1, "the change must arrive as a rectangle")
        local r1, g1, b1 = get(plane, 16, 16)
        assert_true(r1 > 200 and g1 > 200 and b1 > 200, "the changed pixels must come through")
        local r2, g2, b2 = get(plane, sw - 4, sh - 4)
        assert_true(r2 < 60 and g2 < 60 and b2 < 60, "and the rest of the frame must stay intact")
        plane:free()
        cli:close()
    end)

    server:stop()
    if not ok then error(err, 0) end
end)

check("server_gives_a_client_that_asks_incrementally_the_whole_screen", function()
    -- A client that has been sent nothing yet must be given the whole screen even when its first
    -- request is incremental (some clients send one): answering it with only the rectangles that
    -- happen to be dirty hands it a patchwork, and with an empty update (nothing dirty yet) it
    -- would sit in front of a blank screen forever. Every later change must then arrive normally.
    local Server = require("vnc/server")

    local server, port
    for candidate = 5951, 5959 do
        local s = Server.new{ settings = { ip = "127.0.0.1", port = candidate, password = "" } }
        if s:start() then server, port = s, candidate break end
    end
    assert_true(server ~= nil, "could not bind a test port")

    local ok, err = pcall(function()
        local bb = Screen.bb
        local sw, sh = bb:getWidth(), bb:getHeight()
        -- Paint the screen without telling the server about it: it has nothing recorded, which is
        -- exactly what a client that connects to a static screen finds.
        bb:paintRect(0, 0, sw, sh, BB.COLOR_BLACK)
        bb:paintRect(8, 8, 32, 24, BB.COLOR_WHITE)

        local client = connect_client(server, port, set_encodings_wire())
        local cli = client.sock
        local plane = BB.new(sw, sh, BB.TYPE_BBRGB24)

        cli:send(client.request(true, 0, 0, sw, sh))
        local nrects, rects = client.read_update(plane)
        assert_true(nrects >= 1, "a client that has seen nothing must be given the screen")
        local covered, why = rects_cover(rects, sw, sh)
        assert_true(covered, "and it must be the whole screen, not the dirty rectangles: "
            .. tostring(why))
        local r1, g1, b1 = get(plane, 16, 16)
        assert_true(r1 > 200 and g1 > 200 and b1 > 200, "the painted rectangle must be in it")
        local r2, g2, b2 = get(plane, sw - 4, sh - 4)
        assert_true(r2 < 60 and g2 < 60 and b2 < 60, "and the untouched screen around it")

        -- a change after that must arrive as an ordinary incremental update
        bb:paintRect(64, 64, 16, 16, BB.COLOR_WHITE)
        server:_record_dirty("partial", { x = 64, y = 64, w = 16, h = 16 })
        cli:send(client.request(true, 0, 0, sw, sh))
        assert_true(client.read_update(plane) >= 1, "the change must arrive")
        plane:free()
        cli:close()
    end)

    server:stop()
    if not ok then error(err, 0) end
end)

check("server_keeps_a_change_a_client_did_not_ask_about", function()
    -- A change outside the region a client asks about must not be marked as already sent. A client
    -- that asks for one corner (its viewport, say) and later for the whole screen would otherwise
    -- never be told about it - the change is dropped by the bookkeeping, not by the wire.
    local Server = require("vnc/server")

    local server, port
    for candidate = 5961, 5969 do
        local s = Server.new{ settings = { ip = "127.0.0.1", port = candidate, password = "" } }
        if s:start() then server, port = s, candidate break end
    end
    assert_true(server ~= nil, "could not bind a test port")

    local ok, err = pcall(function()
        local bb = Screen.bb
        local sw, sh = bb:getWidth(), bb:getHeight()
        bb:paintRect(0, 0, sw, sh, BB.COLOR_BLACK)
        server:_record_dirty("full", nil)

        local client = connect_client(server, port, set_encodings_wire())
        local cli = client.sock
        local plane = BB.new(sw, sh, BB.TYPE_BBRGB24)

        cli:send(client.request(false, 0, 0, sw, sh))
        assert_true(client.read_update(plane) >= 1, "the first full update must carry the screen")

        bb:paintRect(sw - 40, sh - 40, 16, 16, BB.COLOR_WHITE)
        server:_record_dirty("partial", { x = sw - 40, y = sh - 40, w = 16, h = 16 })

        -- the client asks about a corner that does not contain the change ...
        cli:send(client.request(true, 0, 0, 64, 64))
        assert_true(client.read_update(plane) == 0, "nothing changed in that corner")

        -- ... and then asks for the whole screen again: the change is still owed
        cli:send(client.request(true, 0, 0, sw, sh))
        assert_true(client.read_update(plane) >= 1,
            "a change the client did not ask about must not be marked as sent")
        local r, g, b = get(plane, sw - 32, sh - 32)
        assert_true(r > 200 and g > 200 and b > 200, "and its pixels must arrive")
        plane:free()
        cli:close()
    end)

    server:stop()
    if not ok then error(err, 0) end
end)

-- ---------------------------------------------------------------- a tiled change carries its own pixels

--- Paints a black/white pattern of `cw` x `ch` cells over `(x0, y0, w, h)`.
---
--- Black and white survive every framebuffer the suite runs on (e-ink emulation included), so what
--- the client assembles can be compared byte for byte with a blit of the screen. The cell sizes
--- are picked so that they do not divide the encoders' 256 px rectangle limit: a 256 px rectangle
--- never repeats its neighbour's phase, so a rectangle that arrived carrying another rectangle's
--- pixels cannot look right by accident.
local function paint_wire_pattern(bb, x0, y0, w, h, seed)
    local cw = seed == 1 and 100 or (seed == 2 and 37 or 23)
    local ch = seed == 1 and 100 or (seed == 2 and 53 or 29)
    for y = 0, h - 1, ch do
        for x = 0, w - 1, cw do
            local color = ((math.floor(x / cw) + math.floor(y / ch)) % 2 == 0)
                and BB.COLOR_WHITE or BB.COLOR_BLACK
            bb:paintRect(x0 + x, y0 + y, math.min(cw, w - x), math.min(ch, h - y), color)
        end
    end
end

local function rect_list(rects)
    local out = {}
    for i, r in ipairs(rects) do
        out[i] = string.format("%d,%d %dx%d e%d", r.x, r.y, r.w, r.h, r.enc)
    end
    return table.concat(out, " | ")
end

--- The wire-level check for the mosaic artefact, for one encoder.
---
--- A change larger than @{Server.ENCODE_RECT_LIMIT} reaches a tiled client as several rectangles
--- (that tiling is what keeps a full-screen Hextile/ZRLE/RRE encode from holding the whole tick),
--- and KOReader records the *same* region more than once for one interaction: a click's screen
--- update is a "nil" and a "full" refresh of the same rectangle (c.f., the debug log's
--- "recorded dirty region (mode nil): 0,0 600x800" followed by "(mode full): 0,0 600x800"), so
--- one update can carry the same geometry several times. Every rectangle on the wire must still
--- carry the pixels of its own region - which is what the encoders' per-pixel input has to make
--- true - and the client's assembled framebuffer must equal the screen.
local function wire_change_carries_its_own_pixels(encoding, name, first_port)
    local Server = require("vnc/server")

    local server, port
    for candidate = first_port, first_port + 8 do
        local s = Server.new{ settings = { ip = "127.0.0.1", port = candidate, password = "" } }
        if s:start() then server, port = s, candidate break end
    end
    assert_true(server ~= nil, "could not bind a test port")

    local ok, err = pcall(function()
        local bb = Screen.bb
        local sw, sh = bb:getWidth(), bb:getHeight()
        assert_true(sw >= 300 and sh >= 200,
            string.format("the screen face (%dx%d) must hold the check's change", sw, sh))
        paint_wire_pattern(bb, 0, 0, sw, sh, 1)

        local client = connect_client(server, port, set_encodings_wire(encoding))
        local cli = client.sock
        local plane = BB.new(sw, sh, BB.TYPE_BBRGB24)       -- what the client has assembled
        local reference = BB.new(sw, sh, BB.TYPE_BBRGB24)   -- what the screen holds

        -- The client's first frame: a non-incremental request is answered with the whole screen.
        cli:send(client.request(false, 0, 0, sw, sh))
        local nrects, rects = client.read_update(plane)
        assert_true(nrects >= 1, "the first update must carry the screen")
        reference:blitFrom(bb, 0, 0, 0, 0, sw, sh)
        local same, why = pixels_equal(plane, reference, sw, sh)
        assert_true(same, "the first frame must match the screen: " .. tostring(why))
        print(string.format("   [wire %s] first frame: %d rectangle(s) (%s)",
            name, nrects, rect_list(rects)))

        -- A change wider than Server.ENCODE_RECT_LIMIT, then the whole screen; each recorded
        -- twice, the first with an explicit region and the second as the full-screen "nil"/"full"
        -- pair the refresh hook records.
        local changes = {
            { what = "300x200", rect = { x = 0, y = 0, w = 300, h = 200 }, seed = 2 },
            { what = string.format("%dx%d (the whole screen)", sw, sh), rect = nil, seed = 3 },
        }
        for _, change in ipairs(changes) do
            local r = change.rect
            paint_wire_pattern(bb, r and r.x or 0, r and r.y or 0, r and r.w or sw, r and r.h or sh,
                change.seed)
            server:_record_dirty("nil", r)
            server:_record_dirty("full", r)

            cli:send(client.request(true, 0, 0, sw, sh))
            local got, got_rects = client.read_update(plane)
            reference:blitFrom(bb, 0, 0, 0, 0, sw, sh)
            local equal, detail = pixels_equal(plane, reference, sw, sh)
            print(string.format("   [wire %s] %s change: %d rectangle(s): %s -> %s",
                name, change.what, got, rect_list(got_rects),
                equal and "the frame matches the screen" or "THE FRAME DIFFERS"))
            assert_true(equal, string.format(
                "%s: a %s change must arrive with the pixels of each rectangle's own region,"
                .. " but the frame the client assembled differs: %s", name, change.what,
                tostring(detail)))
            for i, got_rect in ipairs(got_rects) do
                assert_true(got_rect.enc == encoding,
                    string.format("%s: rectangle %d of %d came as encoding %d, not %d",
                        name, i, #got_rects, got_rect.enc, encoding))
            end
        end

        cli:close()
        plane:free()
        reference:free()
    end)
    server:stop()
    if not ok then error(err, 0) end
end

--- The conversion cache hands the *immutable* part of a conversion to the next client of the same
--- pixel format, never the encoder's per-pixel `values` array: that array is one mutable buffer,
--- so a cache entry that kept a reference to it would hand the second client whatever rectangle
--- was converted last. This is the same bug as the wire checks above through the other door
--- (a second client, rather than the same geometry twice).
check("a_cached_conversion_carries_no_other_rectangles_pixels", function()
    local Server = require("vnc/server")

    local server = Server.new{ settings = { ip = "127.0.0.1", port = 5899, password = "" } }
    local bb = Screen.bb
    local sw = bb:getWidth()
    paint_wire_pattern(bb, 0, 0, sw, bb:getHeight(), 2)

    local first = { pixel_format = CLIENT_FORMAT, encodings = { ServerEnc.ZRLE } }
    local second = { pixel_format = CLIENT_FORMAT, encodings = { ServerEnc.ZRLE } }
    local rect_a = { x = 0, y = 0, w = 256, h = 256 }
    local rect_b = { x = 256, y = 0, w = 256, h = 256 }

    -- Both clients ask for `rect_a`; the first one's tick also converts `rect_b` in between.
    local _, payload_a1 = server:_encode(first, rect_a)
    local _, payload_b1 = server:_encode(first, rect_b)
    local _, payload_a2 = server:_encode(second, rect_a)
    assert_true(payload_a1 ~= payload_b1,
        "the check needs the two rectangles to differ (the pattern must cover the whole screen)")
    assert_true(payload_a2 == payload_a1,
        "the second client's rectangle must be encoded from that rectangle's pixels, not from"
        .. " another rectangle's conversion")
end)

check("wire_zrle_change_carries_its_own_pixels", function()
    wire_change_carries_its_own_pixels(ServerEnc.ZRLE, "ZRLE", 5851)
end)

check("wire_hextile_change_carries_its_own_pixels", function()
    wire_change_carries_its_own_pixels(ServerEnc.HEXTILE, "Hextile", 5841)
end)

check("wire_rre_change_carries_its_own_pixels", function()
    wire_change_carries_its_own_pixels(ServerEnc.RRE, "RRE", 5831)
end)

check("wire_raw_change_carries_its_own_pixels", function()
    wire_change_carries_its_own_pixels(ServerEnc.RAW, "Raw", 5821)
end)

-- ---------------------------------------------------------------- what one poll must read

--- The direct regression test for reading a client's buffer instead of one field per poll.
---
--- The server used to read exactly the bytes the protocol owed: a six-byte PointerEvent (type,
--- mask, x, y) cost four polls, ~41 ms, and a viewer that moved its mouse could not be served
--- faster than about 24 messages a second. Everything a client writes in one go must be taken and
--- parsed by the poll that sees it - `rx_len` is what the state machine still owes, so a per-field
--- reader leaves nearly the whole write behind.
check("a_burst_of_pointer_events_is_parsed_in_one_poll", function()
    local Server = require("vnc/server")
    local socket = require("socket")

    local server, port
    for candidate = 5891, 5899 do
        local s = Server.new{ settings = { ip = "127.0.0.1", port = candidate, password = "" } }
        if s:start() then server, port = s, candidate break end
    end
    assert_true(server ~= nil, "could not bind a test port")

    local ok, err = pcall(function()
        local client = connect_client(server, port, set_encodings_wire())
        local cli = client.sock

        -- 200 motion messages (mask 0: KOReader has no hover, so they are parsed and dropped) and
        -- then a request for a small region, all as one write.
        local parts = {}
        for i = 1, 200 do
            parts[i] = string.char(5, 0, (i % 250) + 1, 1, (i % 250) + 1, 2)
        end
        parts[#parts + 1] = client.request(false, 0, 0, 16, 16)
        -- No wait before the poll: `send` handed the bytes to the kernel, and which poll reads them
        -- is what this asserts.
        cli:send(table.concat(parts))
        client.polls(2)
        local record
        for _, r in pairs(server.clients) do record = r end
        assert_true(record ~= nil, "the client must be registered while it is connected")
        -- Two polls is the *design* bound, not a speed budget: one poll reads and parses a whole
        -- write (that is what the read-ahead is for), the second is the slack the read/parse split
        -- needs for bytes that land while the first is being parsed.
        assert_true(record.rx_len == 0, string.format(
            "one poll must read and parse a whole write, %d byte(s) still unread after two polls",
            record.rx_len))

        -- ... and the request behind the burst was answered in the same poll: its update is
        -- already on the wire, so it is read here without pumping the server any further.
        local head, e = cli:receive(4)
        assert_true(head ~= nil and head:byte(1) == 0, string.format(
            "the burst and the request are one write, so one poll must have read and parsed both"
            .. " (%s)", tostring(e)))
        assert_true(head:byte(3) * 256 + head:byte(4) == 1,
            "the 16x16 request must be answered with one rectangle")
        cli:close()
    end)

    server:stop()
    if not ok then error(err, 0) end
end)

--- The same for a message whose *fields* are the many: an encoding list of 200 entries is 200
--- four-byte reads. It must be consumed by the poll that sees it, and the request behind it
--- answered in that same poll.
check("a_large_client_message_is_consumed_in_one_poll", function()
    local Server = require("vnc/server")
    local socket = require("socket")

    local server, port
    for candidate = 5881, 5889 do
        local s = Server.new{ settings = { ip = "127.0.0.1", port = candidate, password = "" } }
        if s:start() then server, port = s, candidate break end
    end
    assert_true(server ~= nil, "could not bind a test port")

    local ok, err = pcall(function()
        local client = connect_client(server, port, set_encodings_wire())
        local cli = client.sock

        -- 200 encodings, all Raw, so the answer below stays a plain one-rectangle update.
        local parts = { string.char(2, 0, 0, 200) }
        for _ = 1, 200 do parts[#parts + 1] = string.char(0, 0, 0, 0) end
        parts[#parts + 1] = client.request(false, 0, 0, 16, 16)
        cli:send(table.concat(parts))
        client.polls(2)
        local record
        for _, r in pairs(server.clients) do record = r end
        assert_true(record ~= nil, "the client must be registered while it is connected")
        assert_true(record.rx_len == 0, string.format(
            "one poll must read and parse a whole write - this one is 200 four-byte reads -"
            .. " %d byte(s) still unread after two polls", record.rx_len))
        assert_true(#(record.server.client.encodings or {}) == 200,
            "all 200 announced encodings must have been recorded")

        local head, e = cli:receive(4)
        assert_true(head ~= nil and head:byte(1) == 0, string.format(
            "the encoding list and the request behind it are one write, so one poll must have read"
            .. " and parsed both (%s)", tostring(e)))
        cli:close()
    end)

    server:stop()
    if not ok then error(err, 0) end
end)

--- An incremental request whose answer has nothing to report is *held*, not answered. Answering it
--- with an empty update makes the client ask again at once - against a real TigerVNC viewer that is
--- a ping-pong at the poll rate (measured: 97 round trips a second in both directions, ~9 kB/s on
--- the wire, 194 packets/s) for as long as nothing on screen changes.
---
--- What must not regress while it is held: the request is answered the moment something changes,
--- and a client asking again and again is never answered with an empty update at all (its own
--- traffic is its sign of life). The deadline - the one case that *is* answered - has its own check
--- below.
check("an_idle_incremental_request_is_held_until_something_changes", function()
    local Server = require("vnc/server")
    local socket = require("socket")

    local server, port
    for candidate = 5871, 5879 do
        local s = Server.new{ settings = { ip = "127.0.0.1", port = candidate, password = "" } }
        if s:start() then server, port = s, candidate break end
    end
    assert_true(server ~= nil, "could not bind a test port")

    local ok, err = pcall(function()
        local bb = Screen.bb
        local sw, sh = bb:getWidth(), bb:getHeight()
        bb:paintRect(0, 0, sw, sh, BB.COLOR_BLACK)
        server:_record_dirty("full", nil)

        local client = connect_client(server, port, set_encodings_wire())
        local cli = client.sock
        local plane = BB.new(sw, sh, BB.TYPE_BBRGB24)

        -- the first frame, so this client owes nothing afterwards
        cli:send(client.request(false, 0, 0, sw, sh))
        assert_true(client.read_update(plane) >= 1, "the first full update must carry the screen")
        plane:free()

        -- nothing changed since: ask incrementally and pump two polls. Nothing may come back - not
        -- in the poll that reads the request, and not in the next one either.
        cli:send(client.request(true, 0, 0, sw, sh))
        client.polls(2)

        local head, e = cli:receive(4)
        assert_true(head == nil, string.format(
            "an incremental request with nothing to report must be held, not answered (%s)",
            tostring(e)))

        -- ... and it is answered by the *change*, within the polls that follow it - not by a poll
        -- count of waiting, and not only when the coalescing deadline expires.
        bb:paintRect(8, 8, 32, 24, BB.COLOR_WHITE)
        server:_record_dirty("partial", { x = 8, y = 8, w = 32, h = 24 })
        client.polls(2)

        head, e = cli:receive(4)
        assert_true(head ~= nil and head:byte(1) == 0, string.format(
            "the change must answer the held request within a poll or two (%s)", tostring(e)))
        local nrects = head:byte(3) * 256 + head:byte(4)
        assert_true(nrects == 1, string.format(
            "the change must arrive as one rectangle, got %d", nrects))
        local r = recv_exact(cli, 12, server)
        local rx, ry = r:byte(1) * 256 + r:byte(2), r:byte(3) * 256 + r:byte(4)
        local rw, rh = r:byte(5) * 256 + r:byte(6), r:byte(7) * 256 + r:byte(8)
        local enc = r:byte(9) * 16777216 + r:byte(10) * 65536 + r:byte(11) * 256 + r:byte(12)
        assert_true(rx == 8 and ry == 8 and rw == 32 and rh == 24, string.format(
            "the answered rectangle must be the one that changed, got %d,%d %dx%d", rx, ry, rw, rh))
        if enc == 16 then
            local len = recv_exact(cli, 4, server)
            recv_exact(cli, len:byte(1) * 16777216 + len:byte(2) * 65536
                + len:byte(3) * 256 + len:byte(4), server)
        else
            recv_exact(cli, rw * rh * 4, server)            -- the Raw payload
        end

        -- The request is done: asking again with nothing to report is held again, not answered
        -- from what is left over.
        cli:send(client.request(true, 0, 0, sw, sh))
        client.polls(2)
        local again = drain_socket(cli, 0.05, server)
        assert_true(#again == 0, string.format(
            "a request with nothing to report must be held, got %d byte(s)", #again))
        cli:close()
    end)

    server:stop()
    if not ok then error(err, 0) end
end)

--- A client that keeps asking while nothing changes must never be answered with an empty update -
--- not "at most once a second", and not "one per request": the whole point of a hold is that the
--- ping-pong stops. The deadline runs from the client's *latest* request, so its own traffic is
--- what keeps it unanswered; a client that goes quiet with a request outstanding is answered by its
--- own check below.
---
--- Measured against a real TigerVNC viewer, the ping-pong this replaces is 97 round trips a second
--- (~9 kB/s) for as long as the screen does not change.
check("a_client_that_keeps_asking_is_never_answered_while_nothing_changes", function()
    local Server = require("vnc/server")
    local socket = require("socket")

    local server, port
    for candidate = 5811, 5819 do
        local s = Server.new{ settings = { ip = "127.0.0.1", port = candidate, password = "" } }
        if s:start() then server, port = s, candidate break end
    end
    assert_true(server ~= nil, "could not bind a test port")

    local ok, err = pcall(function()
        local bb = Screen.bb
        local sw, sh = bb:getWidth(), bb:getHeight()
        bb:paintRect(0, 0, sw, sh, BB.COLOR_BLACK)
        server:_record_dirty("full", nil)

        local client = connect_client(server, port, set_encodings_wire())
        local cli = client.sock
        local plane = BB.new(sw, sh, BB.TYPE_BBRGB24)

        cli:send(client.request(false, 0, 0, sw, sh))
        assert_true(client.read_update(plane) >= 1, "the first full update must carry the screen")
        plane:free()

        -- Two seconds of asking, faster than the deadline: nothing may come back at all. The wall
        -- clock, not a poll count - how much of a message one poll gets through is the server's
        -- business (c.f., pump_until).
        local bytes = 0
        for _ = 1, 14 do
            cli:send(client.request(true, 0, 0, sw, sh))
            bytes = bytes + #drain_socket(cli, 0.15, server)
        end
        assert_true(bytes == 0, string.format(
            "a client that keeps asking while nothing changes must not be sent empty updates, got"
            .. " %d byte(s)", bytes))

        -- The session is still live and the held requests were not thrown away: a change answers
        -- them (the regions the client named are unioned).
        bb:paintRect(8, 8, 32, 24, BB.COLOR_WHITE)
        server:_record_dirty("partial", { x = 8, y = 8, w = 32, h = 24 })
        local head = recv_exact(cli, 4, server)
        assert_true(head:byte(1) == 0, "the change must answer the held requests")
        assert_true(head:byte(3) * 256 + head:byte(4) >= 1,
            "and it must carry the change, not an empty update")
        cli:close()
    end)

    server:stop()
    if not ok then error(err, 0) end
end)

--- A client that goes quiet with a request outstanding must not be left with no answer ever: after
--- @{vnc.server}'s Server.HOLD_DEADLINE one empty update goes out as a sign of life - one per
--- deadline, not one per poll and not one per held request. The request stays held: what it asked
--- for has not been answered, so the next change is still delivered to it (asserted at the end).
---
--- One second is the number because: a real server (TigerVNC's Xvnc) holds such a request
--- indefinitely, so any deadline is already conservative; 1 s is 100x the poll interval, so it can
--- never fire while content is flowing; it is far below any plausible viewer timeout (TigerVNC has
--- none, and the gtk-vnc viewer this was measured with sat through 16 s of silence); and it costs
--- at most one 4-byte update and one 10-byte request per second, against ~100 round trips a second
--- if the request were answered at once.
check("a_held_request_is_answered_by_the_deadline_as_a_sign_of_life", function()
    local Server = require("vnc/server")
    local socket = require("socket")

    assert_true(Server.HOLD_DEADLINE >= 0.5 and Server.HOLD_DEADLINE <= 5, string.format(
        "the coalescing deadline must be long enough not to fire while content flows and short"
        .. " enough to be a sign of life, got %s", tostring(Server.HOLD_DEADLINE)))

    local server, port
    for candidate = 5801, 5809 do
        local s = Server.new{ settings = { ip = "127.0.0.1", port = candidate, password = "" } }
        if s:start() then server, port = s, candidate break end
    end
    assert_true(server ~= nil, "could not bind a test port")

    local ok, err = pcall(function()
        local bb = Screen.bb
        local sw, sh = bb:getWidth(), bb:getHeight()
        bb:paintRect(0, 0, sw, sh, BB.COLOR_BLACK)
        server:_record_dirty("full", nil)

        local client = connect_client(server, port, set_encodings_wire())
        local cli = client.sock
        local plane = BB.new(sw, sh, BB.TYPE_BBRGB24)

        cli:send(client.request(false, 0, 0, sw, sh))
        assert_true(client.read_update(plane) >= 1, "the first full update must carry the screen")
        plane:free()

        -- A quiet client with a request held: asking nothing more, it is answered when the
        -- deadline passes (wall clock: the deadline is a matter of time, not of polls).
        cli:send(client.request(true, 0, 0, sw, sh))
        step_for(function() server:_poll() end, Server.HOLD_DEADLINE + 0.3)

        local head = recv_exact(cli, 4, server)
        assert_true(head:byte(1) == 0, "the sign of life must be a FramebufferUpdate")
        local nrects = head:byte(3) * 256 + head:byte(4)
        assert_true(nrects == 0, string.format(
            "the sign of life must be an *empty* update (nothing changed), got %d rectangle(s)",
            nrects))

        -- ... and one per deadline, not one per poll or one per held request.
        local more = drain_socket(cli, 0.3, server)
        assert_true(#more == 0, string.format(
            "one sign of life per deadline, got %d more byte(s)", #more))

        -- The client is still served: its next request is answered by the next change.
        cli:send(client.request(true, 0, 0, sw, sh))
        bb:paintRect(8, 8, 32, 24, BB.COLOR_WHITE)
        server:_record_dirty("partial", { x = 8, y = 8, w = 32, h = 24 })
        head = recv_exact(cli, 4, server)
        assert_true(head:byte(1) == 0 and head:byte(3) * 256 + head:byte(4) >= 1,
            "the session must still deliver changes after a sign of life")
        cli:close()
    end)

    server:stop()
    if not ok then error(err, 0) end
end)

--- The c1e3806 bug must not come back: a request with nothing to answer is held, and the *next*
--- message in the same write - a keystroke - must still be read and acted on in the same poll or the
--- next one. Holding the request by suspending the protocol coroutine would stop the message loop
--- reading it, and a viewer's input would look dead until the screen happened to change.
---
--- Deterministic by construction: the request and the keystroke are one write, and the suite already
--- pins elsewhere that one poll reads a whole write - so two polls are slack, not a speed budget.
check("server_holds_a_request_and_still_injects_the_message_behind_it", function()
    local Server = require("vnc/server")
    local socket = require("socket")

    local server, port
    for candidate = 5791, 5799 do
        local s = Server.new{ settings = { ip = "127.0.0.1", port = candidate, password = "" } }
        if s:start() then server, port = s, candidate break end
    end
    assert_true(server ~= nil, "could not bind a test port")

    local ok, err = pcall(function()
        local bb = Screen.bb
        local sw, sh = bb:getWidth(), bb:getHeight()
        bb:paintRect(0, 0, sw, sh, BB.COLOR_BLACK)
        server:_record_dirty("full", nil)

        local client = connect_client(server, port, set_encodings_wire())
        local cli = client.sock
        local plane = BB.new(sw, sh, BB.TYPE_BBRGB24)

        cli:send(client.request(false, 0, 0, sw, sh))
        assert_true(client.read_update(plane) >= 1, "the first full update must carry the screen")
        plane:free()

        local seen_key = false
        local original_input_event = UIManager.handleInputEvent
        UIManager.handleInputEvent = function(_, ev)
            if tostring(ev.handler) == "onKeyPress" then seen_key = true end
        end
        local ok_held, held_err = pcall(function()
            -- One write: the request (which will be held) and the keystroke behind it.
            cli:send(client.request(true, 0, 0, sw, sh)
                .. string.char(4, 1, 0, 0) .. string.char(0, 0, 0xFF, 0x54))     -- KeyEvent Down
            client.polls(2)
            assert_true(seen_key, "the keystroke behind a held request must be acted on")
            -- ... and the held request must still be unanswered.
            local bytes = drain_socket(cli, 0.05, server)
            assert_true(#bytes == 0, string.format(
                "holding the request must not have answered it, got %d byte(s)", #bytes))
        end)
        UIManager.handleInputEvent = original_input_event
        if not ok_held then error(held_err, 0) end
        cli:close()
    end)

    server:stop()
    if not ok then error(err, 0) end
end)

--- The stall watchdog is for a *partially* received message - half a message in hand means we are
--- waiting for bytes that are never coming (a length we mis-read, so every later message is being
--- swallowed as its payload). A held update request leaves the connection in the "reading" state
--- too, with bytes owed for the client's *next* message, so the watchdog must not touch it: that
--- would drop an idle client after ten seconds of nothing changing.
check("server_stall_watchdog_only_fires_on_a_partially_received_message", function()
    local Server = require("vnc/server")
    local socket = require("socket")

    local server, port
    for candidate = 5781, 5789 do
        local s = Server.new{ settings = { ip = "127.0.0.1", port = candidate, password = "" } }
        if s:start() then server, port = s, candidate break end
    end
    assert_true(server ~= nil, "could not bind a test port")

    local saved_stall = Server.STALL_TIMEOUT
    -- Test-local, and it only shortens the wait: the check is about *which* state the watchdog
    -- fires in, not about the ten seconds it waits.
    Server.STALL_TIMEOUT = 0.25
    local ok, err = pcall(function()
        local bb = Screen.bb
        local sw, sh = bb:getWidth(), bb:getHeight()
        bb:paintRect(0, 0, sw, sh, BB.COLOR_BLACK)
        server:_record_dirty("full", nil)

        local client = connect_client(server, port, set_encodings_wire())
        local cli = client.sock
        local plane = BB.new(sw, sh, BB.TYPE_BBRGB24)

        cli:send(client.request(false, 0, 0, sw, sh))
        assert_true(client.read_update(plane) >= 1, "the first full update must carry the screen")
        plane:free()

        -- A *held* request: a whole request, nothing owed half-way, nothing changing - the
        -- connection must survive much longer than the watchdog.
        cli:send(client.request(true, 0, 0, sw, sh))
        step_for(function() server:_poll() end, 3 * Server.STALL_TIMEOUT)
        local alive, holding = false, false
        for _, record in pairs(server.clients) do
            if not record.dropped then
                alive = true
                if record.server.client.held then holding = true end
            end
        end
        assert_true(alive, string.format(
            "a held request must not be dropped by the stall watchdog: the client must survive"
            .. " %.2fs of nothing changing", 3 * Server.STALL_TIMEOUT))
        assert_true(holding, string.format(
            "the request must still be held after %.2fs of nothing changing (the watchdog is for a"
            .. " half-received message, not for a request with nothing to answer)",
            3 * Server.STALL_TIMEOUT))

        -- Half a request, and then silence: *that* is what the watchdog is for.
        local msg = client.request(true, 0, 0, sw, sh)
        cli:send(msg:sub(1, 3))
        local function partial()
            for _, record in pairs(server.clients) do
                if record.rx_len > 0 and record.pending and record.rx_len < record.pending then
                    return true
                end
            end
            return false
        end
        local waiting = pump_until(function() server:_poll() end, 2, partial)
        assert_true(waiting, "three bytes of a ten-byte request must leave the rest owed")
        step_for(function() server:_poll() end, 3 * Server.STALL_TIMEOUT)
        local still_there = false
        for _, record in pairs(server.clients) do
            if not record.dropped then still_there = true end
        end
        assert_true(not still_there, string.format(
            "a message that never finishes arriving must be dropped after the watchdog's %.2fs",
            Server.STALL_TIMEOUT))
        cli:close()
    end)
    Server.STALL_TIMEOUT = saved_stall

    server:stop()
    if not ok then error(err, 0) end
end)

--- KOReader records the same region more than once for one interaction (`(mode nil)` then
--- `(mode full)`, both 0,0 600x800), and two records of the same rectangle would hand a client that
--- has not been served in between the same tiles twice - twice the encode, twice the bytes, for one
--- change. Folding them into one record must not lose a change for a client that *was* served in
--- between, though: the folded record carries the newest generation, so that client is told again.
check("server_coalesces_one_region_recorded_twice", function()
    local Server = require("vnc/server")
    local socket = require("socket")

    local server, port
    for candidate = 5771, 5779 do
        local s = Server.new{ settings = { ip = "127.0.0.1", port = candidate, password = "" } }
        if s:start() then server, port = s, candidate break end
    end
    assert_true(server ~= nil, "could not bind a test port")

    local ok, err = pcall(function()
        local bb = Screen.bb
        local sw, sh = bb:getWidth(), bb:getHeight()
        bb:paintRect(0, 0, sw, sh, BB.COLOR_BLACK)
        server:_record_dirty("full", nil)

        local client = connect_client(server, port, set_encodings_wire())
        local cli = client.sock
        local plane = BB.new(sw, sh, BB.TYPE_BBRGB24)

        cli:send(client.request(false, 0, 0, sw, sh))
        assert_true(client.read_update(plane) >= 1, "the first full update must carry the screen")

        -- What one full-screen record costs this encoding (ZRLE and friends tile a big rectangle,
        -- so this is not always one).
        bb:paintRect(0, 0, sw, sh, BB.COLOR_WHITE)
        server:_record_dirty("full", nil)
        cli:send(client.request(true, 0, 0, sw, sh))
        local baseline, rects = client.read_update(plane)
        assert_true(baseline >= 1, "a full-screen change must be delivered")
        local r0, g0, b0 = get(plane, 16, 16)
        assert_true(r0 > 200 and g0 > 200 and b0 > 200, "with the pixels it left behind")

        -- One interaction, two records of the same region (what KOReader does for a click): the
        -- client must pay for exactly one of them.
        bb:paintRect(0, 0, sw, sh, BB.COLOR_BLACK)
        server:_record_dirty(nil, nil)
        server:_record_dirty("full", nil)
        assert_true(#server._dirty == 1, string.format(
            "the same region recorded twice must be one dirty record, got %d", #server._dirty))
        cli:send(client.request(true, 0, 0, sw, sh))
        local nrects, rects2 = client.read_update(plane)
        assert_true(nrects == baseline, string.format(
            "the same region recorded twice must cost the same as one change, got %d rectangle(s)"
            .. " against %d", nrects, baseline))
        local area = 0
        for _, rect in ipairs(rects2) do area = area + rect.w * rect.h end
        assert_true(area == sw * sh, string.format(
            "and the rectangles must cover the region that changed (%d of %d pixels)", area, sw * sh))
        local r1, g1, b1 = get(plane, 16, 16)
        assert_true(r1 < 60 and g1 < 60 and b1 < 60, "with the pixels the second record left behind")

        -- A client served *between* two records of the same region must still be told about the
        -- second one: folding them keeps the newest generation, so it is offered again (and a
        -- version that folded them onto the *older* generation would leave this client black).
        bb:paintRect(0, 0, sw, sh, BB.COLOR_WHITE)
        server:_record_dirty("full", nil)
        cli:send(client.request(true, 0, 0, sw, sh))
        nrects = client.read_update(plane)
        assert_true(nrects >= 1, string.format(
            "a region recorded again after a client was served must be delivered again, got %d"
            .. " rectangle(s)", nrects))
        local r2, g2, b2 = get(plane, 16, 16)
        assert_true(r2 > 200 and g2 > 200 and b2 > 200, "and it must carry the newer pixels")

        plane:free()
        cli:close()
    end)

    server:stop()
    if not ok then error(err, 0) end
end)

--- One conversion per pixel format per poll: two clients of the same format asking about the same
--- rectangle in the same tick must not convert the same pixels twice. Counted by wrapping the
--- module function the server calls, so the plugin itself needs nothing.
check("two_clients_of_one_format_share_one_conversion", function()
    local Server = require("vnc/server")
    local ServerEnc = require("vnc/serverenc")
    local socket = require("socket")

    local server, port
    for candidate = 5861, 5869 do
        local s = Server.new{ settings = { ip = "127.0.0.1", port = candidate, password = "" } }
        if s:start() then server, port = s, candidate break end
    end
    assert_true(server ~= nil, "could not bind a test port")

    local calls = 0
    local original_convert = ServerEnc.convert
    ServerEnc.convert = function(self, ...)
        calls = calls + 1
        return original_convert(self, ...)
    end

    local ok, err = pcall(function()
        local bb = Screen.bb
        local sw, sh = bb:getWidth(), bb:getHeight()
        bb:paintRect(0, 0, sw, sh, BB.COLOR_BLACK)
        server:_record_dirty("full", nil)

        local a = connect_client(server, port, set_encodings_wire())
        local b = connect_client(server, port, set_encodings_wire())
        local plane = BB.new(sw, sh, BB.TYPE_BBRGB24)
        a.send(a.request(false, 0, 0, sw, sh))
        assert_true(a.read_update(plane) >= 1, "the first update must carry the screen")
        b.send(b.request(false, 0, 0, sw, sh))
        assert_true(b.read_update(plane) >= 1, "the first update must carry the screen")
        plane:free()

        -- one change, 200x100: a single rectangle for every encoding (it is below the limit the
        -- encoders that walk every pixel are given) and the same pixel format for both clients
        bb:paintRect(8, 8, 200, 100, BB.COLOR_WHITE)
        server:_record_dirty("partial", { x = 8, y = 8, w = 200, h = 100 })

        -- both ask in the same tick: `send` put each request in the kernel, so the next poll
        -- serves both clients - no wait is involved, and the sharing asserted below is per poll.
        a.send(a.request(true, 0, 0, sw, sh))
        b.send(b.request(true, 0, 0, sw, sh))
        calls = 0                           -- the first frames are not part of this
        server:_poll()
        assert_true(calls == 1, string.format(
            "one poll must convert a rectangle once for every client of that pixel format that asks"
            .. " in it, converted %d time(s)", calls))

        -- ... and both were served in that poll: their answers are already on the wire
        local ahead = a.sock:receive(4)
        local bhead = b.sock:receive(4)
        assert_true(ahead ~= nil and ahead:byte(1) == 0 and bhead ~= nil and bhead:byte(1) == 0,
            "both clients must be answered by the poll that shares the conversion")
        a.sock:close()
        b.sock:close()
    end)

    ServerEnc.convert = original_convert
    server:stop()
    if not ok then error(err, 0) end
end)

check("server_pushes_a_change_to_a_client_that_enabled_continuous_updates", function()
    -- Continuous Updates (client message 150, the community extension gtk-vnc/GNOME Connections
    -- speaks): a viewer that enables it stops asking for the region it named and waits for the
    -- server to push what changes there. A server that only ever *answers* requests shows such a
    -- viewer its first frame and then nothing, however much the screen changes and however well
    -- its input works - the reported "TigerVNC works, the other viewer shows one frame" shape.
    local Server = require("vnc/server")
    local socket = require("socket")

    local server, port
    for candidate = 5901, 5909 do
        local s = Server.new{ settings = { ip = "127.0.0.1", port = candidate, password = "" } }
        if s:start() then server, port = s, candidate break end
    end
    assert_true(server ~= nil, "could not bind a test port")

    local ok, err = pcall(function()
        local bb = Screen.bb
        local sw, sh = bb:getWidth(), bb:getHeight()
        local function region(x, y, w, h)
            return string.char(math.floor(x / 256), x % 256, math.floor(y / 256), y % 256) ..
                string.char(math.floor(w / 256), w % 256, math.floor(h / 256), h % 256)
        end
        local function enable_continuous(enable, x, y, w, h)
            return string.char(150, enable and 1 or 0) .. region(x, y, w, h)
        end

        bb:paintRect(0, 0, sw, sh, BB.COLOR_BLACK)
        server:_record_dirty("full", nil)

        local client = connect_client(server, port, set_encodings_wire())
        local cli = client.sock
        local plane = BB.new(sw, sh, BB.TYPE_BBRGB24)

        -- the first (asked-for) full update, so the client has a frame to extend
        cli:send(client.request(false, 0, 0, sw, sh))
        assert_true(client.read_update(plane) >= 1, "the first full update must carry the screen")
        local r0, g0, b0 = get(plane, 16, 16)
        assert_true(r0 < 60 and g0 < 60 and b0 < 60, "the screen starts black")

        -- EnableContinuousUpdates(enable = 1, the whole screen): from here on this client asks
        -- for nothing at all.
        cli:send(enable_continuous(true, 0, 0, sw, sh))
        -- Wall clock, not a poll count: how much of the message one poll gets through is the
        -- server's business, and a count that matched one machine's read speed is exactly what
        -- makes a check fail on a slower one.
        local function recorded()
            for _, record in pairs(server.clients) do
                if record.server.client.continuous then return true end
            end
            return false
        end
        local enabled, polls = pump_until(function() server:_poll() end, 5, recorded)
        assert_true(enabled, string.format(
            "the server must record the region a client asked to be kept up to date (%d poll(s)"
            .. " in 5 s)", polls))

        -- ... and it must not be answered: there is nothing to answer, the client relies on the
        -- pushes now (an answer here is exactly the message that tells a viewer to go back to
        -- asking).
        local ack = drain_socket(cli, 0.3, server)
        assert_true(#ack == 0,
            "enabling continuous updates must not be answered, got " .. #ack .. " byte(s)")

        -- An idle client whose region did not change gets nothing at all: no stream of empty
        -- updates, which is what a push on every poll tick would amount to.
        local idle = drain_socket(cli, 0.3, server)
        assert_true(#idle == 0,
            "an idle client must not be sent empty updates, got " .. #idle .. " byte(s)")

        -- The screen changes: with nothing outstanding, this can only arrive pushed.
        bb:paintRect(8, 8, 32, 24, BB.COLOR_WHITE)
        server:_record_dirty("partial", { x = 8, y = 8, w = 32, h = 24 })
        local pushed = client.read_update(plane)
        assert_true(pushed >= 1,
            "a change must be pushed to a client that enabled continuous updates without a request")
        local r1, g1, b1 = get(plane, 16, 16)
        assert_true(r1 > 200 and g1 > 200 and b1 > 200, "and the changed pixels must come through")

        -- ... but asking for it again must not repeat it: the push advanced the same `sent_gen`
        -- the request path reads, so there is nothing to answer and the request is *held* - what
        -- it gets is the deadline's sign of life (an empty update), not the change again.
        cli:send(client.request(true, 0, 0, sw, sh))
        local repeated = client.read_update(plane)
        assert_true(repeated == 0,
            "a change a push already delivered must not be answered again, got "
            .. repeated .. " rect(s)")

        -- A client that switches the extension off is back on the request/response path: the
        -- disable is acknowledged (one byte, EndOfContinuousUpdates) ...
        cli:send(enable_continuous(false, 0, 0, sw, sh))
        local eocu = recv_exact(cli, 1, server)
        assert_true(eocu == string.char(150),
            "disabling continuous updates must be answered with EndOfContinuousUpdates, got byte "
            .. tostring(eocu:byte(1)))
        -- ... and the earlier request is still outstanding (its sign of life was not content), so
        -- this change answers *it*: that is the request path, not a push.
        bb:paintRect(64, 64, 16, 16, BB.COLOR_WHITE)
        server:_record_dirty("partial", { x = 64, y = 64, w = 16, h = 16 })
        local owed = client.read_update(plane)
        assert_true(owed >= 1, "the change must answer the request the client left outstanding")
        local r2, g2, b2 = get(plane, 68, 68)
        assert_true(r2 > 200 and g2 > 200 and b2 > 200, "and its pixels must arrive")

        -- Nothing is outstanding now, and the extension is off: a later change must not be pushed.
        bb:paintRect(128, 128, 16, 16, BB.COLOR_WHITE)
        server:_record_dirty("partial", { x = 128, y = 128, w = 16, h = 16 })
        local not_pushed = drain_socket(cli, 0.3, server)
        assert_true(#not_pushed == 0,
            "a client that disabled continuous updates must not be pushed to, got "
            .. #not_pushed .. " byte(s)")

        -- ... while asking gets it exactly once.
        cli:send(client.request(true, 0, 0, sw, sh))
        local answered = client.read_update(plane)
        assert_true(answered >= 1, "a client that asks must be answered with the change")
        local r3, g3, b3 = get(plane, 132, 132)
        assert_true(r3 > 200 and g3 > 200 and b3 > 200, "and its pixels must arrive")
        local twice = drain_socket(cli, 0.3, server)
        assert_true(#twice == 0,
            "the change must go out exactly once, got " .. #twice .. " more byte(s)")

        -- The message may also be sent before the first request: such a client has been sent
        -- nothing yet, so it is given the region itself (the same fullness rule the request path
        -- uses), not an empty update.
        local early = connect_client(server, port, set_encodings_wire())
        local early_plane = BB.new(sw, sh, BB.TYPE_BBRGB24)
        early.sock:send(enable_continuous(true, 0, 0, 64, 64))
        local early_rects = early.read_update(early_plane)
        assert_true(early_rects >= 1,
            "a client that enables continuous updates before its first request must be given"
            .. " the region")
        local r3, g3, b3 = get(early_plane, 16, 16)
        local r4, g4, b4 = get(early_plane, 32, 32)
        assert_true(r3 > 200 and g3 > 200 and b3 > 200 and r4 < 60 and g4 < 60 and b4 < 60,
            "and the region must carry the screen it was given")

        print(string.format("   [cu] pushed %d rect(s) with nothing outstanding (16,16 now"
            .. " %d,%d,%d); enable and idle polls sent %d byte(s); the request after the push was"
            .. " answered with %d rect(s); the disable with %d byte(s); enabling before the first"
            .. " request was given %d rect(s)", pushed, r1, g1, b1, #ack + #idle, repeated,
            #eocu, early_rects))

        plane:free()
        early_plane:free()
        cli:close()
        early.sock:close()
    end)

    server:stop()
    if not ok then error(err, 0) end
end)

check("server_serves_a_client_that_asks_for_more_than_the_screen", function()
    -- Viewers exist that send 65535x65535 to mean "the whole screen". The requested region (and
    -- the region a continuous-updates client names) has to be clamped to the framebuffer before
    -- anything sizes buffers from it: handed on unclamped, it reaches the encoder, which allocates
    -- four bytes per pixel for the rectangle it is given, so 65535x65535 asks for tens of
    -- gigabytes - the connection dies, and with it the only frame the client had. That is a
    -- perfectly good "the first frame arrived and then nothing ever did" for a viewer that asks
    -- for its region that way.
    local Server = require("vnc/server")

    local server, port
    for candidate = 5921, 5929 do
        local s = Server.new{ settings = { ip = "127.0.0.1", port = candidate, password = "" } }
        if s:start() then server, port = s, candidate break end
    end
    assert_true(server ~= nil, "could not bind a test port")

    local ok, err = pcall(function()
        local bb = Screen.bb
        local sw, sh = bb:getWidth(), bb:getHeight()
        bb:paintRect(0, 0, sw, sh, BB.COLOR_BLACK)
        server:_record_dirty("full", nil)

        local client = connect_client(server, port, set_encodings_wire())
        local cli = client.sock
        local plane = BB.new(sw, sh, BB.TYPE_BBRGB24)

        -- A non-incremental request for far more than the screen must be answered with the screen,
        -- not with the rectangle as asked for.
        cli:send(client.request(false, 0, 0, 0xFFFF, 0xFFFF))
        local nrects, rects = client.read_update(plane)
        assert_true(nrects >= 1, "a 65535x65535 request must be answered with the screen")
        local clamped, why = rects_cover(rects, sw, sh)
        assert_true(clamped, "an oversized request must be clamped to the screen, got "
            .. tostring(why) .. string.format(" of %dx%d", sw, sh))
        local r0, g0, b0 = get(plane, 16, 16)
        assert_true(r0 < 60 and g0 < 60 and b0 < 60, "and the screen it does have must be in it")

        -- ... and the client must still be connected, serving the changes it asks about.
        bb:paintRect(8, 8, 32, 24, BB.COLOR_WHITE)
        server:_record_dirty("partial", { x = 8, y = 8, w = 32, h = 24 })
        cli:send(client.request(true, 0, 0, 0xFFFF, 0xFFFF))
        assert_true(client.read_update(plane) >= 1,
            "an oversized incremental request must still be served the change")
        local r1, g1, b1 = get(plane, 16, 16)
        assert_true(r1 > 200 and g1 > 200 and b1 > 200, "and its pixels must arrive")

        -- A region that starts outside the screen is read as the whole screen, not as an error.
        cli:send(client.request(false, 65000, 65000, 0xFFFF, 0xFFFF))
        local far = client.read_update(plane)
        assert_true(far >= 1, "a request aimed outside the screen must be answered with the screen")

        print(string.format("   [clamp] 65535x65535 -> %d,%d %dx%d of a %dx%d screen; the client"
            .. " stayed connected and got its change",
            rects[1].x, rects[1].y, rects[1].w, rects[1].h, sw, sh))
        plane:free()
        cli:close()
    end)

    server:stop()
    if not ok then error(err, 0) end
end)

check("server_survives_a_conforming_fence_before_a_request", function()
    -- ClientFence is type + three padding bytes + u32 flags + u8 length (nine bytes with an empty
    -- payload), and ServerFence is framed identically (RFC 6143 §7.5.4 / rfbproto.rst). Framed with
    -- one padding byte, the client's two leftover zeros are read as the next message type - a
    -- SetPixelFormat - which swallows the 19 bytes that follow (the client's
    -- FramebufferUpdateRequest among them) and then errors on the bogus pixel format, which drops
    -- the connection: a viewer that fences, as real viewers do, keeps the first frame it was given
    -- and never gets another, while its input looks fine.
    local Server = require("vnc/server")

    local server, port
    for candidate = 5921, 5929 do
        local s = Server.new{ settings = { ip = "127.0.0.1", port = candidate, password = "" } }
        if s:start() then server, port = s, candidate break end
    end
    assert_true(server ~= nil, "could not bind a test port")

    local ok, err = pcall(function()
        local socket = require("socket")
        local bb = Screen.bb
        local sw, sh = bb:getWidth(), bb:getHeight()
        bb:paintRect(0, 0, sw, sh, BB.COLOR_BLACK)
        server:_record_dirty("full", nil)

        local client = connect_client(server, port, set_encodings_wire())
        local cli = client.sock
        local plane = BB.new(sw, sh, BB.TYPE_BBRGB24)

        cli:send(client.request(false, 0, 0, sw, sh))
        assert_true(client.read_update(plane) >= 1, "the first full update must carry the screen")

        -- A conforming fence asking for a reply, immediately followed by the request for the
        -- change that was just recorded.
        cli:send(string.char(248) .. "\0\0\0" ..
            string.char(0x80, 0, 0, 1) .. string.char(0))          -- reply requested, no payload
        bb:paintRect(8, 8, 32, 24, BB.COLOR_WHITE)
        server:_record_dirty("partial", { x = 8, y = 8, w = 32, h = 24 })
        cli:send(client.request(true, 0, 0, sw, sh))

        -- Everything the server sends for that: the nine-byte ServerFence, then a
        -- FramebufferUpdate. Read leniently (nothing may be lost to a short read) so a reply that
        -- is too short fails on the assertions below with a useful message. A fence framed with
        -- one padding byte leaves the client's request swallowed, so nothing follows the reply and
        -- the second assertion is the one that fires.
        local got = ""
        local deadline = socket.gettime() + 5
        while #got < 25 and socket.gettime() < deadline do
            got = got .. drain_socket(cli, 0.3, server)
        end
        -- The first assertion is the one a fence framed with one padding byte fails: the two
        -- leftover bytes become a SetPixelFormat, the request behind the fence is swallowed, and
        -- nothing at all is ever sent for it (the connection is then dropped on the bogus pixel
        -- format).
        assert_true(#got > 9,
            string.format("the request after a conforming fence was never answered (the server sent"
                .. " %d byte(s) for the fence and the request behind it)", #got))
        assert_true(got:byte(1) == 248,
            "the fence must be answered, got message " .. tostring(got:byte(1)))

        -- The reply is exactly nine bytes, so the update starts right behind them and must parse:
        -- a seven-byte reply would shift this by two and read no rectangles at all.
        local update = got:sub(10)
        local nrects = update:byte(3) * 256 + update:byte(4)
        assert_true(nrects >= 1,
            "the bytes after the fence reply must be a FramebufferUpdate with the change"
            .. " (a reply shorter than nine bytes shifts the client's whole stream)")
        local rx = update:byte(5) * 256 + update:byte(6)
        local ry = update:byte(7) * 256 + update:byte(8)
        local rw = update:byte(9) * 256 + update:byte(10)
        local rh = update:byte(11) * 256 + update:byte(12)
        assert_true(rx == 8 and ry == 8 and rw == 32 and rh == 24,
            string.format("the answer must carry the change 8,8 32x24, got %d,%d %dx%d",
                rx, ry, rw, rh))

        print(string.format("   [fence] the 9-byte fence reply was followed by the answer to the"
            .. " request behind it (%d rect(s), %d,%d %dx%d)", nrects, rx, ry, rw, rh))
        plane:free()
        cli:close()
    end)

    server:stop()
    if not ok then error(err, 0) end
end)

check("server_survives_a_wrap_of_the_refresh_chain", function()
    -- Another plugin may wrap UIManager._refresh after us. A stop then cannot take our hook out of
    -- the chain, and a later start must neither chain our hook to itself (that recurses until the
    -- stack blows on every frame) nor leave it calling a function that is no longer there.
    local Server = require("vnc/server")

    local real = UIManager._refresh
    local reached = 0
    UIManager._refresh = function(mgr, mode, region, dither)   -- the other plugin
        reached = reached + 1
        return real(mgr, mode, region, dither)
    end

    local server, port
    for candidate = 5971, 5979 do
        local s = Server.new{ settings = { ip = "127.0.0.1", port = candidate, password = "" } }
        if s:start() then server, port = s, candidate break end
    end
    assert_true(server ~= nil, "could not bind a test port")

    local ok, err = pcall(function()
        -- somebody wraps us, so our hook is no longer the outermost one
        local hooked = UIManager._refresh
        UIManager._refresh = function(mgr, mode, region, dither)
            return hooked(mgr, mode, region, dither)
        end

        server:stop()
        local ok_refresh, rerr = pcall(UIManager._refresh, UIManager, "fast",
            Geom:new{ x = 0, y = 0, w = 8, h = 8 }, false)
        assert_true(ok_refresh,
            "a refresh after a stop that could not restore the chain must not fail: " .. tostring(rerr))

        server:start()
        local before = reached
        ok_refresh, rerr = pcall(UIManager._refresh, UIManager, "fast",
            Geom:new{ x = 0, y = 0, w = 8, h = 8 }, false)
        assert_true(ok_refresh, "a refresh after a restart must not fail: " .. tostring(rerr))
        -- (More than one call is normal: UIManager merges overlapping refreshes by re-entering
        -- _refresh. What must not happen is the runaway recursion of our hook reaching itself.)
        assert_true(reached > before and reached - before < 8,
            "the refresh must reach the real one without recursing (" .. tostring(reached - before) .. ")")
    end)

    server:stop()
    UIManager._refresh = real
    if not ok then error(err, 0) end
end)

check("client_input_reaches_a_widget", function()
    -- The end of the chain: a tap and a key from a client must make a *real widget* on KOReader's
    -- window stack react. (The check below spies on UIManager:handleInputEvent, which only proves
    -- the event was dispatched; this one proves it is acted upon.)
    local Server = require("vnc/server")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local GestureRange = require("ui/gesturerange")

    local server = Server.new{ settings = { ip = "127.0.0.1", port = 5900, password = "" } }
    local received = {}
    local widget = InputContainer:new{
        dimen = Screen:getSize(),
        ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = 4000, h = 4000 } } },
        },
        key_events = { KeyPress = { { "Down" } } },
    }
    function widget:onTap(_, ges)
        received.tap = { x = ges.pos.x, y = ges.pos.y }
        return true
    end
    function widget:onKeyPress(key)
        received.key = key.key
        return true
    end
    UIManager:show(widget)
    local ok, err = pcall(function()
        server:inject_pointer(120, 90, 1)
        server:inject_pointer(121, 90, 1)               -- a mouse wobbles while clicking ...
        server:inject_pointer(120, 90, 0)               -- ... and must still be a tap, not a drag
        server:inject_key(0xFF54, true)                 -- Down
        assert_true(received.tap ~= nil, "a client tap must reach a widget's onTap")
        assert_true(received.tap.x == 120 and received.tap.y == 90,
            string.format("the tap must land where the client asked, got %s,%s",
                tostring(received.tap.x), tostring(received.tap.y)))
        assert_true(received.key == "Down",
            "a client key must reach a widget's onKeyPress, got " .. tostring(received.key))
    end)
    UIManager:close(widget)
    if not ok then error(err, 0) end
end)

check("a_client_click_over_the_wire_reaches_a_widget", function()
    -- The wire end of the chain: a PointerEvent that arrives over the socket, through the
    -- protocol's per-client state, must make a *real widget* on the window stack react.
    -- `client_input_reaches_a_widget` above drives Server:inject_pointer, which owns the button
    -- state itself, so it cannot see the protocol layer pre-empting that state; this check goes
    -- the way a viewer's click really arrives. (Before the msg == 5 branch stopped storing the
    -- mask, no PointerEvent ever became a gesture, and this is the check that says so.)
    local Server = require("vnc/server")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local GestureRange = require("ui/gesturerange")
    local socket = require("socket")

    local server, port
    for candidate = 5931, 5999 do
        local s = Server.new{ settings = { ip = "127.0.0.1", port = candidate, password = "" } }
        if s:start() then server, port = s, candidate break end
    end
    assert_true(server ~= nil, "could not bind a test port")

    local function full_screen()
        return Geom:new{ x = 0, y = 0, w = 4000, h = 4000 }
    end
    local taps, moves = {}, {}
    local widget = InputContainer:new{
        dimen = Screen:getSize(),
        disable_double_tap = true,
        ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = full_screen() } },
            Pan = { GestureRange:new{ ges = "pan", range = full_screen() } },
            Swipe = { GestureRange:new{ ges = "swipe", range = full_screen() } },
        },
    }
    function widget:onTap(_, ges)
        taps[#taps + 1] = { x = ges.pos.x, y = ges.pos.y }
        return true
    end
    function widget:onPan(_, ges)
        moves[#moves + 1] = ges.ges
        return true
    end
    widget.onSwipe = widget.onPan
    UIManager:show(widget)

    local ok, err = pcall(function()
        local conn = connect_client(server, port, set_encodings_wire())
        local function pointer(mask, x, y)
            return string.char(5, mask, math.floor(x / 256), x % 256, math.floor(y / 256), y % 256)
        end
        -- Waits for what the check is about, by wall clock: 60 polls was enough while a poll read
        -- one field of one message, and a poll count would tie the check to that again.
        local function settle(cond)
            return pump_until(function() server:_poll() end, 2, cond)
        end

        -- A plain click: press then release, in place.
        conn.sock:send(pointer(1, 120, 90))
        conn.sock:send(pointer(0, 120, 90))
        local tapped, polls = settle(function() return #taps == 1 end)
        assert_true(tapped, string.format(
            "a click over the wire must reach a widget's onTap, got %d tap(s) after %d poll(s)"
            .. " in 2 s", #taps, polls))
        assert_true(taps[1].x == 120 and taps[1].y == 90,
            string.format("the tap must land where the client clicked, got %s,%s",
                tostring(taps[1].x), tostring(taps[1].y)))

        -- The same click with the mouse wobbling a pixel or two while the button is held: under
        -- the 4px drag threshold, so it must stay exactly one tap, at the release point, and the
        -- motion must not be forwarded.
        conn.sock:send(pointer(1, 200, 160))
        conn.sock:send(pointer(1, 201, 160))                    -- 1px while held ...
        conn.sock:send(pointer(1, 201, 161))                    -- ... 2px in total
        conn.sock:send(pointer(0, 200, 160))
        local tapped, polls = settle(function() return #taps == 2 end)
        assert_true(tapped, string.format(
            "a wobbling click must still be a tap, got %d tap(s) after %d poll(s) in 2 s",
            #taps, polls))
        assert_true(taps[2].x == 200 and taps[2].y == 160,
            string.format("the wobbling click must tap where it was released, got %s,%s",
                tostring(taps[2].x), tostring(taps[2].y)))
        assert_true(#moves == 0,
            "a wobbling click must not be a drag, got " .. table.concat(moves, ","))

        -- ... while a real drag must still be one: past the 4px threshold, and past the gesture
        -- detector's 35px pan threshold, so the motion reaches the widget and the lift is no tap.
        conn.sock:send(pointer(1, 300, 260))
        for step = 1, 10 do
            conn.sock:send(pointer(1, 300 + step * 10, 260))
        end
        conn.sock:send(pointer(0, 400, 260))
        local dragged, polls = settle(function() return #moves > 0 and #taps == 2 end)
        assert_true(dragged, string.format(
            "a real drag must still reach the widget, got no pan/swipe after %d poll(s) in 2 s",
            polls))
        assert_true(#taps == 2, "a real drag must not also be a tap, got " .. #taps .. " tap(s)")
        conn.sock:close()
    end)
    UIManager:close(widget)
    server:stop()
    if not ok then error(err, 0) end
end)

check("server_injects_client_input", function()
    -- A PointerEvent must become a KOReader gesture at the right position: that is what lets a
    -- remote VNC client tap, drag and long-press KOReader itself.
    local Server = require("vnc/server")
    local server = Server.new{ settings = { ip = "127.0.0.1", port = 5900, password = "" } }

    local seen = {}
    local original = UIManager.handleInputEvent
    UIManager.handleInputEvent = function(_, ev)
        seen[#seen + 1] = ev
    end
    local ok, err = pcall(function()
        local client = {}
        server:_on_pointer(client, 120, 90, 1)      -- press
        server:_on_pointer(client, 120, 90, 0)      -- release -> a tap
        assert_true(#seen > 0, "no event reached the UI")
        local ges
        for _, ev in ipairs(seen) do
            if ev.handler == "Gesture" or (ev.args and ev.args[1] and ev.args[1].pos) then ges = ev end
        end
        assert_true(ges ~= nil, "expected a gesture event, got " .. #seen .. " event(s)")

        -- named keys go through the device's own event_map inversion, so they arrive as real
        -- key events (arrows, Enter, PageDown, ...); text arrives as TextInput
        seen = {}
        server:_on_key(client, 0xFF54, true)            -- Down
        server:_on_key(client, 0xFF54, false)
        seen = {}
        server:_on_key(client, 0x61, true)              -- 'a'
        local got_text, handler = false, nil
        for _, ev in ipairs(seen) do
            handler = tostring(ev.handler)
            if ev.handler == "onTextInput" then got_text = true end
        end
        assert_true(got_text, "a printable keysym must arrive as TextInput, got " .. tostring(handler))
    end)
    UIManager.handleInputEvent = original
    if not ok then error(err, 0) end
end)

check("server_stays_live_after_a_client_pointer_press", function()
    -- The reported wedge, end to end: a client connects, takes the first full frame, and the
    -- moment its first PointerEvent (mouse down) is injected the session dies - no client input is
    -- injected any more, no frames go out - until somebody presses a key on the *local* device,
    -- after which it wedges again.
    --
    -- The press arms a hold timer, and `Input:setTimeout` arms it at `origin + delay`, where
    -- `origin` is the timestamp of the event that armed it, in the clock `GestureDetector` probed
    -- from the device's *own* events (`clock_id`) - CLOCK_MONOTONIC on every backend KOReader has
    -- today. The server used to stamp injected events with `os.time()`, i.e. CLOCK_REALTIME in
    -- whole seconds, so that timer's deadline landed ~56 years in the future. `Input:waitEvent`
    -- cannot give control back to UIManager while such a timer is pending: it keeps polling for a
    -- timer that cannot expire. The scheduled poll task therefore stops running - the client is
    -- never read and never written again - and only a *local* input event makes `waitForEvent`
    -- return, which is the "unclogs when a key is pressed locally" of the report; the timer is
    -- still armed at that point, which is why it wedges again right after.
    --
    -- This check drives the *real* UI loop and lets nobody else service the server, so it sees
    -- exactly that: with the button still held, a client key must still reach a widget and a
    -- recorded screen change must still reach the client, and the same must hold after the release.
    local Server = require("vnc/server")
    local socket = require("socket")
    local time = require("ui/time")
    require("ffi/linux_input_h")        -- EV_*/ABS_MT_*/BTN_TOUCH/SYN_REPORT (and ETIME)
    local C = ffi.C

    local server, port
    for candidate = 5981, 5989 do
        local s = Server.new{ settings = { ip = "127.0.0.1", port = candidate, password = "" } }
        if s:start() then server, port = s, candidate break end
    end
    assert_true(server ~= nil, "could not bind a test port")

    local Input = Device.input
    local real_wait = Input.input.waitForEvent
    -- A headless local input device: every wait just reports a timeout after a short sleep, so the
    -- loop can be driven by hand. A wait that never gives control back to UIManager is what the
    -- wedge looks like from the inside, so each step is budgeted - the longest wait that is
    -- legitimate here is the hold timer KOReader itself arms on a press (0.5s).
    local WEDGE_BUDGET = time.s(3)
    local step_deadline
    local function wedged()
        local timer = Input.timer_callbacks[1]
        local detail = ""
        if timer then
            local ahead = time.to_s(timer.deadline - time.now())
            if ahead > 1 then
                detail = string.format(
                    " (a timer armed from the injected event is due in %.0f s: the timestamp on the"
                    .. " injected event is not in the device's event clock)", ahead)
            end
        end
        return "the UI loop is stuck inside Input:waitEvent" .. detail
    end
    Input.input.waitForEvent = function()
        if step_deadline and time.now() > step_deadline then error(wedged(), 0) end
        socket.sleep(0.002)
        return false, C.ETIME
    end

    local InputContainer = require("ui/widget/container/inputcontainer")
    local keys = 0
    local widget = InputContainer:new{
        dimen = Screen:getSize(),
        key_events = { KeyPress = { { "Down" } } },
    }
    function widget:onKeyPress() keys = keys + 1 return true end
    UIManager:show(widget)

    -- Witness that the client's press is really delivered (a gesture at its coordinates reaching
    -- the UI), so the liveness assertions below cannot pass by the press simply being dropped.
    local gestures = {}
    local real_handle_input_event = UIManager.handleInputEvent
    UIManager.handleInputEvent = function(mgr, ev)
        if ev.handler == "onGesture" and ev.args and ev.args[1] and ev.args[1].pos then
            gestures[#gestures + 1] = ev.args[1]
        end
        return real_handle_input_event(mgr, ev)
    end

    --- One iteration of the real loop, the way UIManager:run drives it.
    local function ui_step()
        step_deadline = time.now() + WEDGE_BUDGET
        local ok, err = pcall(UIManager.handleInput, UIManager)
        if not ok then error(err, 0) end
    end

    --- Drives the loop for up to `seconds`, stopping early once `until_fn` says so.
    local function pump_ui(seconds, until_fn)
        local deadline = time.now() + time.s(seconds)
        while time.now() < deadline do
            ui_step()
            if until_fn and until_fn() then return true end
        end
        return not until_fn or until_fn()
    end

    --- Events for the local (device) side, stamped and routed the way a backend's are:
    --- ffi/SDL3.lua's genEmuEvent uses CLOCK_MONOTONIC_COARSE ("synthetic ones in the same timescale
    --- as the UI"). A tap like this is what the user performs on KOReader's own menu before the
    --- server ever sees a client, and it is what makes GestureDetector probe the device's clock.
    local function local_ev(ev_type, code, value)
        local sec, usec = time.split_s_us(time.monotonic_coarse())
        return { type = ev_type, code = code, value = value, time = { sec = sec, usec = usec } }
    end
    local function local_frame(evs)
        for _, ev in ipairs(evs) do
            if ev.type == C.EV_KEY then
                Input:handleKeyBoardEv(ev)
            else
                Input:handleTouchEv(ev)
            end
        end
    end
    local function local_tap(x, y)
        local_frame({
            local_ev(C.EV_ABS, C.ABS_MT_SLOT, 0),
            local_ev(C.EV_ABS, C.ABS_MT_TRACKING_ID, 1),
            local_ev(C.EV_ABS, C.ABS_MT_POSITION_X, x),
            local_ev(C.EV_ABS, C.ABS_MT_POSITION_Y, y),
            local_ev(C.EV_KEY, C.BTN_TOUCH, 1),
            local_ev(C.EV_SYN, C.SYN_REPORT, 0),
        })
        local_frame({
            local_ev(C.EV_ABS, C.ABS_MT_POSITION_X, x),
            local_ev(C.EV_ABS, C.ABS_MT_POSITION_Y, y),
            local_ev(C.EV_ABS, C.ABS_MT_SLOT, 0),
            local_ev(C.EV_ABS, C.ABS_MT_TRACKING_ID, -1),
            local_ev(C.EV_KEY, C.BTN_TOUCH, 0),
            local_ev(C.EV_SYN, C.SYN_REPORT, 0),
        })
    end

    local ok, err = pcall(function()
        local bb = Screen.bb
        local sw, sh = bb:getWidth(), bb:getHeight()
        bb:paintRect(0, 0, sw, sh, BB.COLOR_BLACK)
        server:_record_dirty("full", nil)

        -- From here on only the UI loop's own poll task services the server.
        local client = connect_client(server, port, set_encodings_wire(), ui_step)
        local cli = client.sock
        local plane = BB.new(sw, sh, BB.TYPE_BBRGB24)

        -- The device's own tap, which puts its event clock on record. Start from a blank slate (a
        -- device freshly booted, or one that just came back from suspend) so the clock this check
        -- depends on does not come from whatever an earlier check happened to inject.
        Input:resetState()
        local_tap(300, 300)
        assert_true(Input.gesture_detector:getClockSource() == C.CLOCK_MONOTONIC,
            "this check needs the device's events to be stamped like KOReader's own are")

        cli:send(client.request(false, 0, 0, sw, sh))
        assert_true(client.read_update(plane) >= 1, "the first full update must carry the screen")

        local function pointer(mask, x, y)
            return string.char(5, mask, math.floor(x / 256), x % 256, math.floor(y / 256), y % 256)
        end
        local key_down = string.char(4, 1, 0, 0, 0, 0, 0xFF, 0x54)   -- KeyEvent, keysym Down

        -- The press stays unreleased, which is the user's stuck state ...
        cli:send(pointer(1, 343, 36))

        -- ... and it is really delivered: a gesture at the client's coordinates reached the UI
        -- (the press itself, not only the liveness checks below, must come through).
        assert_true(pump_ui(1, function()
                for _, ges in ipairs(gestures) do
                    if ges.pos.x == 343 and ges.pos.y == 36 then return true end
                end
                return false
            end),
            "the client's press must reach KOReader as a gesture at the position it asked for")

        -- (a) a key from the client must still reach the widget with the button held
        local before = keys
        cli:send(key_down)
        assert_true(pump_ui(2, function() return keys > before end),
            "a client key must still be delivered while the client's button is held down")

        -- (b) a recorded change must still reach the client
        bb:paintRect(8, 8, 32, 24, BB.COLOR_WHITE)
        server:_record_dirty("partial", { x = 8, y = 8, w = 32, h = 24 })
        cli:send(client.request(true, 0, 0, sw, sh))
        assert_true(client.read_update(plane) >= 1,
            "a screen change must still be sent while the client's button is held down")
        local r, g, b = get(plane, 16, 16)
        assert_true(r > 200 and g > 200 and b > 200, "and the changed pixels must come through")

        -- The release lifts the contact and clears the hold timer: still live
        before = keys
        cli:send(pointer(0, 343, 36))
        cli:send(key_down)
        assert_true(pump_ui(2, function() return keys > before end),
            "a client key must still be delivered after the release")

        bb:paintRect(64, 64, 16, 16, BB.COLOR_WHITE)
        server:_record_dirty("partial", { x = 64, y = 64, w = 16, h = 16 })
        cli:send(client.request(true, 0, 0, sw, sh))
        assert_true(client.read_update(plane) >= 1, "and a change must still be sent after the release")

        plane:free()
        cli:close()
    end)

    Input.input.waitForEvent = real_wait
    UIManager.handleInputEvent = real_handle_input_event
    UIManager:close(widget)
    server:stop()
    if not ok then error(err, 0) end
end)

-- ------------------------------------------------- a click that stays a click (the real UI loop)

--- A PointerEvent as it arrives on the wire (RFC 6143 §7.5.5).
local function pointer_event(mask, x, y)
    return string.char(5, mask, math.floor(x / 256), x % 256, math.floor(y / 256), y % 256)
end

--- The stage the three checks below share: a server on a test port, a widget that records what
--- reaches it, and the *real* UI loop, driven step by step with a budgeted headless
--- `waitForEvent` exactly the way `server_stays_live_after_a_client_pointer_press` drives it - so
--- nothing but the scheduled poll task ever reads from or writes to the client.
---
--- Everything a check asserts on is recorded with the fts it happened at: the input frames the
--- server fed to Input (`injected`), the gestures the UI was told about (`ges`) and what the widget
--- did about them (`acted`), so that "the click came out as a hold" can be reported with the
--- numbers that show it.
---
--- Also returned: `server`, `client` (the wire connection, already past its first full update),
--- `plane`, `sw`, `sh`, `hold_interval` (the detector's own long-press interval, in fts),
--- `ui_step()`, `pump_ui(seconds, until_fn)`, `send_later(seconds, msg)` - a message an independent
--- client would have put on the wire by then, flushed from inside the UI loop's own wait -
--- `describe()`, and `restore()` (nil-safe; a check that failed early can still call it).
local function live_input_stage()
    local Server = require("vnc/server")
    local socket = require("socket")
    local time = require("ui/time")
    require("ffi/linux_input_h")        -- EV_*/ABS_MT_*/BTN_TOUCH/SYN_REPORT (and ETIME)
    local C = ffi.C
    local InputContainer = require("ui/widget/container/inputcontainer")
    local GestureRange = require("ui/gesturerange")

    local server, port
    for candidate = 5991, 5999 do
        local s = Server.new{ settings = { ip = "127.0.0.1", port = candidate, password = "" } }
        if s:start() then server, port = s, candidate break end
    end
    assert_true(server ~= nil, "could not bind a test port")

    local bb = Screen.bb
    local sw, sh = bb:getWidth(), bb:getHeight()
    bb:paintRect(0, 0, sw, sh, BB.COLOR_BLACK)
    server:_record_dirty("full", nil)

    local Input = Device.input
    local hold_interval = Input.gesture_detector.ges_hold_interval

    local injected, ges, acted = {}, {}, {}

    -- A headless local input device: every wait reports a timeout after a short sleep, so the loop
    -- can be driven by hand - and a wait that cannot give control back to UIManager (the UI thread
    -- stuck on a timer) is reported instead of hanging the suite.
    local WEDGE_BUDGET = time.s(3)
    local step_deadline
    local real_wait = Input.input.waitForEvent
    -- A client puts its bytes on the wire when it wants them read. While the UI thread is inside
    -- `waitEvent` (which is where it goes while it is blocked on a timer) nothing else in this test
    -- runs, so this is where the test's own client acts - exactly as another process' bytes would
    -- already be in the kernel's buffer when the poll task finally gets around to reading them.
    local sends, stage_client = {}, nil
    local function flush_sends()
        for i = #sends, 1, -1 do
            if sends[i].at <= time.now() then
                stage_client.sock:send(sends[i].msg)
                table.remove(sends, i)
            end
        end
    end
    Input.input.waitForEvent = function()
        if stage_client then flush_sends() end
        if step_deadline and time.now() > step_deadline then
            local timer = Input.timer_callbacks[1]
            local detail = ""
            if timer then
                detail = string.format(" (a pending input timer is due in %.1f s: the loop is not"
                    .. " returning to UIManager)", time.to_s(timer.deadline - time.now()))
            end
            error("the UI loop is stuck inside Input:waitForEvent" .. detail, 0)
        end
        socket.sleep(0.002)
        return false, C.ETIME
    end

    -- Every input frame the server feeds to Input, and its kind: whether the client's press was
    -- injected on its own (before its release could be read) or together with the release, is
    -- exactly what the checks below measure.
    local real_handle_touch = Input.handleTouchEv
    local frame_kind
    Input.handleTouchEv = function(input, ev)
        if ev.type == C.EV_ABS then
            if ev.code == C.ABS_MT_TRACKING_ID then
                frame_kind = ev.value == -1 and "lift" or "down"
            elseif ev.code == C.ABS_MT_POSITION_X and not frame_kind then
                frame_kind = "motion"
            end
        elseif ev.type == C.EV_SYN and ev.code == C.SYN_REPORT then
            injected[#injected + 1] = { kind = frame_kind or "?", t = time.now() }
            frame_kind = nil
        end
        return real_handle_touch(input, ev)
    end

    -- Every gesture the UI is told about, and what a real widget did about it.
    local real_handle_input_event = UIManager.handleInputEvent
    UIManager.handleInputEvent = function(mgr, ev)
        if ev.handler == "onGesture" and ev.args and ev.args[1] and ev.args[1].pos then
            local g = ev.args[1]
            ges[#ges + 1] = { ges = g.ges, x = g.pos.x, y = g.pos.y, t = time.now() }
        end
        return real_handle_input_event(mgr, ev)
    end

    local full_range = Geom:new{ x = 0, y = 0, w = 4000, h = 4000 }
    local widget = InputContainer:new{
        dimen = Screen:getSize(),
        ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = full_range } },
            Hold = { GestureRange:new{ ges = "hold", range = full_range } },
            HoldRelease = { GestureRange:new{ ges = "hold_release", range = full_range } },
            Pan = { GestureRange:new{ ges = "pan", range = full_range } },
            Swipe = { GestureRange:new{ ges = "swipe", range = full_range } },
        },
        key_events = { KeyPress = { { "Down" } } },
    }
    local function recorder(what)
        -- `EventListener:handleEvent` calls the handler as `handler(self, event.args...)`, and the
        -- gesture is the *second* of those (the first is the `ges_events` entry's own `args`).
        return function(_, _, ges)
            acted[#acted + 1] = { what = what, x = ges and ges.pos and ges.pos.x or nil,
                                  y = ges and ges.pos and ges.pos.y or nil }
            return true
        end
    end
    widget.onTap = recorder("tap")
    widget.onHold = recorder("hold")
    widget.onHoldRelease = recorder("hold_release")
    widget.onPan = recorder("pan")
    widget.onSwipe = recorder("swipe")
    widget.onKeyPress = function() acted[#acted + 1] = { what = "key" } return true end
    UIManager:show(widget)

    --- One iteration of the real loop, the way UIManager:run drives it.
    local function ui_step()
        step_deadline = time.now() + WEDGE_BUDGET
        local ok, err = pcall(UIManager.handleInput, UIManager)
        if not ok then error(err, 0) end
    end

    --- Drives the loop for up to `seconds`, stopping early once `until_fn` says so.
    local function pump_ui(seconds, until_fn)
        local deadline = time.now() + time.s(seconds)
        while time.now() < deadline do
            ui_step()
            if until_fn and until_fn() then return true end
        end
        return not until_fn or until_fn()
    end

    --- Events for the local (device) side, stamped and routed the way a backend's are:
    --- ffi/SDL3.lua's genEmuEvent uses CLOCK_MONOTONIC_COARSE ("synthetic ones in the same timescale
    --- as the UI"). A tap like this is what the user performs on KOReader's own menu before the
    --- server ever sees a client, and it is what makes GestureDetector probe the device's clock.
    local function local_ev(ev_type, code, value)
        local sec, usec = time.split_s_us(time.monotonic_coarse())
        return { type = ev_type, code = code, value = value, time = { sec = sec, usec = usec } }
    end
    local function local_frame(evs)
        for _, ev in ipairs(evs) do
            if ev.type == C.EV_KEY then
                Input:handleKeyBoardEv(ev)
            else
                Input:handleTouchEv(ev)
            end
        end
    end
    local function local_tap(x, y)
        local_frame({
            local_ev(C.EV_ABS, C.ABS_MT_SLOT, 0),
            local_ev(C.EV_ABS, C.ABS_MT_TRACKING_ID, 1),
            local_ev(C.EV_ABS, C.ABS_MT_POSITION_X, x),
            local_ev(C.EV_ABS, C.ABS_MT_POSITION_Y, y),
            local_ev(C.EV_KEY, C.BTN_TOUCH, 1),
            local_ev(C.EV_SYN, C.SYN_REPORT, 0),
        })
        local_frame({
            local_ev(C.EV_ABS, C.ABS_MT_POSITION_X, x),
            local_ev(C.EV_ABS, C.ABS_MT_POSITION_Y, y),
            local_ev(C.EV_ABS, C.ABS_MT_SLOT, 0),
            local_ev(C.EV_ABS, C.ABS_MT_TRACKING_ID, -1),
            local_ev(C.EV_KEY, C.BTN_TOUCH, 0),
            local_ev(C.EV_SYN, C.SYN_REPORT, 0),
        })
    end

    -- Start from a blank slate (a device freshly booted, or one that just came back from suspend),
    -- so the clock this stage depends on does not come from whatever an earlier check injected,
    -- then let the device's own tap put its event clock on record.
    Input:resetState()
    local_tap(300, 300)
    assert_true(Input.gesture_detector:getClockSource() == C.CLOCK_MONOTONIC,
        "this stage needs the device's events to be stamped like KOReader's own are")
    -- The device's own tap above is not the *server's* input: the records below are about what the
    -- server injects, so they start from an empty slate.
    for i = #injected, 1, -1 do table.remove(injected, i) end

    local client, plane
    -- The poll task's runs, and how often our connection was *answered* (the protocol moved its
    -- `sent_gen`, i.e. an update - if only an empty one - was produced and written in that run).
    -- This is the server-side fact behind "updates keep flowing", and unlike reading the socket it
    -- does not depend on when this single-threaded test gets around to it (every socket read below
    -- can cost a 200 ms receive timeout, which is more than the hold interval).
    local stats = { polls = 0, served = 0 }
    local server_client
    local real_poll = server._poll
    server._poll = function(srv)
        stats.polls = stats.polls + 1
        local before = server_client and server_client.sent_gen
        real_poll(srv)
        if server_client and server_client.sent_gen ~= before then
            stats.served = stats.served + 1
        end
    end

    local function restore()
        server._poll = real_poll
        Input.input.waitForEvent = real_wait
        Input.handleTouchEv = real_handle_touch
        UIManager.handleInputEvent = real_handle_input_event
        UIManager:close(widget)
        if client then client.sock:close() end
        Input:resetState()
        server:stop()
    end

    local connected, connect_err = pcall(function()
        -- From here on only the UI loop's own poll task services the server.
        client = connect_client(server, port, set_encodings_wire(), ui_step)
        stage_client = client
        for _, record in pairs(server.clients) do server_client = record.server.client end
        plane = BB.new(sw, sh, BB.TYPE_BBRGB24)
        client.sock:send(client.request(false, 0, 0, sw, sh))
        assert_true(client.read_update(plane) >= 1, "the first full update must carry the screen")
    end)
    if not connected then
        restore()
        error(connect_err, 0)
    end

    --- A one-line account of what happened, for the failure messages: the frames the server
    --- injected (kind, and when, relative to the first of them), the gestures the UI was told
    --- about, and what the widget acted on.
    local function describe()
        local t0 = injected[1] and injected[1].t or (ges[1] and ges[1].t) or time.now()
        local f = {}
        for _, fr in ipairs(injected) do
            f[#f + 1] = string.format("%s@+%dms", fr.kind, time.to_ms(fr.t - t0))
        end
        local g = {}
        for _, ge in ipairs(ges) do
            g[#g + 1] = string.format("%s@+%dms", ge.ges, time.to_ms(ge.t - t0))
        end
        local a = {}
        for _, w in ipairs(acted) do a[#a + 1] = w.what end
        return string.format("input frames [%s], UI gestures [%s], widget acted on [%s]",
            table.concat(f, " "), table.concat(g, " "), table.concat(a, " "))
    end

    local function send_later(seconds, msg)
        sends[#sends + 1] = { at = time.now() + time.s(seconds), msg = msg }
    end

    return {
        server = server, client = client, plane = plane, sw = sw, sh = sh,
        hold_interval = hold_interval, stats = stats,
        injected = injected, ges = ges, acted = acted,
        ui_step = ui_step, pump_ui = pump_ui, send_later = send_later,
        describe = describe, restore = restore,
    }
end

-- ---------------------------------------------------------------- a key-driven repaint

--- The stage the three key-repaint checks below share: a real widget that repaints itself when the
--- UI sends it a key, a client that holds an incremental request, and the real UI loop, driven step
--- by step with the budgeted headless `waitForEvent` the live input stages above use.
---
--- Unlike their widget, which only records what it is told, this one *paints*: `paintTo` writes a
--- 64x64 patch into the framebuffer the server captures from, and a key press flips the patch's
--- colour and asks for it with `UIManager:setDirty` - a widget's own repaint, with the painting left
--- to the `UIManager:_repaint` that follows the handler, which is the shape of the reported bug. The
--- pixels the client gets can therefore be compared against the screen's, so "the frame carried the
--- repaint" is a claim about pixels and not about bookkeeping.
---
--- Returned: the server and its client (already past its first full update), `plane` (what the
--- client has assembled) and `reference` (the screen), `ui_step`, `snapshot()` (re-reads the screen
--- into `reference`), `hold_a_request()` (leaves the client with a request the server has *nothing*
--- to answer, i.e. held), `take_frame(budget)` (reads the next update, allowing the loop at most
--- `budget` more iterations and failing if it needs more), the patch's `rect` and the widget's
--- counters, `queue_local_key()` (a raw EV_KEY a local keyboard would have waiting, delivered by the
--- loop's own `Input:waitEvent` on its next step), `describe()` and `restore()`.
local function live_repaint_stage()
    local Server = require("vnc/server")
    local socket = require("socket")
    local time = require("ui/time")
    require("ffi/linux_input_h")        -- EV_KEY / SYN_REPORT (and ETIME)
    local C = ffi.C
    local InputContainer = require("ui/widget/container/inputcontainer")

    local server, port
    for candidate = 5931, 5939 do
        local s = Server.new{ settings = { ip = "127.0.0.1", port = candidate, password = "" } }
        if s:start() then server, port = s, candidate break end
    end
    assert_true(server ~= nil, "could not bind a test port")

    local bb = Screen.bb
    local sw, sh = bb:getWidth(), bb:getHeight()
    assert_true(sw >= 128 and sh >= 128, "the screen must hold this stage's patch")
    local RECT, RX, RY = 64, 16, 16

    -- A black screen, recorded as one full-frame change: whatever the client reads first is *this*
    -- screen, so any later pixel that differs from the reference is a change this stage made.
    bb:paintRect(0, 0, sw, sh, BB.COLOR_BLACK)
    server:_record_dirty("full", nil)

    local Input = Device.input
    local WEDGE_BUDGET = time.s(3)
    local step_deadline
    local queued = {}
    local real_wait = Input.input.waitForEvent
    -- A headless local input device: it reports a timeout after a short sleep (so the loop can be
    -- driven by hand) and hands over whatever local events have been queued for it - the same array
    -- of Linux input events a real backend's `waitForEvent` returns. A local key therefore goes
    -- through `Input:waitEvent` and `UIManager:handleInputEvent` exactly as a device's own keyboard
    -- does, with no client message anywhere near it.
    Input.input.waitForEvent = function()
        if step_deadline and time.now() > step_deadline then
            error("the UI loop is stuck inside Input:waitForEvent", 0)
        end
        socket.sleep(0.002)
        if #queued > 0 then
            local evs = queued
            queued = {}
            return true, evs
        end
        return false, C.ETIME
    end

    -- The device's own input code for the key the widget listens for: the far end of the server's
    -- keysym -> KOReader key name -> input code mapping, and what a local keyboard delivers.
    local key_code
    for code, name in pairs(Input.event_map or {}) do
        if name == "Down" then key_code = code break end
    end
    assert_true(key_code ~= nil, "this device has no key named Down")

    local stage = { bright = false, paints = 0, keys = 0 }
    local widget = InputContainer:new{
        dimen = Geom:new{ x = RX, y = RY, w = RECT, h = RECT },
        key_events = { KeyPress = { { "Down" } } },
    }
    --- A real repaint: the patch goes into the framebuffer the server captures from, at the
    --- coordinates the handler below asks to be refreshed.
    function widget:paintTo(target)
        stage.paints = stage.paints + 1
        target:paintRect(RX, RY, RECT, RECT, stage.bright and BB.COLOR_WHITE or BB.COLOR_BLACK)
    end
    function widget:onKeyPress()
        stage.keys = stage.keys + 1
        if stage.handler_delay then
            -- A handler that takes longer than one poll interval - a page turn that has to render is
            -- the ordinary case - so that by the time the loop comes back to its task pass the poll
            -- is already due. That is the state a *local* key press finds itself in when the
            -- reported bug loses its repaint (c.f., the check that sets this).
            socket.sleep(stage.handler_delay)
        end
        stage.bright = not stage.bright
        UIManager:setDirty(widget, "ui", Geom:new{ x = RX, y = RY, w = RECT, h = RECT })
        return true
    end
    UIManager:show(widget)

    -- One iteration of the real loop, the way UIManager:run drives it.
    local function ui_step()
        step_deadline = time.now() + WEDGE_BUDGET
        local ok, err = pcall(UIManager.handleInput, UIManager)
        if not ok then error(err, 0) end
    end

    -- How many UI iterations a read in progress may drive before the frame has to be there: a key
    -- repaints the widget in one iteration (the `_repaint` at its end) and the poll that follows
    -- records and answers it in the next, so a budget of two is "within a poll or two" - and nothing
    -- more, so a frame that never came cannot hide behind a longer wait.
    local pump_budget
    local function pump()
        if pump_budget then
            pump_budget = pump_budget - 1
            assert_true(pump_budget >= 0,
                "the client's update must arrive within a poll or two of the repaint it answers")
        end
        ui_step()
    end

    local plane = BB.new(sw, sh, BB.TYPE_BBRGB24)       -- what the client has assembled
    local reference = BB.new(sw, sh, BB.TYPE_BBRGB24)   -- what the screen holds
    local client = connect_client(server, port, set_encodings_wire(), pump)
    local cli = client.sock
    local server_client
    for _, record in pairs(server.clients) do server_client = record.server.client end
    assert_true(server_client ~= nil, "the client's connection state must exist")
    cli:send(client.request(false, 0, 0, sw, sh))
    assert_true(client.read_update(plane) >= 1, "the first full update must carry the screen")

    local function snapshot()
        reference:blitFrom(bb, 0, 0, 0, 0, sw, sh)
    end
    snapshot()

    --- Leaves the client holding a request that has nothing to answer, so the only thing that can
    --- produce the next frame is a change recorded *after* this point. Client messages are read by
    --- the poll task, so this pumps the loop until it has - with `held` as the proof - and fails
    --- both if it never does and if the request was answered instead (which would mean something
    --- was recorded that this stage did not make).
    local function hold_a_request()
        cli:send(client.request(true, 0, 0, sw, sh))
        local sent_before = server_client.sent_gen
        local deadline = socket.gettime() + 2
        while server_client.held == nil and server_client.sent_gen == sent_before
                and socket.gettime() < deadline do
            ui_step()
        end
        assert_true(server_client.held ~= nil and server_client.sent_gen == sent_before,
            string.format("the stage needs the server to hold an incremental request that has"
                .. " nothing to answer (gen=%d sent_gen=%s, was %s; evicted=%d dirty=%d)",
                server._gen, tostring(server_client.sent_gen), tostring(sent_before),
                server._evicted_gen, #server._dirty))
    end

    --- The frame that answers the held request, with at most `budget` further UI iterations allowed
    --- to produce it. Anything else - nothing ever arriving, or arriving only after the loop was
    --- pumped further - fails in the read rather than passing on a longer wait.
    local function take_frame(budget)
        pump_budget = budget
        local nrects, rects = client.read_update(plane)
        pump_budget = nil
        return nrects, rects
    end

    --- A key press from the *local* device: queued for the loop's own `Input:waitEvent`, with no
    --- client message and no poll task involvement in delivering it.
    local function queue_local_key()
        local sec, usec = time.split_s_us(time.monotonic_coarse())
        queued[#queued + 1] = { type = C.EV_KEY, code = key_code, value = 1,
                                time = { sec = sec, usec = usec } }
    end

    --- One-line account of what happened, for the failure messages: what the client holds at the
    --- patch, what the screen holds there, and how the widgets and the request got there.
    local function describe(what)
        local r, g, b = get(plane, RX + 4, RY + 4)
        local wr, wg, wb = get(reference, RX + 4, RY + 4)
        return string.format("%s: %d key(s), %d paint(s), client pixel at %d,%d = %d,%d,%d,"
            .. " screen holds %d,%d,%d (%s)", what, stage.keys, stage.paints, RX + 4, RY + 4,
            r, g, b, wr, wg, wb, server_client.held and "request still held" or "request answered")
    end

    local function restore()
        Input.input.waitForEvent = real_wait
        UIManager:close(widget)
        cli:close()
        server:stop()
        plane:free()
        reference:free()
    end

    return {
        server = server, client = client, client_state = server_client, plane = plane,
        reference = reference, ui_step = ui_step, snapshot = snapshot, describe = describe,
        hold_a_request = hold_a_request, take_frame = take_frame, queue_local_key = queue_local_key,
        restore = restore, stage = stage, rect = { x = RX, y = RY, w = RECT, h = RECT },
    }
end

--- The reported defect, end to end: a keyboard event makes a widget repaint, a client is holding a
--- request, and the frame answering it must carry the pixels of that repaint - within a poll or two,
--- with no following event to push it along.
---
--- It cannot, if the rectangle is recorded when `UIManager:_refresh` is called: that only *enqueues*
--- the refresh, and the widget is painted by the `UIManager:_repaint` the UI loop runs next - while a
--- key the *server* injects is delivered from the poll task, i.e. inside the loop's own task pass, so
--- the poll answers the held request before that `_repaint` has painted anything. The frame then
--- carries the pixels from *before* the key, and `sent_gen` has moved past a change the client never
--- saw: it shows the old screen until a later event records another generation, which is the "a
--- keyboard-driven repaint arrives one event late" of the report. A click looked immune only because
--- the widgets a click lands on repaint through `forceRePaint`, which paints inside the injection.
check("a_client_click_in_the_live_loop_is_a_tap", function()
    -- The reported defect: a client *click* (press, then release ~100 ms later) is delivered as a
    -- *hold*. Once any contact is down, core arms its hold timer (`Contact:handleNonTap` ->
    -- `Input:setTimeout(slot, "hold", cb, tev.timev, ges_hold_interval)`), and `Input:waitEvent`
    -- does not give control back to UIManager while an input timer is pending - it keeps polling
    -- the *device* for one that expires. A press injected the moment it is read therefore starves
    -- this very poll task: the client's release cannot be read, so the hold fires first and the
    -- click comes out as onHold + onHoldRelease.
    --
    -- A click is press *and* release, so it can be judged before anything is injected: the server
    -- can keep the client's contact to itself for a moment and, once the release is in, hand core a
    -- contact down and up in one frame - which is what the kernel delivers for a click too. Nothing
    -- is pending on the UI thread then, so the loop keeps running and the release is read the
    -- moment it arrives.
    local stage = live_input_stage()
    local ok, err = pcall(function()
        local time = require("ui/time")
        local cli = stage.client.sock
        local bb, plane = Screen.bb, stage.plane

        -- Updates flow before the click (a viewer keeps an incremental request outstanding).
        bb:paintRect(8, 8, 32, 24, BB.COLOR_WHITE)
        stage.server:_record_dirty("partial", { x = 8, y = 8, w = 32, h = 24 })
        cli:send(stage.client.request(true, 0, 0, stage.sw, stage.sh))
        assert_true(stage.client.read_update(plane) >= 1,
            "a change must reach the client before the click (" .. stage.describe() .. ")")
        local r, g, b = get(plane, 16, 16)
        assert_true(r > 200 and g > 200 and b > 200,
            "and the changed pixels must come through (" .. stage.describe() .. ")")

        -- The click: the press now, the release 100 ms later, both while the real loop runs. The
        -- release goes on the wire from inside the loop's own wait, because that is what an
        -- independent client does - it does not wait to be read.
        cli:send(pointer_event(1, 343, 36))
        stage.send_later(0.1, pointer_event(0, 343, 36))

        -- Let it finish.
        assert_true(stage.pump_ui(2, function()
                for _, w in ipairs(stage.acted) do
                    if w.what == "tap" or w.what == "hold" then return true end
                end
                return false
            end),
            "the click must reach the widget (" .. stage.describe() .. ")")

        local kinds, order = {}, {}
        for _, w in ipairs(stage.acted) do kinds[w.what] = true order[#order + 1] = w.what end
        local down, lift
        for _, f in ipairs(stage.injected) do
            if f.kind == "down" and not down then down = f end
            if f.kind == "lift" and not lift then lift = f end
        end
        print(string.format("   [click] press and release injected %d ms apart (hold interval %d ms),"
            .. " hold fired: %s, widget: %s",
            down and lift and time.to_ms(lift.t - down.t) or -1, time.to_ms(stage.hold_interval),
            kinds.hold and "yes" or "no", table.concat(order, ",")))

        assert_true(kinds.tap,
            "a fast client click must reach the widget as onTap (" .. stage.describe() .. ")")
        assert_true(not kinds.hold and not kinds.hold_release,
            "a fast client click must not be a hold (" .. stage.describe() .. ")")
        assert_true(stage.acted[1].what == "tap" and stage.acted[1].x == 343 and stage.acted[1].y == 36,
            string.format("the tap must land where the client clicked, got %s at %s,%s (%s)",
                stage.acted[1].what, tostring(stage.acted[1].x), tostring(stage.acted[1].y),
                stage.describe()))
        for _, ge in ipairs(stage.ges) do
            assert_true(ge.ges ~= "hold",
                "the detector must not judge a click a hold (" .. stage.describe() .. ")")
        end
        assert_true(down and lift, "the click must be injected as a press and a release ("
            .. stage.describe() .. ")")
        assert_true(time.to_ms(lift.t - down.t) < time.to_ms(stage.hold_interval),
            string.format("the release was injected %d ms after the press, i.e. only once core's"
                .. " hold timer had fired: the click had become a hold (%s)",
                time.to_ms(lift.t - down.t), stage.describe()))

        -- Updates keep flowing afterwards, too.
        bb:paintRect(64, 64, 16, 16, BB.COLOR_WHITE)
        stage.server:_record_dirty("partial", { x = 64, y = 64, w = 16, h = 16 })
        cli:send(stage.client.request(true, 0, 0, stage.sw, stage.sh))
        assert_true(stage.client.read_update(plane) >= 1,
            "a change must still reach the client after the click")
        local r2, g2, b2 = get(plane, 68, 68)
        assert_true(r2 > 200 and g2 > 200 and b2 > 200, "and the changed pixels must come through")
    end)
    stage.restore()
    if not ok then error(err, 0) end
end)

check("a_client_button_held_past_the_hold_interval_is_a_hold", function()
    -- A long press has to stay a long press. The server keeps a client's contact to itself only
    -- until it is clear which gesture it is: with the button still down after the detector's own
    -- long-press interval it is a hold, so the press is injected on its own *then* and core's timer
    -- (armed from that injected event) runs it, exactly as for a finger. The release closes it as a
    -- hold_release, and no tap is involved.
    local stage = live_input_stage()
    local ok, err = pcall(function()
        local time = require("ui/time")
        local cli = stage.client.sock
        local bb, plane = Screen.bb, stage.plane
        local t_press = time.now()

        cli:send(pointer_event(1, 200, 200))

        -- The press must *not* be injected on sight: a press injected now would arm core's hold
        -- timer, and while that timer is pending `Input:waitEvent` never returns to UIManager - so
        -- this poll task, the only thing that can read the client's release, would not run again
        -- until the hold had fired. Give the loop ~150 ms to read the press: no frame may have been
        -- injected with it.
        stage.pump_ui(0.15)
        assert_true(#stage.injected == 0,
            "the client's press must not be injected before the hold interval is up - a press"
            .. " injected on sight starves the poll task that has to read the release ("
            .. stage.describe() .. ")")

        -- While the contact is only held back, nothing is pending on the UI thread, so the loop
        -- keeps servicing the client: the poll task runs, and an update request is answered within
        -- it (the protocol moves the connection's `sent_gen`, which is it producing - and writing -
        -- an update, empty or not). That is what "updates keep flowing" means here, and it is also
        -- what lets a release be noticed next.
        bb:paintRect(8, 8, 32, 24, BB.COLOR_WHITE)
        stage.server:_record_dirty("partial", { x = 8, y = 8, w = 32, h = 24 })
        local polls_before, served_before = stage.stats.polls, stage.stats.served
        cli:send(stage.client.request(true, 0, 0, stage.sw, stage.sh))
        stage.pump_ui(0.15)
        print(string.format("   [hold] while buffered: %d poll(s), %d update(s) answered",
            stage.stats.polls - polls_before, stage.stats.served - served_before))
        assert_true(stage.stats.served > served_before,
            "the client's update request must be answered while the contact is only held back ("
            .. stage.describe() .. ")")
        assert_true(stage.stats.polls - polls_before >= 5,
            string.format("the poll task must keep running while the contact is held back: it ran"
                .. " %d time(s) (%s)", stage.stats.polls - polls_before, stage.describe()))
        assert_true(#stage.injected == 0 and #stage.acted == 0,
            "the contact must still only be held back at this point (" .. stage.describe() .. ")")
        -- Take the answer that was produced: it is what the client would have drawn, and it must
        -- not be left in the socket for the "after the release" read below to trip over.
        assert_true(stage.client.read_update(plane) >= 1,
            "the update answered while the contact was held back must reach the client ("
            .. stage.describe() .. ")")

        -- Hold it past the interval; the release follows once the hold has fired.
        stage.send_later(0.7, pointer_event(0, 200, 200))
        assert_true(stage.pump_ui(3, function()
                for _, w in ipairs(stage.acted) do
                    if w.what == "hold_release" then return true end
                end
                return false
            end),
            "a held button must reach the widget as a hold and its release ("
            .. stage.describe() .. ")")

        local order = {}
        for _, w in ipairs(stage.acted) do order[#order + 1] = w.what end
        local down
        for _, f in ipairs(stage.injected) do
            if f.kind == "down" then down = f break end
        end
        local hold_at
        for _, ge in ipairs(stage.ges) do
            if ge.ges == "hold" then hold_at = ge.t break end
        end
        print(string.format("   [hold] press injected %d ms after the client's press (hold interval"
            .. " %d ms), hold %d ms after the client's press (%d ms after the injection), widget: %s",
            down and time.to_ms(down.t - t_press) or -1, time.to_ms(stage.hold_interval),
            hold_at and time.to_ms(hold_at - t_press) or -1,
            down and hold_at and time.to_ms(hold_at - down.t) or -1, table.concat(order, ",")))

        assert_true(table.concat(order, ",") == "hold,hold_release",
            "a held button must be onHold first, then its release: got ["
            .. table.concat(order, ",") .. "] (" .. stage.describe() .. ")")
        assert_true(down and down.t - t_press >= stage.hold_interval - time.ms(2),
            string.format("the press was injected %d ms after the client pressed it, i.e. before"
                .. " the %d ms hold interval was up (%s)", down and time.to_ms(down.t - t_press) or -1,
                time.to_ms(stage.hold_interval), stage.describe()))
        -- The injected frame carries the moment the client's press was read, so core's own hold
        -- timer is due the moment it is armed: the widget gets onHold one interval after the
        -- client pressed, exactly where a finger's long press would be.
        assert_true(hold_at and hold_at - t_press >= stage.hold_interval - time.ms(2),
            string.format("the hold must reach the widget one hold interval after the client"
                .. " pressed, got %d ms (%s)", hold_at and time.to_ms(hold_at - t_press) or -1,
                stage.describe()))

        -- ... and updates keep flowing after the release.
        bb:paintRect(64, 64, 16, 16, BB.COLOR_WHITE)
        stage.server:_record_dirty("partial", { x = 64, y = 64, w = 16, h = 16 })
        cli:send(stage.client.request(true, 0, 0, stage.sw, stage.sh))
        assert_true(stage.client.read_update(plane) >= 1,
            "a change must still reach the client after the release")
        local r2, g2, b2 = get(plane, 68, 68)
        assert_true(r2 > 200 and g2 > 200 and b2 > 200, "and the changed pixels must come through")
    end)
    stage.restore()
    if not ok then error(err, 0) end
end)

check("a_client_drag_in_the_live_loop_is_a_pan", function()
    -- A drag must keep its meaning (and its 4 px threshold) while a client's contact is held back:
    -- motion that stays within 4 px of the press point is a mouse wobble and the click is a tap,
    -- while motion beyond it is a drag - and then the press is injected together with the motion
    -- that made it a drag.
    local stage = live_input_stage()
    local ok, err = pcall(function()
        local time = require("ui/time")
        local cli = stage.client.sock
        local bb, plane = Screen.bb, stage.plane

        -- Motion with no button down is nothing KOReader has: no hover, so nothing may be injected.
        cli:send(pointer_event(0, 500, 500))
        -- Long enough, in wall clock, for a motion the server *had* forwarded to have come out the
        -- other end: "nothing was injected" is only evidence if the loop had the time to do it.
        stage.pump_ui(0.2)
        assert_true(#stage.injected == 0 and #stage.acted == 0,
            "motion without a button down must be forwarded to nothing (" .. stage.describe() .. ")")

        -- (1) A wobble under the threshold stays a tap, at the point it was released.
        cli:send(pointer_event(1, 300, 260))
        cli:send(pointer_event(1, 301, 260))
        cli:send(pointer_event(1, 301, 261))
        cli:send(pointer_event(0, 300, 260))
        assert_true(stage.pump_ui(1, function() return #stage.acted > 0 end),
            "a click with a 2 px wobble must reach the widget (" .. stage.describe() .. ")")
        assert_true(stage.acted[1].what == "tap" and stage.acted[1].x == 300
                and stage.acted[1].y == 260,
            "a 2 px wobble is not a drag: the tap lands where it was released ("
            .. stage.describe() .. ")")
        for _, f in ipairs(stage.injected) do
            assert_true(f.kind ~= "motion",
                "motion within the 4 px threshold must not be forwarded (" .. stage.describe() .. ")")
        end

        -- (2) Past the threshold it is a drag - and it must not be judged a hold, which is what a
        -- press injected on its own becomes when the motion behind it has to wait for a pending
        -- hold timer to fire before this poll task can run again.
        local mark_f, mark_w = #stage.injected, #stage.acted
        cli:send(pointer_event(1, 300, 320))                    -- press
        stage.send_later(0.02, pointer_event(1, 340, 320))      -- 40 px: past the 4 px threshold
        stage.send_later(0.05, pointer_event(1, 380, 320))      -- ... and the detector's own 35 px
        stage.send_later(0.1, pointer_event(1, 420, 320))       --     pan threshold
        stage.send_later(0.25, pointer_event(0, 420, 320))
        assert_true(stage.pump_ui(3, function()
                for i = mark_w + 1, #stage.acted do
                    local what = stage.acted[i].what
                    if what == "pan" or what == "swipe" or what == "hold" or what == "tap" then
                        return true
                    end
                end
                return false
            end),
            "a drag must reach the widget as a pan or a swipe (" .. stage.describe() .. ")")

        local what, order, motion = {}, {}, 0
        for i = mark_w + 1, #stage.acted do
            what[stage.acted[i].what] = true
            order[#order + 1] = stage.acted[i].what
        end
        for i = mark_f + 1, #stage.injected do
            if stage.injected[i].kind == "motion" then motion = motion + 1 end
        end
        print(string.format("   [drag] %d motion frame(s) injected, widget: %s",
            motion, table.concat(order, ",")))
        assert_true(what.pan or what.swipe,
            "a drag past the threshold must reach the widget as a pan or a swipe ("
            .. stage.describe() .. ")")
        assert_true(not what.tap, "a drag must not be a tap (" .. stage.describe() .. ")")
        assert_true(not what.hold, "a drag must not be a hold (" .. stage.describe() .. ")")
        assert_true(motion > 0,
            "a drag past the 4 px threshold must forward the motion (" .. stage.describe() .. ")")

        -- An update after the drag (the drag itself must not have left a timer behind).
        bb:paintRect(64, 64, 16, 16, BB.COLOR_WHITE)
        stage.server:_record_dirty("partial", { x = 64, y = 64, w = 16, h = 16 })
        cli:send(stage.client.request(true, 0, 0, stage.sw, stage.sh))
        assert_true(stage.client.read_update(plane) >= 1,
            "a change must still reach the client after the drag (" .. stage.describe() .. ")")
        local r, g, b = get(plane, 68, 68)
        assert_true(r > 200 and g > 200 and b > 200, "and the changed pixels must come through")

        -- Where the rest of the drag went: the contact's remaining motion is only read once core's
        -- hold timer - armed by the injected down, as it is for a finger - has expired, because
        -- `Input:waitEvent` does not give UIManager (and so this poll task) back before that. A
        -- finger's own motion arrives on the device fd and breaks that wait; a socket's cannot.
        local motions, down_at, lift_at = 0, nil, nil
        for i = mark_f + 1, #stage.injected do
            local f = stage.injected[i]
            if f.kind == "motion" then motions = motions + 1
            elseif f.kind == "down" then down_at = f.t
            elseif f.kind == "lift" then lift_at = f.t end
        end
        print(string.format("   [drag] by the end: %d motion frame(s), lift injected %d ms after the down",
            motions, down_at and lift_at and time.to_ms(lift_at - down_at) or -1))
    end)
    stage.restore()
    if not ok then error(err, 0) end
end)

check("a_key_driven_repaint_reaches_a_client_within_a_poll_of_its_paint", function()
    local stage = live_repaint_stage()
    local ok, err = pcall(function()
        stage.hold_a_request()
        local paints_before = stage.stage.paints

        -- One key, through the wire (XK_Down, which this device maps to the key the widget listens
        -- for). Nothing follows it: no second event, no click, no local input.
        stage.client.sock:send(string.char(4, 1, 0, 0) .. string.char(0, 0, 0xff, 0x54))
        local nrects, rects = stage.take_frame(2)
        stage.snapshot()

        assert_true(stage.stage.keys == 1, "the widget must have been sent the key")
        assert_true(stage.stage.paints > paints_before,
            "the key's repaint must have been painted (" .. stage.describe("after the key") .. ")")

        local rx, ry = stage.rect.x + 4, stage.rect.y + 4
        local got_r, got_g, got_b = get(stage.plane, rx, ry)
        local want_r, want_g, want_b = get(stage.reference, rx, ry)
        assert_true(want_r == 255 and want_g == 255 and want_b == 255,
            "the key's repaint must have left the patch white ("
            .. stage.describe("after the key") .. ")")
        print(string.format("   [key] one key press, no further event: %d rectangle(s) %s,"
            .. " %d paint(s) of the widget", nrects, rect_list(rects),
            stage.stage.paints - paints_before))
        assert_true(got_r == want_r and got_g == want_g and got_b == want_b,
            string.format("the frame answering the key must carry the pixels of the repaint it caused:"
                .. " the client holds %d,%d,%d at %d,%d where the screen holds %d,%d,%d"
                .. " (the answer was encoded before the repaint was painted) (%s)",
                got_r, got_g, got_b, rx, ry, want_r, want_g, want_b,
                stage.describe("after the key")))
    end)
    stage.restore()
    if not ok then error(err, 0) end
end)

--- The same invariant with no client message anywhere: a key pressed on the *local* device, whose
--- handler takes longer than one poll interval (a page turn that has to render is the ordinary
--- case). By the time the loop reaches its next task pass the poll is due, so the poll runs *before*
--- the `UIManager:_repaint` that paints the widget - the state the reported bug loses the repaint
--- in, and the one that made it look as if keyboard input was never recorded at all.
check("a_local_key_repaint_reaches_a_client_within_a_poll_of_its_paint", function()
    local stage = live_repaint_stage()
    local ok, err = pcall(function()
        stage.stage.handler_delay = 0.02          -- longer than Server.POLL_INTERVAL
        stage.hold_a_request()
        local paints_before = stage.stage.paints

        -- No client message at all: a key on the device, delivered by the loop's own wait. The loop
        -- then needs one iteration to deliver it (its `waitEvent` runs after that iteration's
        -- `_repaint`), the next to paint the repaint it asked for - which is where the change is
        -- recorded - and the poll after that to answer the request with it: three iterations, two
        -- of them polls. Losing the repaint would need a further event and there is none.
        stage.queue_local_key()
        local nrects, rects = stage.take_frame(3)
        stage.snapshot()

        assert_true(stage.stage.keys == 1, "the widget must have been sent the local key")
        assert_true(stage.stage.paints > paints_before,
            "the local key's repaint must have been painted ("
            .. stage.describe("after the local key") .. ")")

        local rx, ry = stage.rect.x + 4, stage.rect.y + 4
        local got_r, got_g, got_b = get(stage.plane, rx, ry)
        local want_r, want_g, want_b = get(stage.reference, rx, ry)
        assert_true(want_r == 255 and want_g == 255 and want_b == 255,
            "the local key's repaint must have left the patch white ("
            .. stage.describe("after the local key") .. ")")
        print(string.format("   [local key] one key press, no client message: %d rectangle(s) %s,"
            .. " %d paint(s) of the widget", nrects, rect_list(rects),
            stage.stage.paints - paints_before))
        assert_true(got_r == want_r and got_g == want_g and got_b == want_b,
            string.format("the frame answering a local key must carry the pixels of the repaint it"
                .. " caused: the client holds %d,%d,%d at %d,%d where the screen holds %d,%d,%d"
                .. " (the answer was encoded before the repaint was painted) (%s)",
                got_r, got_g, got_b, rx, ry, want_r, want_g, want_b,
                stage.describe("after the local key")))
    end)
    stage.restore()
    if not ok then error(err, 0) end
end)

--- The half of the invariant that is not about one frame: the change must not be *lost*. Recording
--- a rectangle while the poll is running has to leave the client's request outstanding, so a later
--- poll answers it - if the generation accounting had moved past the change instead, the second key
--- would be answered with nothing at all, and a record encoded from stale pixels would leave the
--- client showing a colour the screen no longer holds. The patch flips colour on every press, so
--- each frame is checked against a different expected pixel.
check("a_second_key_repaint_reaches_a_client_too", function()
    local stage = live_repaint_stage()
    local ok, err = pcall(function()
        for press = 1, 2 do
            local what = "press " .. press
            stage.hold_a_request()
            local paints_before = stage.stage.paints
            stage.client.sock:send(string.char(4, 1, 0, 0) .. string.char(0, 0, 0xff, 0x54))
            local nrects = stage.take_frame(2)
            stage.snapshot()

            assert_true(stage.stage.keys == press,
                what .. ": the widget must have been sent " .. press .. " key(s) ("
                .. stage.describe(what) .. ")")
            assert_true(stage.stage.paints > paints_before,
                what .. ": the repaint must have been painted (" .. stage.describe(what) .. ")")

            local rx, ry = stage.rect.x + 4, stage.rect.y + 4
            local got_r, got_g, got_b = get(stage.plane, rx, ry)
            local want_r, want_g, want_b = get(stage.reference, rx, ry)
            print(string.format("   [press %d] %d rectangle(s): the patch is %d,%d,%d on the screen"
                .. " and %d,%d,%d at the client", press, nrects, want_r, want_g, want_b,
                got_r, got_g, got_b))
            assert_true(got_r == want_r and got_g == want_g and got_b == want_b,
                string.format("%s: the frame must carry the patch that press painted, not the one"
                    .. " before it: client %d,%d,%d vs screen %d,%d,%d (%s)", what,
                    got_r, got_g, got_b, want_r, want_g, want_b, stage.describe(what)))
        end
    end)
    stage.restore()
    if not ok then error(err, 0) end
end)

print(string.format("%d check(s), %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)

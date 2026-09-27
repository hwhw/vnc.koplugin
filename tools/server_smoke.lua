#!/usr/bin/env luajit
--[[--
Standalone test harness for the vncviewer **server** side: the pixel-format conversion and the
Raw/RRE/Hextile/ZRLE encoders in @{vncviewer.serverenc}.

Everything here is in-process: each encoding is produced by the server encoder and immediately
decoded by the (independently written) client decoders in @{vncviewer.encodings}, then compared
pixel by pixel against the plane that was encoded. That makes the server's wire format testable
without a server, a socket or a client - and it is the same contract the client side is tested
against a real RFB server.

Run with KOReader's own LuaJIT from the KOReader root:

  cd /usr/lib/koreader
  PLUGIN=~/.config/koreader/plugins/vncviewer.koplugin
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

local Encodings = require("vncviewer/encodings")
local Protocol = require("vncviewer/protocol")
local RfbServer = require("vncviewer/rfbserver")
local ServerEnc = require("vncviewer/serverenc")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local Util = require("vncviewer/util")

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
    local Server = require("vncviewer/server")
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

        local function pump_server(n)
            for _ = 1, n or 20 do
                server:_poll()                     -- services sockets and the coroutines
                socket.sleep(0.02)
            end
        end
        -- A small positive timeout: non-blocking sends on a fresh socket can be dropped
        -- silently, and expect() below treats "timeout" as "pump the server and retry".
        cli:settimeout(0.2)
        local function expect(n)
            local deadline = os.time() + 5
            local data, e
            while os.time() <= deadline do
                data, e = cli:receive(n)
                if data then return data end
                if e ~= "timeout" then break end
                server:_poll()
                socket.sleep(0.01)
            end
            assert_true(data ~= nil, string.format("short read of %d bytes: %s", n, tostring(e)))
            return data
        end

        pump_server(20)
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
        pump_server(4)
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
        pump_server(10)
        cli:send(string.char(3, 0) .. string.char(0, 0, 0, 0) ..       -- FramebufferUpdateRequest
            string.char(math.floor(sw / 256), sw % 256, math.floor(sh / 256), sh % 256))
        pump_server(20)

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

check("server_injects_client_input", function()
    -- A PointerEvent must become a KOReader gesture at the right position: that is what lets a
    -- remote VNC client tap, drag and long-press KOReader itself.
    local Server = require("vncviewer/server")
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
    end)
    UIManager.handleInputEvent = original
    if not ok then error(err, 0) end
end)

print(string.format("%d check(s), %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)

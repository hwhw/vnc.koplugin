#!/usr/bin/env luajit
--[[--
Standalone test harness for the vnc protocol layer.

Starts `tools/mock_vnc_server.py` (one instance per case, on an ephemeral port) and drives
@{vnc.protocol} against it over a real socket, plus a few in-memory byte-stream cases.

Run with KOReader's own LuaJIT from the KOReader root:

  cd /usr/lib/koreader
  PLUGIN=~/.config/koreader/plugins/vnc.koplugin
  LUA_PATH="$PLUGIN/?.lua;./common/?.lua;./common/?/init.lua;;" \
  LUA_CPATH="./common/?.so;;" \
  ./luajit "$PLUGIN/tools/proto_smoke.lua" --tmp /tmp/vncv_smoke
]]

-- KOReader environment: package.path for common/ + frontend/, and ffi.loadlib. The harness is
-- meant to be run from the KOReader root; fall back to adding the paths by hand.
if not pcall(dofile, "setupkoenv.lua") then
    package.path = "./common/?.lua;./frontend/?.lua;" .. package.path
    package.cpath = "./common/?.so;" .. package.cpath
    require("ffi/loadlib")
end

local bit = require("bit")
local ffi = require("ffi")
local socket = require("socket")

local BB = require("ffi/blitbuffer")

local Des = require("vnc/des")
local Encodings = require("vnc/encodings")
local Keysyms = require("vnc/keysyms")
local PxFmt = require("vnc/pxfmt")
local Protocol = require("vnc/protocol")

local bxor = bit.bxor

local TMP = "/tmp/vncv_smoke"
for _, a in ipairs(arg or {}) do
    local v = a:match("^%-%-tmp=(.+)$")
    if v then TMP = v end
end
local tools_dir = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local MOCK = tools_dir .. "/mock_vnc_server.py"

os.execute("mkdir -p " .. TMP)

-- ---------------------------------------------------------------- utilities

local function read_file(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local s = fh:read("*a")
    fh:close()
    return s
end

local function log_has(path, needle)
    local s = read_file(path)
    return s ~= nil and s:find(needle, 1, true) ~= nil
end

local function log_count(path, needle)
    local s = read_file(path)
    if not s then return 0 end
    local n, pos = 0, 1
    while true do
        local i = s:find(needle, pos, true)
        if not i then return n end
        n = n + 1
        pos = i + #needle
    end
end

local function wait_for_log(path, needle, timeout)
    local deadline = os.time() + (timeout or 5)
    repeat
        if log_has(path, needle) then return true end
        os.execute("sleep 0.05")
    until os.time() > deadline
    return false
end

local function free_port()
    local s = assert(socket.tcp())
    assert(s:bind("127.0.0.1", 0))
    local _, port = s:getsockname()
    s:close()
    return tonumber(port)
end

--[[--
Starts the mock server; returns its pid, the port and the log path.
]]
local function start_mock(opts)
    local port = free_port()
    local log = string.format("%s/%s.log", TMP, opts.name)
    os.remove(log)
    os.remove(log .. ".stdout")
    local cmd = {
        "python3", MOCK,
        "--port", tostring(port),
        "--encoding", opts.encoding,
        "--pattern", opts.pattern,
        "--width", tostring(opts.width or 200),
        "--height", tostring(opts.height or 150),
        "--log", log,
    }
    if opts.security then table.insert(cmd, "--security"); table.insert(cmd, opts.security) end
    if opts.password then table.insert(cmd, "--password"); table.insert(cmd, opts.password) end
    if opts.repaint then table.insert(cmd, "--repaint"); table.insert(cmd, tostring(opts.repaint)) end
    if opts.resize_after then table.insert(cmd, "--resize-after"); table.insert(cmd, tostring(opts.resize_after)) end
    table.insert(cmd, "--once")
    local full = table.concat(cmd, " ") .. " > " .. log .. ".stdout 2>&1 & echo $!"
    local h = assert(io.popen(full, "r"))
    local pid = (h:read("*l") or ""):gsub("%s", "")
    h:close()
    if not wait_for_log(log, "LISTENING", 10) then
        error(string.format("mock server did not start (pid %s, log %s): %s",
            pid, log, read_file(log .. ".stdout") or "(no output)"))
    end
    return pid, port, log
end

local function stop_mock(pid)
    if pid and pid ~= "" then
        os.execute("kill -9 " .. pid .. " 2>/dev/null")
    end
end

-- ---------------------------------------------------------------- synthetic framebuffer

local function pattern_pixel(pattern, x, y, fw, fh)
    if pattern == "gradient" then
        return x % 256, y % 256, bxor(x, y) % 256
    elseif pattern == "quadrants" then
        local left, top = x < math.floor(fw / 2), y < math.floor(fh / 2)
        if top then
            return left and 255 or 0, left and 0 or 255, 0
        end
        return left and 0 or 255, left and 0 or 255, left and 255 or 255
    elseif pattern == "checker" then
        local c = ((math.floor(x / 32) + math.floor(y / 32)) % 2 == 0) and 255 or 0
        return c, c, c
    end
    error("unknown pattern " .. tostring(pattern))
end

--- Compares the whole plane against `expect(x, y) -> r, g, b`.
local function check_plane(plane, fw, fh, expect)
    local base = ffi.cast("uint8_t*", plane.data)
    local stride = plane.stride
    for y = 0, fh - 1 do
        local row = base + y * stride
        for x = 0, fw - 1 do
            local er, eg, eb = expect(x, y)
            if er ~= nil then
                local p = row + x * 3
                if p[0] ~= er or p[1] ~= eg or p[2] ~= eb then
                    return nil, string.format("pixel (%d,%d) is (%d,%d,%d), expected (%d,%d,%d)",
                        x, y, p[0], p[1], p[2], er, eg, eb)
                end
            end
        end
    end
    return true
end

local function expect_pattern(pattern, fw, fh)
    return function(x, y) return pattern_pixel(pattern, x, y, fw, fh) end
end

-- ---------------------------------------------------------------- driver

--[[--
Drives @{vnc.protocol} against a real socket until `want_updates` updates have been
seen, or `body` signals a stop.

`o` fields: name, port, password, encodings, want_updates, body, stop_after_body,
on_connected, on_rect, on_resize, on_bell, on_cut_text, on_update, timeout.
]]
local function run_case(o)
    local sock = assert(socket.tcp())
    sock:settimeout(3)
    local ok, err = sock:connect("127.0.0.1", o.port)
    if not ok then return nil, "connect: " .. tostring(err), nil end
    sock:settimeout(3)
    sock:setoption("tcp-nodelay", true)

    local ctx = {
        updates = 0, rects = 0, resizes = {}, bells = 0, cuts = {},
        plane = nil, connected = false, body_run = false, stop = false,
        fw = nil, fh = nil, name = nil,
    }
    local tx = {}
    local function flush()
        if #tx == 0 then return true end
        local out = table.concat(tx, "", 1, #tx)
        for i = 1, #tx do tx[i] = nil end
        local i = 1
        while i <= #out do
            local last, serr = sock:send(out, i)
            if not last then return nil, "send: " .. tostring(serr) end
            i = last + 1
        end
        return true
    end

    local proto
    proto = Protocol.new{
        io = {
            write = function(s) tx[#tx + 1] = s end,
            read = function(n) return coroutine.yield("need", n) end,
        },
        host = "127.0.0.1",
        port = o.port,
        password = o.password,
        encodings = o.encodings,
        shared = true,
        get_plane = function() return ctx.plane end,
        callbacks = {
            on_connected = function(name, w, h)
                ctx.name, ctx.fw, ctx.fh = name, w, h
                ctx.connected = true
                if o.on_connected then return o.on_connected(ctx, name, w, h) end
            end,
            on_rect = function(x, y, w, h, enc)
                ctx.rects = ctx.rects + 1
                if o.on_rect then return o.on_rect(ctx, x, y, w, h, enc) end
            end,
            on_desktop_resize = function(w, h)
                ctx.fw, ctx.fh = w, h
                ctx.resizes[#ctx.resizes + 1] = { w = w, h = h }
                if o.on_resize then return o.on_resize(ctx, w, h, proto) end
            end,
            on_bell = function()
                ctx.bells = ctx.bells + 1
                if o.on_bell then return o.on_bell(ctx) end
            end,
            on_cut_text = function(text)
                ctx.cuts[#ctx.cuts + 1] = text
                if o.on_cut_text then return o.on_cut_text(ctx, text) end
            end,
            on_update_done = function()
                ctx.updates = ctx.updates + 1
                if o.on_update then
                    local oku, erru = o.on_update(ctx)
                    if erru ~= nil or oku == false then
                        return nil, erru or "on_update callback failed"
                    end
                end
                if o.want_updates and ctx.updates >= o.want_updates then ctx.stop = true end
            end,
        },
    }

    local data = nil
    while true do
        local a, b = proto:step(data)
        local fok, ferr = flush()
        if not fok then sock:close(); proto:free(); return nil, ferr, ctx end
        if a == "need" then
            if ctx.connected and not ctx.body_run then
                ctx.body_run = true
                if o.body then
                    local okb, errb = o.body(proto, ctx)
                    if errb ~= nil or okb == false then
                        sock:close(); proto:free()
                        return nil, errb or "body failed", ctx
                    end
                end
                local fok2, ferr2 = flush()
                if not fok2 then sock:close(); proto:free(); return nil, ferr2, ctx end
                if o.stop_after_body then ctx.stop = true end
            end
            if ctx.stop then break end
            local chunk, rerr = sock:receive(b)
            if not chunk then
                sock:close(); proto:free()
                return nil, string.format("receive(%d): %s", b, tostring(rerr)), ctx
            end
            data = chunk
        elseif a == "done" then
            break
        else
            sock:close()
            proto:free()
            return nil, tostring(b), ctx
        end
    end
    sock:close()
    proto:free()
    return true, nil, ctx
end

--- Drives the protocol against an in-memory byte string (no socket, no mock).
local function run_mem(bytes, o)
    o = o or {}
    local pos = 1
    local proto = Protocol.new{
        io = {
            write = function() end,
            read = function(n) return coroutine.yield("need", n) end,
        },
        host = "mem",
        port = 0,
        password = o.password,
        encodings = o.encodings or Encodings.ORDER_DEFAULT,
        get_plane = function() return o.plane end,
        callbacks = o.callbacks or {},
    }
    local data = nil
    for _ = 1, 1000 do
        local a, b = proto:step(data)
        if a == "need" then
            data = bytes:sub(pos, pos + b - 1)
            pos = pos + b
            if #data < b then
                proto:free()
                return nil, string.format("feed exhausted: wanted %d, had %d", b, #data)
            end
        elseif a == "done" then
            proto:free()
            return true
        else
            proto:free()
            return nil, tostring(b)
        end
    end
    proto:free()
    return nil, "protocol did not terminate"
end

-- ---------------------------------------------------------------- checks

local failures = 0
local function check(name, fn)
    local ok, res, err = pcall(fn)
    if ok and res then
        print("ok - " .. name)
    else
        failures = failures + 1
        if not ok then
            print(string.format("FAIL: %s: %s", name, tostring(res)))
        else
            print(string.format("FAIL: %s: %s", name, tostring(err)))
        end
    end
end

--- Runs one encoding end-to-end against the mock and compares every pixel.
local function encoding_case(name, encoding, pattern, expect, opts)
    opts = opts or {}
    local pid, port, log = start_mock{
        name = name, encoding = encoding, pattern = pattern,
        width = opts.width or 200, height = opts.height or 150,
        repaint = opts.repaint, resize_after = opts.resize_after,
    }
    local ok, err, ctx
    local ok2, err2 = pcall(function()
        ok, err, ctx = run_case{
            name = name, port = port,
            encodings = opts.encodings or Encodings.order(opts.enable_tight),
            want_updates = opts.want_updates or 1,
            on_connected = function(c, _, w, h)
                c.plane = BB.new(w, h, BB.TYPE_BBRGB24)
            end,
            on_resize = opts.on_resize,
            on_update = opts.on_update,
            body = function(proto, c)
                proto:request_update(0, 0, 0, c.fw, c.fh)
                if opts.after_request then opts.after_request(proto, c) end
                return true
            end,
        }
    end)
    stop_mock(pid)
    if not ok2 then return nil, err2 end
    if not ok then return nil, err end
    if opts.verify_log then
        local vok, verr = opts.verify_log(log, ctx)
        if not vok then return nil, verr end
    end
    if opts.check ~= false then
        local cok, cerr = check_plane(ctx.plane, ctx.fw, ctx.fh, expect(pattern, ctx.fw, ctx.fh))
        if not cok then
            return nil, string.format("%s: %s", encoding, cerr)
        end
    end
    if opts.post then return opts.post(ctx, log) end
    return true
end

local function main()
    -- 1. DES against FIPS/NIST vectors (independent of the mock).
    check("des_vectors", function()
        local function hex2s(h)
            local t = {}
            for i = 1, #h, 2 do t[#t + 1] = string.char(tonumber(h:sub(i, i + 1), 16)) end
            return table.concat(t)
        end
        local function s2hex(s)
            return (s:gsub(".", function(c) return string.format("%02X", c:byte()) end))
        end
        local cases = {
            { "0101010101010101", "8000000000000000", "95F8A5E5DD31D900" },
            { "133457799BBCDFF1", "0123456789ABCDEF", "85E813540F0AB405" },
            { "0101010101010101", "0000000000000000", "8CA64DE9C1B123A7" },
            { "0E329232EA6D0D73", "8787878787878787", "0000000000000000" },
            { "FFFFFFFFFFFFFFFF", "FFFFFFFFFFFFFFFF", "7359B2163E4EDC58" },
        }
        for _, c in ipairs(cases) do
            local got = s2hex(Des.ecb_encrypt_block(hex2s(c[1]), hex2s(c[2])))
            if got ~= c[3] then
                return nil, string.format("DES(%s,%s)=%s want %s", c[1], c[2], got, c[3])
            end
        end
        return true
    end)

    -- 2. VNC Authentication bit reversal.
    check("bit_reverse", function()
        if Des.reverse_bits(0x01) ~= 0x80 then return nil, "reverse_bits(0x01) ~= 0x80" end
        if Des.reverse_bits(0xA5) ~= 0xA5 then return nil, "reverse_bits(0xA5) ~= 0xA5" end
        if Des.reverse_bits(0x00) ~= 0x00 then return nil, "reverse_bits(0x00) ~= 0" end
        return true
    end)

    -- 3. The pixel format we send must hit the wire in the documented byte order, and the
    --    encoding list must be the documented negotiation order.
    check("pxfmt_wire", function()
        local pid, port, log = start_mock{ name = "pxfmt", encoding = "raw", pattern = "gradient" }
        local ok, err = pcall(function()
            local r, e = run_case{
                port = port, want_updates = 1,
                on_connected = function(c, _, w, h) c.plane = BB.new(w, h, BB.TYPE_BBRGB24) end,
                body = function(proto, c) proto:request_update(0, 0, 0, c.fw, c.fh) end,
            }
            if not r then error(e) end
        end)
        stop_mock(pid)
        if not ok then return nil, err end
        if not wait_for_log(log, "INPUT SetPixelFormat bpp=32 red_shift=0 green_shift=8 blue_shift=16", 5) then
            return nil, "pixel format was not reported as bpp=32/LSB/shift 0,8,16:\n" .. (read_file(log) or "")
        end
        if not log_has(log, "INPUT SetEncodings 16,15,5,1,2,0,-223") then
            return nil, "SetEncodings order mismatch:\n" .. (read_file(log) or "")
        end
        return true
    end)

    -- 4. Security negotiation.
    check("handshake_none", function()
        local pid, port, log = start_mock{ name = "auth_none", encoding = "raw", pattern = "gradient", security = "none" }
        local ok, err = pcall(function()
            local r, e = run_case{
                port = port, want_updates = 1,
                on_connected = function(c, _, w, h) c.plane = BB.new(w, h, BB.TYPE_BBRGB24) end,
                body = function(proto, c) proto:request_update(0, 0, 0, c.fw, c.fh) end,
            }
            if not r then error(e) end
        end)
        stop_mock(pid)
        if not ok then return nil, err end
        if not wait_for_log(log, "AUTH ok", 5) then return nil, "no AUTH ok in mock log" end
        return true
    end)

    check("handshake_vnc", function()
        local pid, port, log = start_mock{
            name = "auth_vnc", encoding = "raw", pattern = "gradient",
            security = "vnc", password = "s3cret",
        }
        local ok, err = pcall(function()
            local r, e = run_case{
                port = port, password = "s3cret", want_updates = 1,
                on_connected = function(c, _, w, h) c.plane = BB.new(w, h, BB.TYPE_BBRGB24) end,
                body = function(proto, c) proto:request_update(0, 0, 0, c.fw, c.fh) end,
            }
            if not r then error(e) end
        end)
        stop_mock(pid)
        if not ok then return nil, err end
        if not wait_for_log(log, "AUTH ok", 5) then
            return nil, "VNC authentication was rejected (our DES does not match OpenSSL):\n" .. (read_file(log) or "")
        end
        return true
    end)

    check("handshake_vnc_wrong_password", function()
        local pid, port, log = start_mock{
            name = "auth_bad", encoding = "raw", pattern = "gradient",
            security = "vnc", password = "s3cret",
        }
        local ok, err = run_case{
            port = port, password = "wrong", want_updates = 1,
            on_connected = function(c, _, w, h) c.plane = BB.new(w, h, BB.TYPE_BBRGB24) end,
            body = function(proto, c) proto:request_update(0, 0, 0, c.fw, c.fh) end,
        }
        stop_mock(pid)
        if ok then return nil, "wrong password was accepted" end
        if not tostring(err):find("Authentication failure", 1, true) then
            return nil, "error does not mention the server's reason: " .. tostring(err)
        end
        return true
    end)

    -- 5. Every encoding, pixel exact against the synthetic pattern.
    check("encodings_raw", function()
        return encoding_case("enc_raw", "raw", "gradient", expect_pattern)
    end)

    check("encodings_rre", function()
        return encoding_case("enc_rre", "rre", "gradient", expect_pattern)
    end)

    check("encodings_hextile", function()
        return encoding_case("enc_hextile", "hextile", "gradient", expect_pattern)
    end)

    check("encodings_hextile_quads", function()
        -- The quadrants pattern makes the Hextile background/foreground carry paths and the
        -- one-colour-per-tile cases fire as well.
        return encoding_case("enc_hextile_quads", "hextile", "quadrants", expect_pattern)
    end)

    check("encodings_trle", function()
        return encoding_case("enc_trle", "trle", "gradient", expect_pattern)
    end)

    check("encodings_trle_palette", function()
        -- 4 colours: exercises solid tiles, packed palettes (1/2/4 bit), palette reuse
        -- (127/129) and palette RLE (130+).
        return encoding_case("enc_trle_pal", "trle", "quadrants", expect_pattern)
    end)

    check("encodings_zrle", function()
        return encoding_case("enc_zrle", "zrle", "gradient", expect_pattern)
    end)

    check("encodings_zrle_palette", function()
        return encoding_case("enc_zrle_pal", "zrle", "quadrants", expect_pattern)
    end)

    check("encodings_copyrect", function()
        -- The mock fills the left part as Raw, then CopyRect-shifts it right by 64 pixels
        -- with an overlapping source. Expected image: pattern(x, y) for x < 64, else
        -- pattern(x - 64, y).
        local function expect(pat, fw, fh)
            return function(x, y)
                if x < 64 then return pattern_pixel(pat, x, y, fw, fh) end
                return pattern_pixel(pat, x - 64, y, fw, fh)
            end
        end
        return encoding_case("enc_copyrect", "copyrect", "gradient", expect)
    end)

    check("encodings_tight", function()
        local jx, jy, jw, jh = 8, 8, 32, 32
        local jr, jg, jb = 199, 40, 120
        local function expect(pat, fw, fh)
            return function(x, y)
                if x >= jx and x < jx + jw and y >= jy and y < jy + jh then return nil end
                return pattern_pixel(pat, x, y, fw, fh)
            end
        end
        return encoding_case("enc_tight", "tight", "gradient", expect, {
            enable_tight = true,
            post = function(ctx)
                -- The JPEG rect is lossy: check it only loosely.
                local base = ffi.cast("uint8_t*", ctx.plane.data)
                for y = jy, jy + jh - 1 do
                    for x = jx, jx + jw - 1 do
                        local p = base + y * ctx.plane.stride + x * 3
                        if math.abs(p[0] - jr) > 8 or math.abs(p[1] - jg) > 8 or math.abs(p[2] - jb) > 8 then
                            return nil, string.format(
                                "JPEG rect pixel (%d,%d) is (%d,%d,%d), expected ~(%d,%d,%d)",
                                x, y, p[0], p[1], p[2], jr, jg, jb)
                        end
                    end
                end
                return true
            end,
        })
    end)

    check("encodings_tight_quads", function()
        -- Quadrants: triggers the Tight fill subencoding and the 1-bit palette path.
        return encoding_case("enc_tight_quads", "tight", "quadrants", expect_pattern, {
            enable_tight = true,
            check = false,
            post = function(ctx)
                -- The JPEG rect is overwritten last, so just check that the JPEG rect matches
                -- loosely and everything else matches exactly.
                local base = ffi.cast("uint8_t*", ctx.plane.data)
                for y = 0, ctx.fh - 1 do
                    for x = 0, ctx.fw - 1 do
                        local p = base + y * ctx.plane.stride + x * 3
                        if x >= 8 and x < 40 and y >= 8 and y < 40 then
                            if math.abs(p[0] - 199) > 8 or math.abs(p[1] - 40) > 8 or math.abs(p[2] - 120) > 8 then
                                return nil, string.format("JPEG rect pixel (%d,%d) is (%d,%d,%d)", x, y, p[0], p[1], p[2])
                            end
                        else
                            local er, eg, eb = pattern_pixel("quadrants", x, y, ctx.fw, ctx.fh)
                            if p[0] ~= er or p[1] ~= eg or p[2] ~= eb then
                                return nil, string.format("pixel (%d,%d) is (%d,%d,%d), expected (%d,%d,%d)",
                                    x, y, p[0], p[1], p[2], er, eg, eb)
                            end
                        end
                    end
                end
                return true
            end,
        })
    end)

    check("encodings_mixed", function()
        return encoding_case("enc_mixed", "mixed", "gradient", expect_pattern)
    end)

    -- 6. ZRLE stream continuity: many successive rectangles through one zlib stream.
    check("zrle_stream_continuity", function()
        local pattern = "gradient"
        local ok, err = encoding_case("zrle_cont", "zrle", pattern, expect_pattern, {
            width = 160, height = 120, repaint = 0.05, want_updates = 6,
            -- Validate every intermediate state, not just the last one: each update must
            -- leave the whole plane equal to the pattern (the mock repaints correct pixels).
            on_update = function(ctx)
                return check_plane(ctx.plane, ctx.fw, ctx.fh, expect_pattern(pattern, ctx.fw, ctx.fh))
            end,
            post = function(ctx)
                if ctx.updates < 6 then
                    return nil, string.format("only %d updates seen, wanted >= 6", ctx.updates)
                end
                if ctx.rects < 6 then
                    return nil, string.format("only %d rects decoded, wanted >= 6", ctx.rects)
                end
                return true
            end,
        })
        return ok, err
    end)

    -- 7. DesktopSize: the plane is reallocated and a non-incremental request follows.
    check("desktop_resize", function()
        local nw, nh = 200 + 32, 150 + 16
        local ok, err = encoding_case("resize", "raw", "gradient", expect_pattern, {
            resize_after = 1, want_updates = 2,
            on_resize = function(ctx, w, h, proto)
                -- What the session will do: reallocate the plane and resynchronise with a
                -- non-incremental request for the whole new area.
                if ctx.plane then ctx.plane:free() end
                ctx.plane = BB.new(w, h, BB.TYPE_BBRGB24)
                proto:request_update(0, 0, 0, w, h)
            end,
            after_request = nil,
            post = function(ctx, log)
                if #ctx.resizes ~= 1 or ctx.resizes[1].w ~= nw or ctx.resizes[1].h ~= nh then
                    local parts = {}
                    for _, r in ipairs(ctx.resizes) do
                        parts[#parts + 1] = string.format("%dx%d", r.w, r.h)
                    end
                    return nil, string.format("resize callbacks: [%s]", table.concat(parts, ", "))
                end
                local needle = string.format("INPUT FramebufferUpdateRequest incremental=0 x=0 y=0 w=%d h=%d", nw, nh)
                if not wait_for_log(log, needle, 5) then
                    return nil, "no non-incremental full request for the new size (" .. needle .. ")"
                end
                return true
            end,
        })
        return ok, err
    end)

    -- 8. Client input messages reach the server byte-for-byte.
    check("input_messages", function()
        local pid, port, log = start_mock{ name = "input", encoding = "raw", pattern = "gradient" }
        local ok, err = run_case{
            port = port, want_updates = 0, stop_after_body = true,
            on_connected = function(c, _, w, h) c.plane = BB.new(w, h, BB.TYPE_BBRGB24) end,
            body = function(proto)
                proto:send_pointer(300, 200, 1)
                proto:send_key(Keysyms.special.Press, true)
                proto:send_key(Keysyms.special.Press, false)
                -- URI/Dispatcher callers hand us strings: "0" must be a release, not a press
                proto:send_key(Keysyms.special.Press, "1")
                proto:send_key(Keysyms.special.Press, "0")
                proto:send_key(Keysyms.special.Press, 0)
                proto:send_cut_text("hello")
                return true
            end,
        }
        if not ok then stop_mock(pid); return nil, err end
        local want = {
            "INPUT PointerEvent mask=1 x=300 y=200",
            "INPUT KeyEvent down=1 keysym=0xff0d",
            "INPUT KeyEvent down=0 keysym=0xff0d",
            "INPUT ClientCutText len=5",
        }
        for _, needle in ipairs(want) do
            if not wait_for_log(log, needle, 5) then
                stop_mock(pid)
                return nil, "missing log line " .. needle .. "\n" .. (read_file(log) or "")
            end
        end
        stop_mock(pid)
        -- down: true, "1"; up: false, "0", 0
        local downs = log_count(log, "INPUT KeyEvent down=1 keysym=0xff0d")
        local ups = log_count(log, "INPUT KeyEvent down=0 keysym=0xff0d")
        if downs ~= 2 or ups ~= 3 then
            return nil, string.format(
                "key press/release counts: %d down, %d up (wanted 2/3); '0' must not mean down",
                downs, ups)
        end
        return true
    end)

    -- 9. A rectangle with an encoding we never advertised is fatal, with the encoding number.
    check("unsupported_encoding", function()
        local w = require("vnc/util").writer()
        w:raw("RFB 003.008\n")
        w:u8(1); w:u8(1)                          -- one security type: None
        w:u32(0)                                  -- SecurityResult: OK
        w:u16(8); w:u16(8)                        -- ServerInit
        local pf = PxFmt.PIXEL_FORMAT
        w:u8(pf.bits_per_pixel); w:u8(pf.depth); w:u8(pf.big_endian); w:u8(pf.true_colour)
        w:u16(pf.red_max); w:u16(pf.green_max); w:u16(pf.blue_max)
        w:u8(pf.red_shift); w:u8(pf.green_shift); w:u8(pf.blue_shift)
        w:u8(0); w:u8(0); w:u8(0)
        w:u32(0)
        w:u8(0); w:u8(0); w:u16(1)                -- FramebufferUpdate, 1 rect
        w:u16(0); w:u16(0); w:u16(4); w:u16(4); w:u32(6) -- encoding 6
        local plane = BB.new(8, 8, BB.TYPE_BBRGB24)
        local ok, err = run_mem(w:tostring(), {
            plane = plane,
            callbacks = { on_connected = function() end },
        })
        plane:free()
        if ok then return nil, "encoding 6 was accepted" end
        if err ~= "unsupported encoding 6" then
            return nil, "error was " .. tostring(err) .. ", wanted \"unsupported encoding 6\""
        end
        return true
    end)

    if failures > 0 then
        print(string.format("%d check(s) failed", failures))
        os.exit(1)
    end
    print("all checks passed")
    os.exit(0)
end

main()

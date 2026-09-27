--[[--
RFB 3.8 client state machine (with 3.7/3.3 compatibility), transport agnostic.

The whole protocol runs as a coroutine body. It never touches a socket: whenever it needs
bytes it calls the transport's `read(n)`, which `coroutine.yield`s `("need", n)` out of
@{Protocol:step}. The driver reads however many poll ticks it takes to gather exactly `n`
bytes and resumes the coroutine with them. Outgoing messages are handed to `io.write(s)`
and flushed by the driver.

Normative reference: RFC 6143 (sections 7.1-7.7 and Appendix A).

@module vncviewer.protocol
]]

local Des = require("vncviewer/des")
local Encodings = require("vncviewer/encodings")
local PxFmt = require("vncviewer/pxfmt")
local Util = require("vncviewer/util")
local logger = require("logger")

local Protocol = {}
Protocol.__index = Protocol

--[[--
Creates a client.
--- @tparam table opts
--- @tparam table opts.io transport: `read(n)` -> exactly n bytes (may coroutine.yield), `write(s)`
--- @tparam string opts.host
--- @tparam number opts.port
--- @tparam[opt=true] boolean opts.shared ClientInit shared-flag
--- @tparam[opt=nil] string opts.password empty/nil disables VNC Authentication
--- @tparam[opt] table opts.encodings encoding list for SetEncodings
--- @tparam[opt] function opts.get_plane -> the current remote plane BlitBuffer
--- @tparam[opt] table opts.callbacks on_connected|on_rect|on_desktop_resize|on_bell|on_cut_text
--- @treturn Protocol
]]
function Protocol.new(opts)
    assert(type(opts) == "table" and opts.io, "Protocol.new: opts.io is required")
    local self = setmetatable({
        io = opts.io,
        host = opts.host,
        port = opts.port,
        shared = opts.shared ~= false,
        password = opts.password,
        encodings = opts.encodings or Encodings.ORDER_DEFAULT,
        callbacks = opts.callbacks or {},
        get_plane = opts.get_plane,
        streams = Encodings.new_streams(),
        width = nil,
        height = nil,
        version = nil,
        server_name = nil,
        server_pixel_format = nil,
    }, Protocol)
    self.reader = Util.reader({
        read = function(n)
            return coroutine.yield("need", n)
        end,
    })
    self.co = coroutine.create(function() return self:run() end)
    return self
end

--- Calls the callback `name` when it is registered.
function Protocol:_fire(name, ...)
    local cb = self.callbacks[name]
    if cb then return cb(...) end
end

--[[--
Resumes the protocol.

Pass the bytes requested by a previous `("need", n)` result.
--- @treturn string|nil, number|nil `"need"` plus a byte count, `"done"`, or nil plus an error
]]
function Protocol:step(data)
    local ok, a, b = coroutine.resume(self.co, data)
    if not ok then return nil, a end
    return a, b
end

--- The coroutine body. Do not call directly; drive it with @{Protocol:step}.
function Protocol:run()
    self:_handshake()
    self:_set_pixel_format()
    self:_set_encodings()
    self:_message_loop()
    return "done"
end

function Protocol:_handshake()
    local r = self.reader

    local version = r:bytes(12)
    local major, minor = version:match("RFB (%d+)%.(%d+)")
    if not major then
        error(string.format("bad ProtocolVersion %q from %s:%d", version, self.host, self.port), 0)
    end
    major, minor = tonumber(major), tonumber(minor)
    if major == 3 and minor >= 8 then
        self.version = 38
        self.io.write("RFB 003.008\n")
    elseif major == 3 and minor == 7 then
        self.version = 37
        self.io.write("RFB 003.007\n")
    else
        self.version = 33
        self.io.write("RFB 003.003\n")
    end

    -- Security type negotiation.
    local sec_type
    if self.version == 33 then
        sec_type = r:u32()
        if sec_type == 0 then
            local len = r:u32()
            error(string.format("server refused connection: %s", r:bytes(len)), 0)
        end
        if sec_type ~= 1 and sec_type ~= 2 then
            error(string.format("unsupported security type %d", sec_type), 0)
        end
    else
        local count = r:u8()
        if count == 0 then
            local len = r:u32()
            error(string.format("server refused connection: %s", r:bytes(len)), 0)
        end
        local offered = {}
        for i = 1, count do offered[i] = r:u8() end
        if self.password and #self.password > 0 then
            for _, t in ipairs(offered) do
                if t == 2 then sec_type = 2 break end
            end
        end
        if not sec_type then
            for _, t in ipairs(offered) do
                if t == 1 then sec_type = 1 break end
            end
        end
        if not sec_type then
            self.io.write(string.char(0))
            error(string.format("server offers no supported security type (offered: %s)",
                table.concat(offered, ", ")), 0)
        end
        self.io.write(string.char(sec_type))
    end

    -- Security type specific exchange.
    if sec_type == 2 then
        if not (self.password and #self.password > 0) then
            error("server requires VNC Authentication but no password is configured", 0)
        end
        local challenge = r:bytes(16)
        local key = {}
        for i = 1, 8 do
            key[i] = string.char(Des.reverse_bits(self.password:byte(i) or 0))
        end
        key = table.concat(key)
        self.io.write(Des.ecb_encrypt_block(key, challenge:sub(1, 8)) ..
                      Des.ecb_encrypt_block(key, challenge:sub(9, 16)))
    end

    -- SecurityResult is only sent for RFB 3.8, and for VNC Authentication in 3.7/3.3
    -- (RFC 6143 §7.1.3 and Appendix A.1/A.2).
    if self.version >= 38 or sec_type == 2 then
        local status = r:u32()
        if status ~= 0 then
            local reason = ""
            if self.version >= 38 then
                local len = r:u32()
                reason = r:bytes(len)
            end
            local what = sec_type == 2 and "VNC authentication failed" or "security handshake failed"
            error(reason ~= "" and (what .. ": " .. reason) or what, 0)
        end
    end

    -- Initialization.
    self.io.write(string.char(self.shared and 1 or 0))
    self.width = r:u16()
    self.height = r:u16()
    self.server_pixel_format = r:bytes(16)
    local name_len = r:u32()
    self.server_name = r:bytes(name_len)
    self:_fire("on_connected", self.server_name, self.width, self.height)
end

function Protocol:_set_pixel_format()
    local w = Util.writer()
    local pf = PxFmt.PIXEL_FORMAT
    w:u8(0); w:u8(0); w:u8(0); w:u8(0) -- message-type + padding
    w:u8(pf.bits_per_pixel); w:u8(pf.depth); w:u8(pf.big_endian); w:u8(pf.true_colour)
    w:u16(pf.red_max); w:u16(pf.green_max); w:u16(pf.blue_max)
    w:u8(pf.red_shift); w:u8(pf.green_shift); w:u8(pf.blue_shift)
    w:u8(0); w:u8(0); w:u8(0)
    self.io.write(w:tostring())
end

function Protocol:_set_encodings()
    local w = Util.writer()
    w:u8(2); w:u8(0); w:u16(#self.encodings)
    for _, e in ipairs(self.encodings) do
        w:u32(e % 4294967296)
    end
    self.io.write(w:tostring())
end

function Protocol:_message_loop()
    local r = self.reader
    while true do
        local t = r:u8()
        if t == 0 then -- FramebufferUpdate
            r:u8() -- padding
            local nrects = r:u16()
            for _ = 1, nrects do
                self:_rect(r)
            end
            self:_fire("on_update_done")
            -- Exactly one outstanding request at all times; this is what bounds memory
            -- while the app is detached (the loop is simply not resumed).
            self:request_update(1, 0, 0, self.width, self.height)
        elseif t == 1 then -- SetColorMapEntries (never sent for true-colour clients)
            r:u8()
            local first, count = r:u16(), r:u16()
            r:bytes(count * 6)
            logger.dbg("vncviewer: ignoring SetColorMapEntries", first, count)
        elseif t == 2 then -- Bell
            self:_fire("on_bell")
        elseif t == 3 then -- ServerCutText
            r:bytes(3)
            local len = r:u32()
            local text = r:bytes(len)
            self:_fire("on_cut_text", text)
        else
            error(string.format("unknown server message %d", t), 0)
        end
    end
end

function Protocol:_rect(r)
    local x, y = r:u16(), r:u16()
    local w, h = r:u16(), r:u16()
    local enc = r:s32()

    if enc == Encodings.DESKTOP_SIZE then
        self.width, self.height = w, h
        self:_fire("on_desktop_resize", w, h)
        return
    end

    if not Encodings.SUPPORTED[enc] then
        error(string.format("unsupported encoding %d", enc), 0)
    end

    local plane = self.get_plane and self.get_plane()
    if not plane then
        error("no remote plane available to decode into", 0)
    end
    if x + w > plane.w or y + h > plane.h then
        error(string.format("rect (%d,%d %dx%d) does not fit %dx%d framebuffer",
            x, y, w, h, plane.w, plane.h), 0)
    end

    local ok, err = Encodings.decode({
        x = x, y = y, w = w, h = h, encoding = enc,
        r = r, plane = plane, vp = plane:viewport(x, y, w, h),
        streams = self.streams,
    })
    if not ok then
        error(string.format("%s (rect (%d,%d %dx%d))", err, x, y, w, h), 0)
    end
    self:_fire("on_rect", x, y, w, h, enc)
end

--- Sends a FramebufferUpdateRequest (type 3).
function Protocol:request_update(incremental, x, y, w, h)
    local wr = Util.writer()
    wr:u8(3)
    wr:u8(Util.bool_to_bit(incremental))
    wr:u16(x); wr:u16(y); wr:u16(w); wr:u16(h)
    self.io.write(wr:tostring())
end

--- Sends a PointerEvent (type 5). `mask` bit 0 = left, 1 = middle, 2 = right, 3/4 = wheel up/down.
function Protocol:send_pointer(x, y, mask)
    local wr = Util.writer()
    wr:u8(5)
    wr:u8(tonumber(mask) or 0)
    wr:u16(x); wr:u16(y)
    self.io.write(wr:tostring())
end

--- Sends a KeyEvent (type 4).
function Protocol:send_key(keysym, down)
    local wr = Util.writer()
    wr:u8(4)
    wr:u8(Util.bool_to_bit(down))
    wr:u8(0); wr:u8(0)
    wr:u32(keysym % 4294967296)
    self.io.write(wr:tostring())
end

--- Sends a ClientCutText (type 6).
function Protocol:send_cut_text(text)
    local wr = Util.writer()
    wr:u8(6)
    wr:u8(0); wr:u8(0); wr:u8(0)
    wr:u32(#text)
    wr:raw(text)
    self.io.write(wr:tostring())
end

--- @treturn number, number framebuffer size as last reported by ServerInit/DesktopSize
function Protocol:get_framebuffer_size()
    return self.width, self.height
end

--- Releases the per-connection decoder state.
function Protocol:free()
    Encodings.free_streams(self.streams)
    self.streams = nil
end

return Protocol

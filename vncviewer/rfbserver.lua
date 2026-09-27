--[[--
RFB 3.8 server state machine, transport agnostic.

The mirror image of @{vncviewer.protocol}: it never touches a socket, runs as a coroutine body and
yields whenever it wants bytes - `("need", n)` for input, which the driver satisfies across however
many poll ticks it takes - and hands its outgoing messages to `io.write(s)` for the driver to
flush.

One extra yield exists on this side: a client may ask for an incremental update while nothing has
changed. Instead of answering with an empty update (which would make the client ask again at once,
i.e. busy-loop between two processes), the coroutine yields `("idle")` and the driver resumes it
once the screen has actually changed - which is what a real RFB server does.

Normative reference: RFC 6143 (sections 7.1-7.7 and Appendix A).

@module vncviewer.rfbserver
]]

local Des = require("vncviewer/des")
local Util = require("vncviewer/util")
local logger = require("logger")

local Server = {}
Server.__index = Server

Server.VERSION_STRING = "RFB 003.008\n"

Server.SEC_NONE = 1
Server.SEC_VNC_AUTH = 2

--- Encodings we can produce (see @{vncviewer.serverenc}). Anything else the client announces is
--- ignored, and such a client falls back to Raw, which every client must support.
Server.SUPPORTED_ENCODINGS = {
    [0] = true,   -- Raw
    [2] = true,   -- RRE
    [5] = true,   -- Hextile
    [16] = true,  -- ZRLE
}

Server.PSEUDO_DESKTOP_SIZE = -223
Server.PSEUDO_LAST_RECT = -224

--[[--
Creates the server side of one client connection.

--- @tparam table opts
--- @tparam table opts.io transport: `read(n)` (may coroutine.yield `("need", n)`) and `write(s)`
--- @tparam[opt=""] string opts.password non-empty requires VNC Authentication; empty offers the
---   "None" security type, i.e. no authentication at all
--- @tparam[opt] string opts.name desktop name for ServerInit
--- @tparam function opts.get_size -> width, height of the screen being served
--- @tparam function opts.get_rects `(client, region, full)` -> array of `{x, y, w, h}` for the next
---   update (may be empty; `full` marks a non-incremental request, which must be answered)
--- @tparam function opts.encode `(client, rect)` -> encoding, payload: one rectangle encoded for
---   that client's pixel format and encoding
--- @tparam[opt] function opts.get_colour_map -> 256 `{r, g, b}` entries, needed when a client asks
---   for a non-true-colour format (otherwise such a format is refused)
--- @tparam[opt] function opts.on_pointer `(x, y, mask, client)`
--- @tparam[opt] function opts.on_key `(keysym, down, client)`
--- @tparam[opt] function opts.on_cut_text `(text, client)`
--- @tparam[opt] function opts.on_ready `(client)` - handshake done, updates may be sent
--- @treturn Server
]]
function Server.new(opts)
    assert(type(opts) == "table" and opts.io, "Server.new: opts.io is required")
    local self = setmetatable({
        io = opts.io,
        password = opts.password or "",
        name = opts.name or "KOReader",
        get_size = opts.get_size,
        get_rects = opts.get_rects,
        encode = opts.encode,
        get_colour_map = opts.get_colour_map,
        on_pointer = opts.on_pointer,
        on_key = opts.on_key,
        on_cut_text = opts.on_cut_text,
        on_ready = opts.on_ready,
        version = nil,
        --- State of this connection, read by the encoders and the driver.
        client = {
            shared = false,
            pixel_format = nil,        -- nil until the client sends SetPixelFormat
            encodings = { 0 },         -- in the client's own preference order
            desktop_size_supported = false,
            last_rect_supported = false,
            pointer_x = 0,
            pointer_y = 0,
            buttons = 0,
        },
    }, Server)
    self.reader = Util.reader({
        read = function(n) return coroutine.yield("need", n) end,
    })
    self.co = coroutine.create(function() return self:run() end)
    return self
end

--- Resumes the state machine with `data` (the bytes of the last `("need", n)` request).
--- @treturn string|nil "need" | "done" | nil, number|string
function Server:step(data)
    local ok, a, b = coroutine.resume(self.co, data)
    if not ok then return nil, a end
    return a, b
end

function Server:_write(s)
    self.io.write(s)
end

--- Runs the handshake and then the message loop (the coroutine body).
function Server:run()
    self:_handshake()
    if self.on_ready then self.on_ready(self.client) end
    self:_message_loop()
    return "done"
end

-- ---------------------------------------------------------------- handshake

local function random_bytes(n)
    local f = io.open("/dev/urandom", "rb")
    if f then
        local s = f:read(n)
        f:close()
        if s and #s == n then return s end
    end
    -- Fallback for platforms without /dev/urandom: only the challenge becomes predictable, which
    -- is a limitation of VNC Authentication itself anyway.
    math.randomseed(os.time())
    local t = {}
    for i = 1, n do t[i] = string.char(math.random(0, 255)) end
    return table.concat(t)
end

--- The DES key VNC Authentication uses: password truncated/padded to 8 bytes, bits reversed in
--- every byte (the same construction the client side uses).
function Server:_auth_key()
    local key = {}
    for i = 1, 8 do
        key[i] = string.char(Des.reverse_bits(self.password:byte(i) or 0))
    end
    return table.concat(key)
end

function Server:_server_init_pixel_format(out)
    -- What a client sees before it sends SetPixelFormat (a conforming client sends it right
    -- away): 32 bpp true colour, RGB in the low address bytes - the layout this plugin's client
    -- side asks for, so both halves agree by default.
    out:u8(32):u8(24):u8(0):u8(1)
    out:u16(255):u16(255):u16(255)
    out:u8(0):u8(8):u8(16)
    out:raw("\0\0\0")
end

function Server:_handshake()
    local r = self.reader
    self:_write(Server.VERSION_STRING)

    local version = r:bytes(12)
    local major, minor = version:match("^RFB (%d%d%d)%.(%d%d%d)\n$")
    if not major then
        error("malformed version string from client: " .. string.format("%q", version), 0)
    end
    self.version = tonumber(major) * 1000 + tonumber(minor)
    if self.version < 3007 then
        -- 3.3 and older: the server dictates the security type, there is no list.
        self.version = 3003
    end

    local wanted = (self.password ~= "") and Server.SEC_VNC_AUTH or Server.SEC_NONE
    if self.version >= 3007 then
        self:_write(string.char(1, wanted))
        -- ... and the client answers with the type it picked, which must be the one we offered.
        local chosen = r:u8()
        if chosen ~= wanted then
            error(string.format("client chose security type %d, only %d was offered", chosen, wanted), 0)
        end
    else
        self:_write(Util.writer():u32(wanted):tostring())
    end

    if wanted == Server.SEC_VNC_AUTH then
        if not self:_vnc_auth() then
            error("VNC authentication failed", 0)
        end
    elseif self.version >= 3008 then
        -- RFC 6143 §7.1.2: the "None" security type still gets a SecurityResult from 3.8 on.
        -- (The client side of this plugin reads it under exactly the same condition.)
        self:_write(Util.writer():u32(0):tostring())
    end

    self.client.shared = r:u8() ~= 0

    local w, h = self.get_size()
    local init = Util.writer()
    init:u16(w):u16(h)
    self:_server_init_pixel_format(init)
    init:u32(#self.name):raw(self.name)
    self:_write(init:tostring())
end

--- Sends the challenge and checks the response. Returns true, or false (after having sent the
--- SecurityResult the client expects).
function Server:_vnc_auth()
    local challenge = random_bytes(16)
    self:_write(challenge)

    local response = self.reader:bytes(16)
    local key = self:_auth_key()
    local expected = Des.ecb_encrypt_block(key, challenge:sub(1, 8)) ..
                     Des.ecb_encrypt_block(key, challenge:sub(9, 16))

    local ok = response == expected
    local out = Util.writer()
    out:u32(ok and 0 or 1)
    if not ok and self.version >= 3008 then
        local reason = "Authentication failure"
        out:u32(#reason):raw(reason)
    end
    self:_write(out:tostring())
    if not ok then logger.warn("vncviewer: server rejected a VNC authentication attempt") end
    return ok
end

-- ---------------------------------------------------------------- client messages

--- SetColorMapEntries: needed only for clients asking for a non-true-colour format.
function Server:_send_colour_map()
    local map = self.get_colour_map and self.get_colour_map()
    if not map then return end
    local out = Util.writer()
    out:u8(1):u8(0):u16(0):u16(#map)
    for _, c in ipairs(map) do out:u16(c[1] * 257):u16(c[2] * 257):u16(c[3] * 257) end
    self:_write(out:tostring())
end

function Server:_read_pixel_format()
    local r = self.reader
    r:bytes(3)                                  -- padding
    local fmt = {
        bits_per_pixel = r:u8(),
        depth = r:u8(),
        big_endian = r:u8(),
        true_colour = r:u8(),
        red_max = r:u16(),
        green_max = r:u16(),
        blue_max = r:u16(),
        red_shift = r:u8(),
        green_shift = r:u8(),
        blue_shift = r:u8(),
    }
    r:bytes(3)                                  -- padding
    local bits = fmt.bits_per_pixel
    if not (bits == 8 or bits == 16 or bits == 24 or bits == 32) then
        error(string.format("unsupported client pixel format: %d bits per pixel", bits), 0)
    end
    if fmt.true_colour == 0 and not (self.get_colour_map and self.get_colour_map()) then
        error("client requests a colour-mapped pixel format, which this server does not support", 0)
    end
    self.client.pixel_format = fmt
    if fmt.true_colour == 0 then self:_send_colour_map() end
    logger.dbg("vncviewer: client pixel format", string.format(
        "%dbpp depth %d, shifts %d/%d/%d, maxes %d/%d/%d, true_colour %d, big_endian %d",
        bits, fmt.depth, fmt.red_shift, fmt.green_shift, fmt.blue_shift,
        fmt.red_max, fmt.green_max, fmt.blue_max, fmt.true_colour, fmt.big_endian))
end

function Server:_read_encodings()
    local r = self.reader
    r:u8()                                      -- padding
    local count = r:u16()
    local encodings = {}
    for _ = 1, count do
        local enc = r:s32()
        if enc == Server.PSEUDO_DESKTOP_SIZE then
            self.client.desktop_size_supported = true
        elseif enc == Server.PSEUDO_LAST_RECT then
            self.client.last_rect_supported = true
        elseif Server.SUPPORTED_ENCODINGS[enc] then
            encodings[#encodings + 1] = enc
        end
    end
    if #encodings == 0 then encodings = { 0 } end     -- Raw is mandatory for every client
    self.client.encodings = encodings
    logger.dbg("vncviewer: client encodings", table.concat(encodings, ","))
end

function Server:_handle_update_request()
    local r = self.reader
    local incremental = r:u8() ~= 0
    local x, y, w, h = r:u16(), r:u16(), r:u16(), r:u16()

    local rects = self:_collect_rects(x, y, w, h, not incremental)
    if #rects == 0 and incremental then
        -- Nothing changed: hold this request until the screen does (see the module comment).
        coroutine.yield("idle")
        rects = self:_collect_rects(x, y, w, h, false)
    end
    self:_send_update(rects)
end

--- Rectangles to send for a request covering `(x, y, w, h)`, including any pending desktop resize.
function Server:_collect_rects(x, y, w, h, full)
    local rects = {}
    local client = self.client
    if client.pending_desktop then
        -- DesktopSize (-223): the new geometry is carried by the rectangle's own fields.
        rects[#rects + 1] = { x = 0, y = 0, w = client.pending_desktop[1], h = client.pending_desktop[2],
                              encoding = Server.PSEUDO_DESKTOP_SIZE }
    end
    for _, rect in ipairs(self.get_rects(client, { x = x, y = y, w = w, h = h }, full) or {}) do
        rects[#rects + 1] = rect
    end
    if #rects == 0 and full then
        -- A non-incremental request must be answered, even if we think nothing changed.
        local sw, sh = self.get_size()
        rects[1] = { x = 0, y = 0, w = sw, h = sh }
    end
    if #rects > 0 then client.pending_desktop = nil end
    return rects
end

function Server:_send_update(rects)
    -- Encode first: the rectangle headers carry the encoding each rectangle actually ended up
    -- with, and the encoder decides that (it may fall back to Raw, for instance).
    local encoded = {}
    for i, rect in ipairs(rects) do
        local encoding = rect.encoding or 0
        local payload
        if encoding ~= Server.PSEUDO_DESKTOP_SIZE and encoding ~= Server.PSEUDO_LAST_RECT then
            encoding, payload = self.encode(self.client, rect)
        end
        encoded[i] = { rect = rect, encoding = encoding, payload = payload }
    end

    local header = Util.writer()
    header:u8(0)
    header:u8(0)
    header:u16(#encoded)
    for _, e in ipairs(encoded) do
        header:u16(e.rect.x)
        header:u16(e.rect.y)
        header:u16(e.rect.w)
        header:u16(e.rect.h)
        header:u32(e.encoding)     -- u32() wraps, so pseudo-encodings stay signed on the wire
    end
    self:_write(header:tostring())

    for _, e in ipairs(encoded) do
        if e.payload then self:_write(e.payload) end
    end
end

function Server:_message_loop()
    local r = self.reader
    while true do
        local msg = r:u8()
        if msg == 0 then
            self:_read_pixel_format()
        elseif msg == 2 then
            self:_read_encodings()
        elseif msg == 3 then
            self:_handle_update_request()
        elseif msg == 4 then
            local down = r:u8() ~= 0
            r:bytes(2)                                  -- padding
            local keysym = r:u32()
            if self.on_key then self.on_key(keysym, down, self.client) end
        elseif msg == 5 then
            local mask = r:u8()
            local x, y = r:u16(), r:u16()
            self.client.pointer_x, self.client.pointer_y = x, y
            self.client.buttons = mask
            if self.on_pointer then self.on_pointer(x, y, mask, self.client) end
        elseif msg == 6 then
            r:bytes(3)                                  -- padding
            local len = r:u32()
            local text = r:bytes(len)
            if self.on_cut_text then self.on_cut_text(text, self.client) end
        else
            error(string.format("unknown client message %d", msg), 0)
        end
    end
end

return Server

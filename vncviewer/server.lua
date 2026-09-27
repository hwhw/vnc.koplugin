--[[--
The VNC server: a LuaSocket listener, one @{vncviewer.rfbserver} per connected client, the
screen capture that feeds them and the input injection that drives KOReader from their events.

Everything runs from a `UIManager:scheduleIn` poll task, so the server never blocks the UI
thread - the same discipline the client side uses for its socket. Screen changes are collected by
wrapping `UIManager._refresh`, which is the one place where a frame is complete (and therefore
tear-free), and are handed to each client as dirty rectangles.

Input from clients is injected at the level KOReader's own device backends use: Linux-input style
`EV_ABS`/`EV_SYN` events fed to `Device.input:handleTouchEv`, keys as `EV_KEY` events through the
device's own `event_map`, and typed text as `TextInput` events. That keeps this device independent
- no backend (SDL, Kindle, Kobo, ...) is special-cased.

@module vncviewer.server
]]

local bit = require("bit")
local ffi = require("ffi")
local socket = require("socket")

local BB = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Keysyms = require("vncviewer/keysyms")
local RfbServer = require("vncviewer/rfbserver")
local ServerEnc = require("vncviewer/serverenc")
local Util = require("vncviewer/util")

-- Linux input constants (EV_*/ABS_MT_*/SYN_REPORT), the same ones the device backends use.
require("ffi/linux_input_h")
local C = ffi.C

local Server = {}
Server.__index = Server

Server.POLL_INTERVAL = 0.05          -- seconds between socket services
Server.MAX_CLIENTS = 4
Server.DIRTY_LIMIT = 64              -- dirty rectangles kept before falling back to a full frame
Server.READ_CHUNK = 65536

--[[--
Creates a server (it does not listen until @{Server:start} is called).

--- @tparam table opts
--- @tparam table opts.settings the `server` sub-table of @{vncviewer.settings} (ip, port, password)
--- @tparam[opt] string opts.name desktop name announced to clients
--- @tparam[opt] function opts.on_status called when the running state or the client count changes
--- @treturn Server
]]
function Server.new(opts)
    assert(type(opts) == "table" and opts.settings, "Server.new: opts.settings is required")
    local self = setmetatable({
        settings = opts.settings,
        name = opts.name or "KOReader",
        on_status = opts.on_status,
        listener = nil,
        clients = {},
        running = false,
        last_error = nil,
        _gen = 0,
        _evicted_gen = 0,
        _dirty = {},
        _screen_at = nil,       -- screen size the last update was built for
        _orig_refresh = nil,
        _poll_task = nil,
    }, Server)
    self._refresh_hook = function(mgr, mode, region, dither)
        self:_record_dirty(mode, region)
        return self._orig_refresh(mgr, mode, region, dither)
    end
    self._poll_task = function() self:_poll() end
    return self
end

function Server:is_running()
    return self.running
end

--- How many clients are connected and ready.
function Server:client_count()
    local n = 0
    for _ in pairs(self.clients) do n = n + 1 end
    return n
end

function Server:status_text()
    if not self.running then
        return self.last_error
    end
    return string.format("%s:%d", self.settings.ip, self.settings.port)
end

function Server:_notify_status()
    if self.on_status then self.on_status(self) end
end

-- ---------------------------------------------------------------- lifecycle

--[[--
Makes a hole in the Kindle's firewall for our port (and undoes it in @{Server:stop}).

Adapted from KOReader's own HTTP inspector plugin, which does the same thing for its port.
]]
function Server:_firewall(action)
    if not (Device.isKindle and Device:isKindle()) then return end
    local port = self.settings.port
    local flag = action == "add" and "-A" or "-D"
    os.execute(string.format("%s %s %s", "iptables", flag, "INPUT -p tcp --dport " .. port ..
        " -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT"))
    os.execute(string.format("%s %s %s", "iptables", flag, "OUTPUT -p tcp --sport " .. port ..
        " -m conntrack --ctstate ESTABLISHED -j ACCEPT"))
end

--- Binds the listener and starts serving. Returns true, or false plus a message.
function Server:start()
    if self.running then return true end

    local listener, err = socket.tcp()
    if not listener then
        self.last_error = "cannot create a socket: " .. tostring(err)
        return false, self.last_error
    end
    listener:setoption("reuseaddr", true)
    local ok
    ok, err = listener:bind(self.settings.ip, self.settings.port)
    if not ok then
        listener:close()
        self.last_error = string.format("cannot bind %s:%d: %s",
            self.settings.ip, self.settings.port, tostring(err))
        logger.warn("vncviewer: server", self.last_error)
        return false, self.last_error
    end
    ok, err = listener:listen(Server.MAX_CLIENTS)
    if not ok then
        listener:close()
        self.last_error = string.format("cannot listen: %s", tostring(err))
        return false, self.last_error
    end
    listener:settimeout(0)
    self.listener = listener
    self.running = true
    self.last_error = nil

    self:_firewall("add")
    self:_hook_refresh()
    self._gen, self._evicted_gen, self._dirty = 0, 0, {}
    local sw, sh = self:_screen_size()
    self._screen_at = { sw, sh }
    UIManager:scheduleIn(Server.POLL_INTERVAL, self._poll_task)
    logger.info("vncviewer: VNC server listening on", self.settings.ip .. ":" .. self.settings.port)
    self:_notify_status()
    return true
end

--- Stops serving, drops every client and restores the firewall.
function Server:stop()
    if not self.running and not self.listener then return end
    self.running = false
    UIManager:unschedule(self._poll_task)
    self:_unhook_refresh()

    for _, client in pairs(self.clients) do
        self:_drop_client(client, "server stopped")
    end
    self.clients = {}

    if self.listener then
        self.listener:close()
        self.listener = nil
    end
    self:_firewall("remove")
    logger.info("vncviewer: VNC server stopped")
    self:_notify_status()
end

-- ---------------------------------------------------------------- capture

function Server:_screen_size()
    local bb = Screen.bb
    if bb then return bb:getWidth(), bb:getHeight() end
    local size = Screen:getSize()
    return size.w, size.h
end

--[[--
Wraps `UIManager._refresh`, KOReader's single "this frame is done" point.

Only records rectangles here: encoding happens in the poll task, so a repaint never pays for a
client's bandwidth. Other plugins may wrap the same function, so restoring is conditional on our
own hook still being in place.
]]
function Server:_hook_refresh()
    if self._orig_refresh then return end
    self._orig_refresh = UIManager._refresh
    UIManager._refresh = self._refresh_hook
end

function Server:_unhook_refresh()
    if not self._orig_refresh then return end
    if UIManager._refresh == self._refresh_hook then
        UIManager._refresh = self._orig_refresh
    else
        logger.warn("vncviewer: UIManager._refresh was wrapped by somebody else; leaving it alone")
    end
    self._orig_refresh = nil
end

--- Records what a refresh changed, as one generation-stamped rectangle.
function Server:_record_dirty(mode, region)
    local w, h = self:_screen_size()
    local x, y, rw, rh = 0, 0, w, h
    if region then
        x = math.max(0, math.floor(region.x or 0))
        y = math.max(0, math.floor(region.y or 0))
        rw = math.min(w - x, math.ceil(region.w or w))
        rh = math.min(h - y, math.ceil(region.h or h))
    end
    if rw <= 0 or rh <= 0 then return end

    self._gen = self._gen + 1
    local dirty = self._dirty
    dirty[#dirty + 1] = { gen = self._gen, x = x, y = y, w = rw, h = rh }
    while #dirty > Server.DIRTY_LIMIT do
        local dropped = table.remove(dirty, 1)
        -- A client that has not been served since then must be told to resend everything.
        self._evicted_gen = math.max(self._evicted_gen, dropped.gen)
    end
end

--- The rectangle list for one client's update (called by the protocol).
function Server:_get_rects(client, region, full)
    local out = {}
    local sent = client.sent_gen or 0
    if full or sent < self._evicted_gen then
        out[1] = { x = region.x, y = region.y, w = region.w, h = region.h }
        client.sent_gen = self._gen
        return out
    end
    for _, d in ipairs(self._dirty) do
        if d.gen > sent then
            local x, y, w, h = Util.intersect_rect(d, region)
            if x then
                out[#out + 1] = { x = x, y = y, w = w, h = h }
            end
        end
    end
    client.sent_gen = self._gen
    return out
end

--- Encodes one rectangle for one client (called by the protocol).
function Server:_encode(client, rect)
    local fmt = client.pixel_format
    local enc = client.enc
    if not enc then
        enc = ServerEnc.new()
        client.enc = enc
    end
    if fmt and client.enc_format ~= fmt then
        enc:set_pixel_format(fmt)
        client.enc_format = fmt
    end
    if not client.enc_format then
        -- No SetPixelFormat yet: use what ServerInit announced.
        enc:set_pixel_format({
            bits_per_pixel = 32, depth = 24, big_endian = 0, true_colour = 1,
            red_max = 255, green_max = 255, blue_max = 255,
            red_shift = 0, green_shift = 8, blue_shift = 16,
        })
        client.enc_format = true
    end
    if client.enc_encodings ~= client.encodings then
        enc:set_encodings(client.encodings)
        client.enc_encodings = client.encodings
    end
    return enc:encode(Screen.bb, rect)
end

-- ---------------------------------------------------------------- clients

function Server:_accept()
    while true do
        local sock, err = self.listener:accept()
        if not sock then
            if err ~= "timeout" then
                logger.warn("vncviewer: accept failed:", tostring(err))
            end
            return
        end
        if self:client_count() >= Server.MAX_CLIENTS then
            logger.warn("vncviewer: refusing a client, already serving", Server.MAX_CLIENTS)
            sock:close()
        else
            self:_adopt_client(sock)
        end
    end
end

function Server:_adopt_client(sock)
    sock:settimeout(0)
    local client = {
        sock = sock,
        rx = {},                 -- incoming byte chunks, joined lazily
        rx_len = 0,
        tx = {},                 -- outgoing byte chunks
        tx_len = 0,
        pending = nil,           -- how many bytes the coroutine waits for
        parked = false,          -- asked for an update while nothing had changed
    }
    client.server = RfbServer.new({
        io = {
            read = function(n)
                client.pending = n
                client.parked = false
                return coroutine.yield("need", n)
            end,
            write = function(s)
                client.tx[#client.tx + 1] = s
                client.tx_len = client.tx_len + #s
            end,
        },
        password = self.settings.password,
        name = self.name,
        get_size = function() return self:_screen_size() end,
        get_rects = function(c, region, full) return self:_get_rects(c, region, full) end,
        encode = function(c, rect) return self:_encode(c, rect) end,
        get_colour_map = function() return ServerEnc.COLOUR_MAP end,
        on_pointer = function(x, y, mask, c) self:_on_pointer(c, x, y, mask) end,
        on_key = function(keysym, down, c) self:_on_key(c, keysym, down) end,
        on_cut_text = function(text, c) self:_on_cut_text(c, text) end,
        on_ready = function() self:_notify_status() end,
    })
    local key = tostring(sock)
    client.key = key
    self.clients[key] = client
    logger.info("vncviewer: client connected")
    self:_client_step(client)
end

function Server:_drop_client(client, why)
    if client.dropped then return end
    client.dropped = true
    if client.sock then
        client.sock:close()
        client.sock = nil
    end
    if client.enc then
        client.enc:free()
        client.enc = nil
    end
    if client.key then self.clients[client.key] = nil end
    logger.info("vncviewer: client disconnected:", why or "connection closed")
    self:_notify_status()
end

--- Reads whatever is available and advances the client's state machine.
function Server:_client_step(client)
    if client.dropped then return end
    local step = client.server.step
    -- Feed the bytes the coroutine is waiting for, as far as they have arrived.
    if client.pending and client.rx_len >= client.pending then
        local data = self:_take_rx(client, client.pending)
        client.pending = nil
        local kind, arg = step(client.server, data)
        self:_after_step(client, kind, arg)
    elseif not client.pending then
        local kind, arg = step(client.server, nil)
        self:_after_step(client, kind, arg)
    end
end

function Server:_after_step(client, kind, arg)
    if kind == "need" then
        client.pending = arg
        -- Maybe the bytes are already buffered.
        if client.pending and client.rx_len >= client.pending then
            self:_client_step(client)
        end
    elseif kind == "idle" then
        client.parked = true
    elseif kind == nil then
        self:_drop_client(client, tostring(arg))
    end
end

function Server:_take_rx(client, n)
    local parts = {}
    local got = 0
    while got < n do
        local chunk = client.rx[1]
        local want = math.min(#chunk, n - got)
        parts[#parts + 1] = chunk:sub(1, want)
        got = got + want
        if want == #chunk then
            table.remove(client.rx, 1)
        else
            client.rx[1] = chunk:sub(want + 1)
        end
    end
    client.rx_len = client.rx_len - n
    return table.concat(parts)
end

--- Reads from the socket, advances the state machine, flushes outgoing data.
function Server:_service_client(client)
    if client.dropped then return end
    local sock = client.sock

    -- read (bounded per tick)
    local budget = 4
    while budget > 0 and (not client.pending or client.rx_len < client.pending) do
        budget = budget - 1
        local data, err = sock:receive(Server.READ_CHUNK)
        if data and #data > 0 then
            client.rx[#client.rx + 1] = data
            client.rx_len = client.rx_len + #data
        elseif err == "timeout" then
            break
        else
            if err ~= "closed" then
                logger.warn("vncviewer: client read error:", tostring(err))
            end
            self:_drop_client(client, "closed")
            return
        end
    end
    self:_client_step(client)

    -- write
    while client.tx_len > 0 and not client.dropped do
        local chunk = client.tx[1]
        local sent, err, last = sock:send(chunk, 1)
        if sent and sent > 0 then
            if sent >= #chunk then
                table.remove(client.tx, 1)
            else
                client.tx[1] = chunk:sub(sent + 1)
            end
            client.tx_len = client.tx_len - sent
        elseif err == "timeout" then
            break
        else
            self:_drop_client(client, "write failed: " .. tostring(err))
            return
        end
    end
end

function Server:_poll()
    self._poll_task_scheduled = false
    if not self.running then return end

    self:_accept()

    -- a screen change may un-park clients waiting for an update
    local resized = false
    local sw, sh = self:_screen_size()
    if self._screen_at and (self._screen_at[1] ~= sw or self._screen_at[2] ~= sh) then
        resized = true
        for _, client in pairs(self.clients) do
            client.server.client.pending_desktop = { sw, sh }
        end
    end
    self._screen_at = { sw, sh }
    if resized then
        self._gen = self._gen + 1
        self._dirty[#self._dirty + 1] = { gen = self._gen, x = 0, y = 0, w = sw, h = sh }
    end

    for _, client in pairs(self.clients) do
        self:_service_client(client)
        if client.parked and #self._dirty > 0 and not client.dropped then
            client.parked = false
            local kind, arg = client.server:step(nil)
            self:_after_step(client, kind, arg)
        end
    end

    -- The dirty list is deliberately *not* cleared here: each client remembers the generation it
    -- was last served (`sent_gen`), and the list's eviction age tells us when a client has to be
    -- given a full frame instead.
    if self.running then
        UIManager:scheduleIn(Server.POLL_INTERVAL, self._poll_task)
    end
end

-- ---------------------------------------------------------------- client input

--[[--
Feeds Linux-input style events to KOReader and dispatches whatever gestures come out.

This is the seam KOReader's own device backends use (`EV_ABS` for positions, a `SYN_REPORT` to
close an input frame), so a single implementation serves every device: mouse-like clients become
taps, drags and long presses exactly as a finger would.
]]
function Server:_inject(evs)
    local input = Device.input
    if not input then return end
    local handled = {}
    for _, ev in ipairs(evs) do
        ev.time = { sec = os.time(), usec = 0 }
        if input.eventAdjustHook then input:eventAdjustHook(ev) end
        if ev.type == C.EV_KEY then
            local one = input:handleKeyBoardEv(ev)
            if one then handled[#handled + 1] = one end
        else
            local many = input:handleTouchEv(ev)
            if many then
                for _, e in ipairs(many) do handled[#handled + 1] = e end
            end
        end
    end
    for _, e in ipairs(handled) do
        UIManager:handleInputEvent(e)
    end
end

local function abs_ev(code, value)
    return { type = C.EV_ABS, code = code, value = value }
end

local function key_ev(code, value)
    return { type = C.EV_KEY, code = code, value = value }
end

local SYN = { type = C.EV_SYN, code = C.SYN_REPORT, value = 0 }

--- PointerEvent: a press/release at a position, with the button mask doing the rest.
function Server:_on_pointer(client, x, y, mask)
    local was_down = (client.buttons or 0) ~= 0
    client.buttons = mask
    client.pointer_x, client.pointer_y = x, y
    local down = mask ~= 0
    if down == was_down then
        -- motion only: KOReader has no hover, so nothing to do until a button changes
        return
    end
    local slot = abs_ev(C.ABS_MT_SLOT, 0)
    if down then
        self:_inject({
            slot,
            abs_ev(C.ABS_MT_TRACKING_ID, 1),
            abs_ev(C.ABS_MT_TOOL_TYPE, 0),          -- finger
            abs_ev(C.ABS_MT_POSITION_X, x),
            abs_ev(C.ABS_MT_POSITION_Y, y),
            key_ev(C.BTN_TOUCH, 1),                 -- the "snow" protocol wants this too
            SYN,
        })
    else
        self:_inject({
            abs_ev(C.ABS_MT_POSITION_X, x),
            abs_ev(C.ABS_MT_POSITION_Y, y),
            abs_ev(C.ABS_MT_SLOT, 0),
            abs_ev(C.ABS_MT_TRACKING_ID, -1),
            key_ev(C.BTN_TOUCH, 0),
            SYN,
        })
    end
end

--- KeyEvent: printable keysyms become text, named ones a real key press.
function Server:_on_key(client, keysym, down)
    if not Device.input then return end

    -- Printable keysyms arrive as text (KOReader types via TextInput, exactly like its own
    -- keyboard does); the modifier/motion keys below go through the key event path.
    local cp
    if keysym >= 0x20 and keysym <= 0x7E then
        cp = keysym
    elseif keysym >= 0x01000000 and keysym <= 0x0110FFFF then
        cp = keysym - 0x01000000                  -- the client's way of sending a Unicode char
    elseif keysym > 0x7E and keysym < 0x100 then
        cp = keysym
    end
    if cp then
        if down then
            UIManager:handleInputEvent(Event:new("TextInput", Keysyms.utf8(cp)))
        end
        return
    end

    local name = Keysyms.name_for_keysym(keysym)
    if not name then
        logger.dbg("vncviewer: unmapped keysym from client:", keysym)
        return
    end
    local code = self:_keycode_for(name)
    if not code then
        logger.dbg("vncviewer: this device has no key named", name)
        return
    end
    self:_inject({ key_ev(code, down and 1 or 0) })
end

--- Finds the input code this device maps to a KOReader key name.
function Server:_keycode_for(name)
    local map = Device.input and Device.input.event_map
    if not map then return nil end
    if not self._keycodes then
        self._keycodes = {}
        for code, mapped in pairs(map) do
            if type(mapped) == "string" and self._keycodes[mapped] == nil then
                self._keycodes[mapped] = code
            end
        end
    end
    return self._keycodes[name]
end

--- ClientCutText: put it where KOReader's own clipboard lives, if it has one.
function Server:_on_cut_text(client, text)
    logger.dbg("vncviewer: client cut text", #text, "bytes")
    if Device.setClipboardText then
        Device:setClipboardText(text)
    end
end

return Server

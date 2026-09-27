--[[--
The VNC server: a LuaSocket listener, one @{vnc.rfbserver} per connected client, the
screen capture that feeds them and the input injection that drives KOReader from their events.

Everything runs from a `UIManager:scheduleIn` poll task, so the server never blocks the UI
thread - the same discipline the client side uses for its socket. Screen changes are collected by
wrapping `UIManager._refresh`, which is the one place where a frame is complete (and therefore
tear-free), and are handed to each client as dirty rectangles.

Input from clients is injected at the level KOReader's own device backends use: Linux-input style
`EV_ABS`/`EV_SYN` events fed to `Device.input:handleTouchEv`, keys as `EV_KEY` events through the
device's own `event_map`, and typed text as `TextInput` events. That keeps this device independent
- no backend (SDL, Kindle, Kobo, ...) is special-cased.

@module vnc.server
]]

local bit = require("bit")
local ffi = require("ffi")
local socket = require("socket")

local BB = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local logger = require("logger")

local Keysyms = require("vnc/keysyms")
local RfbServer = require("vnc/rfbserver")
local ServerEnc = require("vnc/serverenc")
local Util = require("vnc/util")

-- Linux input constants (EV_*/ABS_MT_*/SYN_REPORT), the same ones the device backends use.
require("ffi/linux_input_h")
local C = ffi.C

local Server = {}
Server.__index = Server

-- One client message is processed per poll, so the poll rate *is* the input rate: at 50 ms a
-- moving mouse (dozens of motion messages per second) could never keep up. 10 ms gives ~100
-- messages per second, and the short socket timeout keeps an idle poll cheap.
Server.POLL_INTERVAL = 0.01          -- seconds between socket services
-- Client sockets use a short *blocking* timeout rather than a non-blocking zero one: LuaSocket's
-- receive(n) demands all n bytes and returns nil (with "timeout") even when some of them are
-- already waiting, so a zero timeout would never read anything. Reads only happen while the
-- protocol actually owes bytes, so an idle client costs nothing.
Server.IO_TIMEOUT = 0.01
--- How long a held update request may block the client's other messages before the server sends
--- an empty update to get back to reading them.
Server.STALL_TIMEOUT = 10
Server.MAX_CLIENTS = 4
Server.DIRTY_LIMIT = 64              -- dirty rectangles kept before falling back to a full frame
Server.READ_CHUNK = 65536
--- How far a client's pointer may move with the button down before it is a drag rather than the
--- pixel or two of wobble a mouse makes while clicking (in both axes' distance, like core's
--- gesture thresholds are).
Server.DRAG_THRESHOLD = 4

--[[--
Creates a server (it does not listen until @{Server:start} is called).

--- @tparam table opts
--- @tparam table opts.settings the `server` sub-table of @{vnc.settings} (ip, port, password)
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
    self._inject_client = {}                 -- button state for Server:inject_pointer
    -- Records the frame's dirty region and then does the refresh it wrapped. `_orig_refresh` is
    -- always the *original* UIManager._refresh - never our own hook - so however the chain around
    -- us is rearranged (a start after a stop somebody else wrapped, an unhook that could not
    -- restore), this can neither call a nil nor call itself.
    self._refresh_hook = function(mgr, mode, region, dither)
        self:_record_dirty(mode, region)
        local orig = self._orig_refresh
        if orig then return orig(mgr, mode, region, dither) end
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
        logger.warn("vnc: server", self.last_error)
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
    -- The generations just restarted from zero: a client that was somehow kept across the restart
    -- must be told to expect a full frame, not to compare against its old `sent_gen`.
    for _, client in pairs(self.clients) do
        client.server.client.sent_gen = nil
    end
    local sw, sh = self:_screen_size()
    self._screen_at = { sw, sh }
    UIManager:scheduleIn(Server.POLL_INTERVAL, self._poll_task)
    logger.info("vnc: VNC server listening on", self.settings.ip .. ":" .. self.settings.port)
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
    logger.info("vnc: VNC server stopped")
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
client's bandwidth. Other plugins may wrap the same function, so `_orig_refresh` is captured once
(the real `_refresh`) and kept across stop/start cycles: re-capturing it after somebody wrapped us
would chain our hook to itself and recurse on every frame.
]]
function Server:_hook_refresh()
    if not self._orig_refresh then
        self._orig_refresh = UIManager._refresh
    end
    if UIManager._refresh ~= self._refresh_hook then
        UIManager._refresh = self._refresh_hook
    end
end

function Server:_unhook_refresh()
    if not self._orig_refresh then return end
    if UIManager._refresh == self._refresh_hook then
        UIManager._refresh = self._orig_refresh
        self._orig_refresh = nil
    else
        -- Somebody wrapped us: their hook still reaches ours, and ours still reaches the real
        -- `_refresh`, so leave the chain alone (and keep `_orig_refresh` for a later start).
        logger.warn("vnc: UIManager._refresh was wrapped by somebody else; leaving it alone")
    end
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
    if rw <= 0 or rh <= 0 then
        -- Never hide this: a region we decided not to record is exactly what "the screen does not
        -- update" looks like from the inside.
        logger.dbg(string.format("vnc: ignoring a dirty region (mode %s): %s,%s %sx%s of %dx%d",
            tostring(mode), tostring(region and region.x), tostring(region and region.y),
            tostring(region and region.w), tostring(region and region.h), w, h))
        return
    end

    self._gen = self._gen + 1
    logger.dbg(string.format("vnc: recorded dirty region (mode %s): %d,%d %dx%d",
        tostring(mode), x, y, rw, rh))
    local dirty = self._dirty
    dirty[#dirty + 1] = { gen = self._gen, x = x, y = y, w = rw, h = rh }
    while #dirty > Server.DIRTY_LIMIT do
        local dropped = table.remove(dirty, 1)
        -- A client that has not been served since then must be told to resend everything.
        self._evicted_gen = math.max(self._evicted_gen, dropped.gen)
    end
end

--- The rectangle list for one client's update (called by the protocol).
---
--- `sent_gen` may only ever advance over generations whose rectangle reached the client: the
--- client's request covers `region` and nothing else, so a change it did not ask about (or that
--- it only asked about in part) stays queued and is offered again on its next request. Advancing
--- past it would drop it for good - the client would be told "nothing new" forever while the
--- screen kept changing.
function Server:_get_rects(client, region, full)
    local out = {}
    local sent = client.sent_gen
    -- A client that has been sent nothing yet (or has fallen behind the eviction window) needs a
    -- whole region: answering it with only the rectangles that happen to be dirty would show it
    -- a mostly empty screen, and an *incremental* first request (some clients send one) an empty
    -- update forever.
    if full or sent == nil or sent < self._evicted_gen then
        out[1] = { x = region.x, y = region.y, w = region.w, h = region.h }
        client.sent_gen = self._gen
        logger.dbg("vnc: answering a client with the full region", region.w, region.h)
        return out
    end
    local unsent_from = nil      -- oldest generation the client did not get in full
    for _, d in ipairs(self._dirty) do
        if d.gen > sent then
            local r = Util.intersect_rect(d, region)
            if r then
                out[#out + 1] = { x = r.x, y = r.y, w = r.w, h = r.h }
                if r.x ~= d.x or r.y ~= d.y or r.w ~= d.w or r.h ~= d.h then
                    unsent_from = unsent_from and math.min(unsent_from, d.gen) or d.gen
                end
            else
                unsent_from = unsent_from and math.min(unsent_from, d.gen) or d.gen
            end
        end
    end
    client.sent_gen = unsent_from and (unsent_from - 1) or self._gen
    if #out == 0 then
        logger.dbg("vnc: nothing new for this client, sending an empty update")
    else
        logger.dbg("vnc: sending", #out, "changed rect(s) to a client")
    end
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
    -- The encoder's own format is the source of truth, so a client that never sends
    -- SetPixelFormat still gets the format ServerInit announced.
    if fmt == nil then fmt = ServerEnc.DEFAULT_FORMAT end
    if enc.fmt ~= fmt then
        enc:set_pixel_format(fmt)
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
                logger.warn("vnc: accept failed:", tostring(err))
            end
            return
        end
        if self:client_count() >= Server.MAX_CLIENTS then
            logger.warn("vnc: refusing a client, already serving", Server.MAX_CLIENTS)
            sock:close()
        else
            self:_adopt_client(sock)
        end
    end
end

function Server:_adopt_client(sock)
    sock:settimeout(Server.IO_TIMEOUT)
    local client = {
        sock = sock,
        rx = {},                 -- incoming byte chunks, joined lazily
        rx_len = 0,
        tx = {},                 -- outgoing byte chunks
        tx_len = 0,
        pending = nil,           -- how many bytes the coroutine waits for
        parked = false,          -- asked for an update while nothing had changed
    }
    client.state = "fresh"       -- "fresh" | "reading" | "parked"
    client.server = RfbServer.new({
        io = {
            read = function(n)
                client.pending = n
                client.state = "reading"
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
    logger.info("vnc: client connected")
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
    logger.info("vnc: client disconnected:", why or "connection closed")
    self:_notify_status()
end

--- Reads whatever is available and advances the client's state machine.
function Server:_client_step(client)
    if client.dropped then return end
    local step = client.server.step
    if client.state == "reading" then
        -- Only ever resume a byte-hungry coroutine with its bytes; anything else would make the
        -- protocol's reader error out with "transport returned nil bytes".
        if client.pending and client.rx_len >= client.pending then
            local data = self:_take_rx(client, client.pending)
            client.pending = nil
            local kind, arg = step(client.server, data)
            self:_after_step(client, kind, arg)
        end
    elseif client.state == "fresh" then
        -- Start the state machine. A *parked* client must not be resumed here: it is waiting for
        -- the update logic in `_poll` to wake it (with new content, or to flush), and resuming it
        -- from the socket loop on every poll would re-park it at once and keep resetting that
        -- timer - which is exactly how a client's keystrokes ended up queued behind a held
        -- update request forever.
        local kind, arg = step(client.server, nil)
        self:_after_step(client, kind, arg)
    end
end

function Server:_after_step(client, kind, arg)
    if kind == "need" then
        client.pending = arg
        client.state = "reading"
        -- Maybe the bytes are already buffered.
        if client.pending and client.rx_len >= client.pending then
            self:_client_step(client)
        end
    elseif kind == "idle" then
        client.state = "parked"
        client.parked_at = socket.gettime()
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

    -- Read (bounded per tick). Ask for exactly what the protocol still owes: LuaSocket's
    -- receive(n) only returns once it has all n bytes, so asking for a full chunk would stall
    -- on any message smaller than that. The budget is generous because a moving mouse produces a
    -- stream of small motion messages, and falling behind on those delays everything else the
    -- client sends - its keystrokes in particular.
    local budget = 256
    while budget > 0 and (not client.pending or client.rx_len < client.pending) do
        budget = budget - 1
        local want = Server.READ_CHUNK
        if client.state == "reading" and client.pending then
            want = math.min(client.pending - client.rx_len, Server.READ_CHUNK)
        elseif client.state == "parked" then
            -- The protocol is holding an update request, so it cannot parse anything right now:
            -- buffer whatever the client sends (its keystrokes) one byte at a time, without
            -- blocking the UI thread.
            want = 1
        end
        if want <= 0 then break end
        sock:settimeout(client.state == "parked" and 0 or Server.IO_TIMEOUT)
        local data, err, partial = sock:receive(want)
        -- A timed-out read can still have received bytes, and LuaSocket hands those back *only*
        -- in `partial`: dropping them would silently shift every later message by the number of
        -- bytes lost, so the client's requests would be read as garbage (or never read again)
        -- while the connection stayed up.
        data = data or partial
        if data and #data > 0 then
            client.rx[#client.rx + 1] = data
            client.rx_len = client.rx_len + #data
            -- `partial` only ever arrives together with a timeout: the socket has nothing more
            -- waiting, so do not pay for another blocking read in this tick.
            if err == "timeout" then break end
        elseif err == "timeout" then
            break
        else
            if err ~= "closed" then
                logger.warn("vnc: client read error:", tostring(err))
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
        if not sent and err == "timeout" and type(last) == "number" and last > 0 then
            -- A timed-out send still put the bytes up to `last` on the wire. Keeping them in the
            -- queue would send them a second time on the next attempt, and the client would read
            -- every later frame from the wrong offset - the corruption that looks like "the screen
            -- stopped updating" while each rectangle was in fact sent.
            sent = last
        end
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
        local ok, err = pcall(self._service_client, self, client)
        if not ok then
            logger.err("vnc: servicing a client failed:", tostring(err))
            self:_drop_client(client, tostring(err))
        end
        -- A press whose client has not released or moved yet is a long press once a full hold
        -- interval has passed; that is decided here, on the poll, because while the contact is
        -- buffered no core timer keeps this task from running (c.f., Server:_on_pointer). The
        -- buffer lives on the connection's *input state* - the bag the protocol hands to the
        -- pointer callback - not on this bookkeeping record.
        if not client.dropped then
            self:_flush_pointer(client.server.client)
        end
        -- A message that is *partially* received and then goes quiet means we are waiting for
        -- bytes that are never coming (a length we mis-read, so every later message is being
        -- swallowed as its payload). Waiting for a client's *next* message is normal and must not
        -- count, hence the `rx_len > 0` requirement.
        if not client.dropped and client.state == "reading" and client.pending
                and client.rx_len > 0 and client.rx_len < client.pending then
            client.pending_since = client.pending_since or socket.gettime()
            if socket.gettime() - client.pending_since >= Server.STALL_TIMEOUT then
                self:_drop_client(client, string.format(
                    "stuck on a client message: %d of %d bytes arrived in %ds",
                    client.rx_len, client.pending, Server.STALL_TIMEOUT))
                goto continue_client
            end
        else
            client.pending_since = nil
        end
        ::continue_client::
    end

    -- The state bag Server:inject_pointer drives (KOReader's HTTP inspector, the tests) goes
    -- through the same contact buffering and needs the same flush.
    self:_flush_pointer(self._inject_client)

    -- The dirty list is deliberately *not* cleared here: each client remembers the generation it
    -- was last served (`sent_gen`), and the list's eviction age tells us when a client has to be
    -- given a full frame instead.
    if self.running then
        UIManager:scheduleIn(Server.POLL_INTERVAL, self._poll_task)
    end
end

-- ---------------------------------------------------------------- client input

--[[--
The timestamp an injected event has to carry: the clock the device stamps its *own* events with.

`GestureDetector` probes that clock from a real event (`clock_id`), and `Input:setTimeout` computes
a timer's deadline from the event that arms it: for a monotonic device that is `origin + delay`.
An origin on another clock - which `os.time()`, i.e. CLOCK_REALTIME in whole seconds, always was -
therefore arms a timer that is due decades away. While such a timer is pending,
`Input:waitEvent` never gives control back to `UIManager` (it keeps polling for the timer, which
cannot expire), so the scheduled poll task stops: no client input is injected, no update is sent,
and nothing is logged until a *local* event wakes the loop - which then wedges again, because the
timer that cannot expire is still armed. CLOCK_MONOTONIC is both what Linux input devices report
and what KOReader's own synthetic events use (c.f., ffi/SDL3.lua's genEmuEvent), so it is the
fallback for a device whose event clock the detector has not probed yet.
]]
local function event_time()
    local detector = Device.input and Device.input.gesture_detector
    local clock = detector and detector:getClockSource()
    local fts
    if clock == C.CLOCK_REALTIME then
        fts = time.realtime_coarse()
    elseif clock == C.CLOCK_BOOTTIME then
        fts = time.boottime()
    else
        fts = time.monotonic_coarse()
    end
    return time.split_s_us(fts)
end

--- The same clock as an fts number, for the decisions the server makes *between* injected frames
--- (how long a client's button has been down) and for stamping a frame that stands for something
--- the client did earlier: a buffered press carries the time the client's contact was read, so the
--- hold timer it arms lands where a finger's would rather than one interval after we got around to
--- injecting it.
local function event_now()
    local sec, usec = event_time()
    return time.s(sec) + time.us(usec)
end

--[[--
Feeds Linux-input style events to KOReader and dispatches whatever gestures come out.

This is the seam KOReader's own device backends use (`EV_ABS` for positions, a `SYN_REPORT` to
close an input frame), so a single implementation serves every device: mouse-like clients become
taps, drags and long presses exactly as a finger would.

`at` (an fts in the device's event clock, optional) is the time the frame happened at; it defaults
to now, and only a frame that stands for a client action from a moment ago passes it.
]]
function Server:_inject(evs, at)
    local input = Device.input
    if not input then return end
    local handled = {}
    -- One timestamp for the whole frame, like the kernel's SYN_REPORT carries for the real ones.
    local sec, usec = time.split_s_us(at or event_now())
    for _, ev in ipairs(evs) do
        ev.time = { sec = sec, usec = usec }
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
        if e.handler == "onKeyPress" or e.handler == "onKeyRelease" then
            local stack = UIManager._window_stack
            local top = stack and stack[#stack] and stack[#stack].widget
            logger.info(string.format("vnc: key %s dispatched to %s (window stack: %d)",
                tostring(e.args and e.args[1] and e.args[1].key or "?"),
                tostring(top and (top.name or top.id) or "nothing"), stack and #stack or 0))
        end
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

--- The frames a client's contact is fed to core with, in the same shape (and with the same
--- per-frame timestamp) the kernel uses for a finger's.
local function down_frame(x, y)
    return {
        abs_ev(C.ABS_MT_SLOT, 0),
        abs_ev(C.ABS_MT_TRACKING_ID, 1),
        abs_ev(C.ABS_MT_TOOL_TYPE, 0),          -- finger
        abs_ev(C.ABS_MT_POSITION_X, x),
        abs_ev(C.ABS_MT_POSITION_Y, y),
        key_ev(C.BTN_TOUCH, 1),                 -- the "snow" protocol wants this too
        SYN,
    }
end

local function lift_frame(x, y)
    return {
        abs_ev(C.ABS_MT_POSITION_X, x),
        abs_ev(C.ABS_MT_POSITION_Y, y),
        abs_ev(C.ABS_MT_SLOT, 0),
        abs_ev(C.ABS_MT_TRACKING_ID, -1),
        key_ev(C.BTN_TOUCH, 0),
        SYN,
    }
end

local function motion_frame(x, y)
    return {
        abs_ev(C.ABS_MT_POSITION_X, x),
        abs_ev(C.ABS_MT_POSITION_Y, y),
        SYN,
    }
end

--[[--
The detector's long-press interval, in the device's own timescale (fts), or nil when there is no
gesture detector to arm a hold timer in - in which case a contact is injected on sight, since
nothing about it can be judged later.
]]
local function hold_interval()
    local detector = Device.input and Device.input.gesture_detector
    local interval = detector and detector.ges_hold_interval
    if not interval or interval <= 0 then return nil end
    return interval
end

--- PointerEvent: a press/release at a position, with the button mask doing the rest.
---
--- `client` is the connection's input state bag (`buttons`, `press_x`/`press_y`, `dragging`,
--- `pointer_x`/`pointer_y`, `buffered`), and this function is its only writer: the protocol layer
--- hands over the PointerEvent as it arrived and leaves that state alone (c.f., vnc/rfbserver.lua's
--- `_message_loop`). Reading `client.buttons` as the *previous* mask is what turns a message into a
--- press or a release; anything that stores the new mask first makes every click look like motion.
---
--- A press is not injected the moment it is read, though. The moment a contact is down, core arms
--- its hold timer (`Contact:handleNonTap` -> `Input:setTimeout(slot, "hold", ..., tev.timev,
--- ges_hold_interval)`), and while an input timer is pending `Input:waitEvent` does *not* give
--- control back to UIManager - it keeps polling the device for a timer to expire. So a press
--- injected on sight starves the very poll task that is the only thing able to read the client's
--- release: the hold fires first and a click is delivered as a hold. And a client's lift is a
--- socket message, not a device event, so it cannot break that wait the way a finger's lift does.
---
--- The client's contact is therefore kept in `client.buffered` until it is *actionable*, which
--- three things make it:
---   * the lift. A click is press *and* release: both are injected now, in one frame each, which is
---     what the kernel delivers for a click too, and the detector judges a tap from them. That
---     leaves no timer pending, so the loop keeps running and the release is read as it arrives.
---   * motion past @{Server.DRAG_THRESHOLD}: a drag, so the down it starts from is injected
---     together with the motion that made it one, and everything after it is forwarded as before.
---   * @{Server:_flush_pointer}: the button is still down one hold interval later, so it is a long
---     press - the down goes in on its own then and core's own hold timer takes it from there.
--- While the contact is buffered no core timer exists, so the loop keeps running - which is what
--- makes the release readable at all, and what keeps updates flowing during a held contact.
function Server:_on_pointer(client, x, y, mask)
    local was_down = (client.buttons or 0) ~= 0
    local down = mask ~= 0
    client.buttons = mask
    client.pointer_x, client.pointer_y = x, y
    if down ~= was_down then
        logger.info(string.format("vnc: client pointer %s at %s,%s",
            down and "press" or "release", tostring(x), tostring(y)))
    elseif not self._logged_motion then
        -- The first *motion* of the server's life, at info: proof that a viewer's motion reaches
        -- us at all. Transitions above are not motion, hence the elseif.
        self._logged_motion = true
        logger.info("vnc: client pointer motion received at " .. tostring(x) .. "," .. tostring(y)
            .. " (further motion is logged at debug level)")
    else
        logger.dbg("vnc: client pointer motion at", x, y, "mask", mask)
    end
    if down and not was_down then
        client.press_x, client.press_y, client.dragging = x, y, false
        if hold_interval() then
            -- Buffer it: see the note above. The time is the device's own event clock, the same
            -- one the frame that carries it will be stamped with.
            client.buffered = { x = x, y = y, at = event_now() }
            return
        end
        self:_inject(down_frame(x, y))
        return
    end
    if not down and was_down then
        local buffered = client.buffered
        if buffered then
            -- The whole click is known: contact down and up, in one frame each (and the down
            -- stamped with the moment the client's press was read, so the detector sees the click
            -- the client made, not the moment we got around to injecting it).
            client.buffered = nil
            self:_inject(down_frame(buffered.x, buffered.y), buffered.at)
            self:_inject(lift_frame(x, y))
            return
        end
        self:_inject(lift_frame(x, y))
        return
    end
    -- Motion (the button mask has not changed).
    if not down then
        -- With no button down there is nothing to report (KOReader has no hover).
        return
    end
    local buffered = client.buffered
    if buffered then
        -- The pointer left the press point before the contact was ever injected: this is a drag,
        -- so inject the down it starts from and then the motion that made it one.
        if math.abs(x - buffered.x) + math.abs(y - buffered.y) < Server.DRAG_THRESHOLD then return end
        client.buffered = nil
        client.dragging = true
        self:_inject(down_frame(buffered.x, buffered.y), buffered.at)
        self:_inject(motion_frame(x, y))
        return
    end
    -- A mouse moves by a pixel or two while its button is pressed, and forwarding that turns every
    -- click into a drag (KOReader cancels the tap and pans instead): motion is only forwarded once
    -- the pointer has really left the press point.
    if not client.dragging then
        local dx = math.abs(x - (client.press_x or x))
        local dy = math.abs(y - (client.press_y or y))
        if dx + dy < Server.DRAG_THRESHOLD then return end
        client.dragging = true
    end
    self:_inject(motion_frame(x, y))
end

--[[--
Injects a buffered contact whose client has held the button for a full @{GestureDetector} long-press
interval: that is a long press, and core has to own it (its hold timer, its `onHold`/
`onHoldRelease`, its hold-pan). Called once per poll tick for every client, so one that keeps
holding - or has gone quiet - still gets its press.
]]
function Server:_flush_pointer(client)
    local buffered = client.buffered
    if not buffered then return end
    local interval = hold_interval()
    if interval and event_now() - buffered.at < interval then return end
    client.buffered = nil
    self:_inject(down_frame(buffered.x, buffered.y), buffered.at)
end

--- KeyEvent: printable keysyms become text, named ones a real key press.
function Server:_on_key(client, keysym, down)
    logger.info(string.format("vnc: client key keysym=0x%X %s", keysym, down and "down" or "up"))
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
        logger.dbg("vnc: unmapped keysym from client:", keysym)
        return
    end
    local code = self:_keycode_for(name)
    if not code then
        logger.info("vnc: this device has no key named", name, "- client key ignored")
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

--[[--
Feeds one pointer event into KOReader as if a VNC client had sent it.

Kept public (unlike the underscore-prefixed internals) so it can be driven from KOReader's HTTP
inspector and from tests: `.../ui/vnc/server/inject_pointer/300/200/1`.

A press goes through the same contact buffering a socket client's does (c.f., @{Server:_on_pointer}),
so it is a gesture, not a frame: a press and its release are injected together as a tap, a press and
then motion as a drag, and a press on its own once a full hold interval has passed since it - the
last one needs a running server, whose poll does that judging.
]]
--- @tparam number|string x
--- @tparam number|string y
--- @tparam number|string mask RFB button mask (1 = left button down, 0 = released)
function Server:inject_pointer(x, y, mask)
    self:_on_pointer(self._inject_client, tonumber(x) or 0, tonumber(y) or 0, tonumber(mask) or 0)
end

--- Feeds one key event into KOReader, as if a VNC client had sent it (X11 keysym).
--- @tparam number|string keysym
--- @tparam boolean|string down
function Server:inject_key(keysym, down)
    local is_down = (down == true) or (down == "true") or (down == 1) or (down == "1")
    self:_on_key(self._inject_client, tonumber(keysym) or 0, is_down)
end

--- ClientCutText: put it where KOReader's own clipboard lives, if it has one.
function Server:_on_cut_text(client, text)
    logger.info("vnc: client sent its clipboard,", #text, "bytes")
    if Device.setClipboardText then
        Device:setClipboardText(text)
    end
end

return Server

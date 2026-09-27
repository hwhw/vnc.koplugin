--[[--
VNC session: socket transport, Wi-Fi handling, attach/detach and reconnect.

A session owns one connection to one server. It drives @{vncviewer.protocol} from a poll
task registered with `UIManager:scheduleIn`, so the app can be closed (detached) without
dropping the connection: while detached the poll task is simply not scheduled, so nothing
is read, nothing is requested, and at most the single outstanding update request is
buffered by the kernel until we resume.

@module vncviewer.session
]]

local Encodings = require("vncviewer/encodings")
local Protocol = require("vncviewer/protocol")
local Remote = require("vncviewer/framebuffer")
local Util = require("vncviewer/util")
local logger = require("logger")

local UIManager = require("ui/uimanager")

-- The network manager drags in the whole widget stack; only load it when we actually need
-- Wi-Fi, so that merely loading the plugin at startup stays cheap.
local NetworkMgr

local Session = {}
Session.__index = Session

-- Seconds between poll ticks while attached.
Session.POLL_INTERVAL = 0.05
-- Hard caps so a single tick can never monopolise the UI thread.
Session.MAX_BYTES_PER_TICK = 262144
Session.MAX_STEPS_PER_TICK = 200
-- Wall-clock budget for the synchronous part of a handshake, and the socket timeout used
-- while it runs.
Session.HANDSHAKE_TIMEOUT = 20
Session.HANDSHAKE_SOCKET_TIMEOUT = 5

--[[--
Creates a session. Nothing is opened until @{Session:connect} is called.

--- @tparam table opts
--- @tparam table opts.profile connection profile (see @{vncviewer.settings})
--- @tparam[opt] table opts.plugin the plugin instance (for settings)
--- @tparam[opt] function opts.on_state `(state, err)` on every transition
--- @tparam[opt] table opts.network_mgr override the network manager (tests)
]]
function Session.new(opts)
    assert(type(opts) == "table" and type(opts.profile) == "table", "Session.new: opts.profile is required")
    return setmetatable({
        profile = opts.profile,
        plugin = opts.plugin,
        on_state = opts.on_state,
        state = "disconnected",
        err = nil,
        sock = nil,
        proto = nil,
        remote = nil,
        tx = {},           -- pending outgoing bytes (array of strings)
        rx = "",           -- received but not yet consumed bytes
        need = nil,        -- bytes the protocol is waiting for
        done = false,
        attached = false,
        app = nil,
        dirty = nil,       -- accumulated dirty rect, in remote coordinates
        wifi_was_on = nil, -- nil until we know
        _connect_cb = nil,
        _network_mgr = opts.network_mgr,
    }, Session)
end

--- @tparam string state
--- @tparam[opt] string err
function Session:_set_state(state, err)
    self.state, self.err = state, err
    logger.dbg("vncviewer: session", self.profile and self.profile.name, "->", state, err or "")
    if self.on_state then
        local ok, e = pcall(self.on_state, state, err)
        if not ok then logger.warn("vncviewer: on_state handler failed:", e) end
    end
end

--- The network manager (lazily required, or the injected test double).
function Session:_net()
    if self._network_mgr then return self._network_mgr end
    if not NetworkMgr then NetworkMgr = require("ui/network/manager") end
    return NetworkMgr
end

--- @treturn string one of `disconnected`, `connecting`, `connected`, `error`
function Session:get_state() return self.state end
function Session:is_connected() return self.state == "connected" end
function Session:is_attached() return self.attached end
function Session:get_remote() return self.remote end
function Session:get_profile() return self.profile end
function Session:get_error() return self.err end

-- ---------------------------------------------------------------- connect

--[[--
Opens the connection: turns Wi-Fi on when needed, connects the socket and runs the RFB
handshake.

The handshake itself is driven synchronously (the socket gets a real timeout for that
phase), so when `callback` reports success the plane exists and the session is usable.
Turning Wi-Fi on is inherently asynchronous, so `callback(ok, err)` may be invoked later
than `connect()` returns.
--- @tparam[opt] function callback `(ok, err)`, called exactly once
]]
function Session:connect(callback)
    if self.state == "connecting" or self.state == "connected" then
        if callback then callback(false, "already connecting or connected") end
        return
    end
    self._connect_cb = callback
    self.err = nil
    self:_set_state("connecting")

    local wifi_on = self:_net():isWifiOn()
    self.wifi_was_on = wifi_on
    if not wifi_on then
        local status = self:_net():turnOnWifiAndWaitForConnection(function()
            self:_do_connect()
        end)
        if status == false then
            self.wifi_was_on = nil
            self:_fail("could not turn on Wi-Fi")
        end
        return
    end
    self:_do_connect()
end

function Session:_finish_connect(ok, err)
    local cb = self._connect_cb
    self._connect_cb = nil
    if cb then
        local ok2, e = pcall(cb, ok, err)
        if not ok2 then logger.warn("vncviewer: connect callback failed:", e) end
    end
end

function Session:_do_connect()
    local p = self.profile
    logger.dbg("vncviewer: connecting to", p.host, p.port)
    local socket = require("socket")
    local sock = socket.tcp()
    if not sock then
        return self:_fail("could not create a TCP socket")
    end
    sock:settimeout(Session.HANDSHAKE_SOCKET_TIMEOUT)
    local ok, err = sock:connect(p.host, p.port)
    if not ok then
        self:_fail(string.format("could not connect to %s:%d (%s)", p.host, p.port, tostring(err)))
        return
    end
    sock:setoption("tcp-nodelay", true)
    self.sock = sock

    local enable_tight = false
    if self.plugin and self.plugin.settings then
        enable_tight = self.plugin.settings:get_setting("enable_tight") and true or false
    end
    local self_ref = self
    self.proto = Protocol.new{
        io = {
            write = function(s) self_ref.tx[#self_ref.tx + 1] = s end,
            read = function(n) return coroutine.yield("need", n) end,
        },
        host = p.host,
        port = p.port,
        password = p.password,
        shared = true,
        encodings = Encodings.order(enable_tight),
        get_plane = function() return self_ref.remote and self_ref.remote:get_plane() end,
        callbacks = {
            on_connected = function(name, w, h)
                logger.info("vncviewer: connected to", name, w, h)
                if self_ref.remote then
                    -- reconnect / fresh size: keep the object so the app's reference stays valid
                    self_ref.remote:resize(w, h)
                else
                    self_ref.remote = Remote.new(w, h)
                end
                self_ref:_set_state("connected")
            end,
            on_rect = function(x, y, w, h)
                self_ref.dirty = Util.union_rect(self_ref.dirty, { x = x, y = y, w = w, h = h })
            end,
            on_desktop_resize = function(w, h)
                logger.info("vncviewer: remote desktop resized to", w, h)
                if self_ref.remote then
                    self_ref.remote:resize(w, h)
                else
                    self_ref.remote = Remote.new(w, h)
                end
                if self_ref.app then self_ref.app:on_remote_resized(w, h) end
                -- resynchronise with a non-incremental update of the whole new area
                self_ref:request_full_update()
            end,
            on_bell = function()
                if self_ref.app then self_ref.app:on_bell() end
            end,
            on_cut_text = function(text)
                logger.dbg("vncviewer: server cut text:", text)
            end,
        },
    }
    self.done = false
    self.need = nil

    local deadline = os.time() + Session.HANDSHAKE_TIMEOUT
    while true do
        local status = self:_pump(true)
        if status == "error" then return end
        if status == "connected" then break end
        if os.time() >= deadline then
            self:_fail("timed out during the RFB handshake")
            return
        end
    end

    -- Connected: from now on the socket must never block the UI thread.
    sock:settimeout(0)
    self:_finish_connect(true)
end

-- ---------------------------------------------------------------- transport

--- Sends everything queued in `tx`, keeping any unsent tail for the next tick.
--- @treturn boolean|nil, string|nil nil plus an error only for real socket errors
function Session:_flush_tx()
    while #self.tx > 0 do
        local out = self.tx[1]
        local last, err = self.sock:send(out)
        if last == #out then
            table.remove(self.tx, 1)
        elseif last then
            self.tx[1] = out:sub(last + 1)
            return true
        elseif err == "timeout" then
            return true
        else
            return nil, string.format("socket send failed (%s)", tostring(err))
        end
    end
    return true
end

--- Queues are flushed right away for UI-driven input, so typing feels immediate.
function Session:_flush_now()
    if not self.sock then return end
    local ok, err = self:_flush_tx()
    if not ok then self:_fail(err) end
end

--- Resumes the protocol, remembering what it asked for.
--- @treturn boolean false when the session failed
function Session:_resume(data)
    local a, b = self.proto:step(data)
    if a == "need" then
        self.need = b
    elseif a == "done" then
        self.done = true
    else
        self:_fail(b)
        return false
    end
    return true
end

--[[--
One round of work: flush outgoing bytes, feed the protocol, collect its requests.

--- @tparam[opt] boolean stop_connected return as soon as the handshake completed
--- @treturn string `"again"`, `"done"`, `"connected"` or `"error"`
]]
function Session:_pump(stop_connected)
    local ok, err = self:_flush_tx()
    if not ok then
        self:_fail(err)
        return "error"
    end

    local budget = Session.MAX_BYTES_PER_TICK
    local steps = Session.MAX_STEPS_PER_TICK
    while steps > 0 do
        steps = steps - 1
        if self.done then return "done" end
        if stop_connected and self.state == "connected" then return "connected" end
        if self.need then
            if #self.rx >= self.need then
                local chunk = self.rx:sub(1, self.need)
                self.rx = self.rx:sub(self.need + 1)
                self.need = nil
                budget = budget - #chunk
                if not self:_resume(chunk) then return "error" end
                local ok2, err2 = self:_flush_tx()
                if not ok2 then
                    self:_fail(err2)
                    return "error"
                end
            else
                local chunk, rerr, partial = self.sock:receive(self.need - #self.rx)
                if chunk then
                    self.rx = self.rx .. chunk
                    budget = budget - #chunk
                else
                    if partial and #partial > 0 then
                        self.rx = self.rx .. partial
                        budget = budget - #partial
                    end
                    if rerr == "timeout" then
                        return "again"
                    elseif rerr == "closed" then
                        self:_fail("connection closed by server")
                        return "error"
                    else
                        self:_fail(string.format("socket receive failed (%s)", tostring(rerr)))
                        return "error"
                    end
                end
            end
        else
            if not self:_resume(nil) then return "error" end
            local ok2, err2 = self:_flush_tx()
            if not ok2 then
                self:_fail(err2)
                return "error"
            end
        end
        if budget <= 0 then return "again" end
    end
    return "again"
end

-- ---------------------------------------------------------------- lifecycle

--- Registers the poll task and resynchronises the framebuffer.
function Session:attach(app)
    self.app = app
    if self.attached then return end
    self.attached = true
    UIManager:scheduleIn(Session.POLL_INTERVAL, self._poll, self)
    -- Non-incremental full area: resynchronises after a detach, and absorbs anything the
    -- server pushed while we were not reading.
    self:request_full_update()
    self:_flush_now()
end

--- Stops the poll task, keeping the socket, the plane and Wi-Fi up.
function Session:detach()
    UIManager:unschedule(self._poll)
    self.attached = false
    self.app = nil
    self.dirty = nil
end

--- The poll task. Must stay a single bound method so `UIManager:unschedule` can cancel it.
function Session:_poll()
    if not self.attached then return end
    local status = self:_pump()
    if status == "error" or status == "done" then
        UIManager:unschedule(self._poll)
        self.attached = false
        return
    end
    if self.dirty and self.app then
        local rect = self.dirty
        self.dirty = nil
        self.app:on_framebuffer_dirty(rect)
    end
    UIManager:scheduleIn(Session.POLL_INTERVAL, self._poll, self)
end

--- Closes the socket and frees the protocol, keeping the plane for display.
function Session:_teardown_connection()
    UIManager:unschedule(self._poll)
    self.attached = false
    if self.sock then
        self.sock:close()
        self.sock = nil
    end
    if self.proto then
        self.proto:free()
        self.proto = nil
    end
    self.tx, self.rx, self.need, self.done = {}, "", nil, false
end

--- Restores Wi-Fi if we were the ones who turned it on.
function Session:_restore_wifi()
    if self.wifi_was_on == false then
        logger.dbg("vncviewer: turning Wi-Fi back off")
        self:_net():turnOffWifi()
    end
    self.wifi_was_on = nil
end

--- Fails the session, keeping the app (and the last picture) alive for a reconnect.
function Session:_fail(err)
    local msg = tostring(err)
    logger.warn("vncviewer: session failed:", msg)
    self:_teardown_connection()
    self:_restore_wifi()
    self:_set_state("error", msg)
    self:_finish_connect(false, msg)
end

--- Closes the connection for good and frees the plane.
function Session:disconnect()
    self:_teardown_connection()
    self:_restore_wifi()
    if self.remote then
        self.remote:free()
        self.remote = nil
    end
    self:_set_state("disconnected")
end

-- ---------------------------------------------------------------- requests

--- Queues a non-incremental update request for the whole framebuffer.
--- Safe to call from protocol callbacks (it never flushes).
function Session:request_full_update()
    if not self.proto or not self.remote then return end
    local w, h = self.remote:get_size()
    self.proto:request_update(0, 0, 0, w, h)
end

--- @tparam number x remote x
--- @tparam number y remote y
--- @tparam number mask RFB pointer button mask
function Session:send_pointer(x, y, mask)
    if not self.proto then return end
    self.proto:send_pointer(x, y, mask)
    self:_flush_now()
end

--- @tparam number keysym X11 keysym
--- @tparam boolean down
function Session:send_key(keysym, down)
    if not self.proto then return end
    self.proto:send_key(keysym, down)
    self:_flush_now()
end

--- @tparam string text
function Session:send_cut_text(text)
    if not self.proto then return end
    self.proto:send_cut_text(text)
    self:_flush_now()
end

return Session

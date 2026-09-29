--[[--
vnc.koplugin — a VNC (RFB 3.8) client for KOReader.

Adds one entry to the file-browser main menu ("More tools - VNC viewer") and owns the
lifecycle of the single viewer app and of the connection sessions. Sessions outlive the app:
leaving the app only detaches it, so the connection (and the plane) is still there when the
viewer is reopened.

@module vnc.main
]]

local _ = require("gettext")
local T = require("ffi/util").template

local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local Dialogs = require("vnc/dialogs")
local Session = require("vnc/session")
local Server = require("vnc/server")
local ServerMenu = require("vnc/servermenu")
local Settings = require("vnc/settings")
local ViewerApp = require("vnc/app")

local VNC = WidgetContainer:extend{
    name = "vnc",
    is_doc_only = false,
    settings_file = nil, -- set in init()
    settings = nil,      -- @{vnc.settings} store
    sessions = {},       -- profile name -> @{vnc.session}
    app = nil,           -- the (single) live @{vnc.app}
    connection_list = nil, -- the connection list while it is on screen
}

--- The value this plugin stores in KOReader's own `start_with` setting for its entry.
---
--- KOReader only knows its own values ("filemanager", "history", …, see
--- @{apps.filemanager.filemanagermenu.FileManagerMenu:getStartWithMenuTable} and reader.lua);
--- an unknown one simply leaves it starting in the file browser, which is exactly where the
--- deferred autoconnect wants it.
VNC.START_WITH = "vnc_autoconnect"

function VNC:init()
    self.settings_file = DataStorage:getSettingsDir() .. "/vnc.lua"
    self.settings = Settings.open(self.settings_file)

    -- The VNC server (serving KOReader's own screen). It is off until the user starts it from
    -- the Network menu or the autostart below asks for it; nothing here listens on its own.
    -- `server_for_run()` is the stored settings with the environment overrides merged in for this
    -- run (the overrides never reach the settings file).
    self.server = Server.new{
        settings = self.settings:server_for_run(),
        name = "KOReader" .. (Device.model and (" on " .. Device.model) or ""),
    }

    -- File manager only (we have nothing to show inside a document).
    if self.ui and self.ui.menu and not self.ui.document then
        self.ui.menu:registerToMainMenu(self)
    end

    -- Not started here: at init() the screen and input may not be ready, and starting the server
    -- hooks UIManager. Defer it to the next UI loop turn, once.
    self:schedule_autostart()

    -- The client's own boot start, on the same terms: the flagged profile (if any) is connected
    -- once, from the first UI loop turn, never re-armed. Nothing is dialled at init().
    self:schedule_autoconnect()
end

--- Schedules the boot start when the settings (or the environment) ask for it.
---
--- Runs once per KOReader start and never re-arms, so a manual stop afterwards stays a stop until
--- the next start. The deferral is what lets main.lua's init() stay free of screen/input work.
function VNC:schedule_autostart()
    if not self.settings:should_autostart() then return end
    UIManager:nextTick(function() self:start_server_at_boot() end)
end

--- Starts the server for the boot start. A failure is logged and left in the server's own state
--- (`last_error`), which is what the Network menu's status line shows; boot pops no dialog.
function VNC:start_server_at_boot()
    local server = self.server
    if not server or server:is_running() then return end
    local ok, err = server:start()
    if not ok then
        logger.warn("vnc: could not start the VNC server at boot:", tostring(err))
    end
end

--- The profile that should auto-connect at KOReader start, if any.
--- @treturn table|nil
function VNC:autoconnect_profile()
    return self.settings and self.settings:autoconnect_profile() or nil
end

--- Schedules the boot connect when a profile carries the autoconnect flag.
---
--- Runs once per KOReader start and never re-arms, so leaving the viewer afterwards stays a
--- leave. The deferral is what lets main.lua's init() stay free of socket/UI work, and it is the
--- same seam the server's boot start uses.
function VNC:schedule_autoconnect()
    if not self:autoconnect_profile() then
        if G_reader_settings:readSetting("start_with") == VNC.START_WITH then
            -- The setting still names us but there is nothing to connect: KOReader starts
            -- normally (core does not know the value) and this is the only trace of it.
            logger.warn("vnc: start_with is \"" .. VNC.START_WITH
                .. "\" but no connection is flagged to auto connect")
        end
        return
    end
    UIManager:nextTick(function() self:autoconnect_at_boot() end)
end

--- Connects to the flagged profile at boot, once.
---
--- A failure is reported exactly like a manual attempt (@{VNC:connect_profile} shows the same
--- "Could not connect to …" message) and leaves the user in the normal KOReader UI: the viewer is
--- only opened on success, and the boot never retries.
function VNC:autoconnect_at_boot()
    local profile = self:autoconnect_profile()
    if not profile then return end
    self:connect_profile(profile.name)
end

function VNC:addToMainMenu(menu_items)
    menu_items.vnc = {
        text = _("VNC viewer"),
        sorting_hint = "more_tools",
        callback = function() self:show() end,
    }
    ServerMenu.register(self, menu_items)
    self:add_start_with_entry(menu_items)
end

--[[--
Adds "VNC auto connect" to KOReader's own "Start with" submenu.

The entry itself is a plain menu item carrying `sorting_hint = "start_with"`: KOReader's generic
menu sorter attaches any such item to the menu whose id is `start_with`, so it lands *inside* the
"Start with" submenu (the documented orphan-attachment extension point; `start_with` has an id via
`ui/elements/filemanager_menu_order.lua`). Nothing about core's own five entries is changed.

Two things core cannot do for us are added on top:

* Presence follows the live flag. The sorter nests the item once, at menu-build time, and the
  file-manager menu is cached, so a `sub_item_table_func` (which TouchMenu resolves every time the
  submenu is opened) returns the submenu without our item whenever no profile is flagged: the
  entry is *absent*, not merely disabled.
* The submenu's label (`text_func`) has no fallback and would return nil for our value, leaving
  "Start with" with nothing after it. It is wrapped - additively: every other value still goes to
  the core function - so ours reads as "Start with: VNC auto connect".
]]
function VNC:add_start_with_entry(menu_items)
    local start_with = menu_items.start_with
    if type(start_with) ~= "table" or type(start_with.sub_item_table) ~= "table" then return end
    local plugin = self

    local entry = {
        text = _("VNC auto connect"),
        sorting_hint = "start_with",
        -- Ticked when the feature is fully set up: a profile carries the flag and KOReader's own
        -- setting names us.
        checked_func = function()
            return plugin:autoconnect_profile() ~= nil
                and G_reader_settings:readSetting("start_with") == VNC.START_WITH
        end,
        -- On records the choice for the flagged profile (the entry only exists while one is
        -- flagged); off clears the profile's flag and the stored choice together.
        callback = function()
            local profile = plugin:autoconnect_profile()
            if not profile then return end
            if G_reader_settings:readSetting("start_with") == VNC.START_WITH then
                plugin.settings:set_autoconnect(nil)
                G_reader_settings:saveSetting("start_with", "filemanager")
            else
                plugin.settings:set_autoconnect(profile.name)
                G_reader_settings:saveSetting("start_with", VNC.START_WITH)
            end
            plugin.settings:flush()
        end,
    }
    menu_items.vnc_start = entry

    -- The sorter appends `entry` to this table once the menu is built; hiding it here (rather than
    -- not adding it) keeps the placement in the sorter's hands while presence follows the flag.
    local sorted_items = start_with.sub_item_table
    start_with.sub_item_table_func = function()
        local out = {}
        local flagged = plugin:autoconnect_profile() ~= nil
        for _, item in ipairs(sorted_items) do
            if item ~= entry or flagged then out[#out + 1] = item end
        end
        return out
    end

    local core_text_func = start_with.text_func
    start_with.text_func = function()
        if G_reader_settings:readSetting("start_with") == VNC.START_WITH then
            return T(_("Start with: %1"), _("VNC auto connect"))
        end
        return core_text_func and core_text_func()
    end
end

function VNC:onFlushSettings()
    if self.settings then self.settings:flush() end
end

-- ---------------------------------------------------------------- sessions

--- Reports session transitions. Errors are shown even when the app is open, except while a
--- connect attempt is in flight: that attempt's own callback reports the failure, and saying it
--- twice would stack two messages on screen.
function VNC:on_session_state(session, state, err)
    if state ~= "error" then return end
    if self._pending_connect == session then return end
    local message = tostring(err or _("unknown error"))
    if self.app and self.app.session == session then
        self.app:on_session_error(message)
    else
        UIManager:show(InfoMessage:new{ text = T(_("VNC: %1"), message), timeout = 4 })
    end
end

--[[--
Shows the viewer, reusing the running session when there is one.

--- @tparam[opt] string profile_name connect/re-attach this profile instead of asking
]]
function VNC:show(profile_name)
    if self.app then
        -- A re-shown viewer: `UIManager:show` refreshes nothing by itself, and a viewer is a
        -- wholesale change (c.f. ViewerApp:_wholesale_change).
        UIManager:show(self.app, "full")
        return
    end
    if profile_name then
        self:connect_profile(profile_name)
        return
    end
    local names = {}
    for name in pairs(self.sessions) do names[#names + 1] = name end
    if #names == 1 then
        local session = self.sessions[names[1]]
        if session:is_connected() then
            self:_open_app(session)
            return
        end
    end
    self:show_connection_list()
end

--[[--
Shows the connection list, replacing one that is already on screen.

This is what every "go back" in the connection dialogs ends up calling, so it must be safe to
call at any point (and it never leaves two lists stacked).
]]
function VNC:show_connection_list()
    -- Every dialog of ours returns here; a text field among them turned SDL text input off.
    if self.app then
        self.app:reassert_text_input()
        -- The list is above the viewer now: its keyboard must not stay on top of it.
        self.app:_sync_keyboard_later()
    end
    self:close_connection_list()
    self.connection_list = Dialogs.open_connection_list(self, {
        on_close = function() self.connection_list = nil end,
    })
end

--- Closes the connection list if it is on screen.
function VNC:close_connection_list()
    local menu = self.connection_list
    self.connection_list = nil
    if menu then UIManager:close(menu) end
end

--- Opens (or reopens) the viewer app for `session` and attaches it.
function VNC:_open_app(session)
    if not self.app then
        self.app = ViewerApp:new{ plugin = self, session = session }
        -- A full-screen widget must ask for the refresh it needs: `UIManager:show` only queues
        -- what the caller passed, and the viewer replaces the whole screen (c.f. ReaderUI, which
        -- is shown the same way).
        UIManager:show(self.app, "full")
        -- After showing: the app records the pre-existing rotation mode first.
        self.app:apply_default_orientation()
    else
        UIManager:show(self.app, "full")
    end
    session:attach(self.app)
end

--[[--
Connects to `name` (or re-attaches an existing connection to it) and opens the viewer.

--- @tparam string name profile name
--- @tparam[opt] function on_failure called after a failed attempt (the connection list passes
---   its "go back" here, so a failure returns the user to the list instead of dropping them out
---   of the plugin)
]]
function VNC:connect_profile(name, on_failure)
    local profile = self.settings:get_profile(name)
    if not profile then
        UIManager:show(InfoMessage:new{ text = T(_("No connection named %1."), name), timeout = 3 })
        return
    end

    local session = self.sessions[name]
    if not session then
        session = Session.new{
            profile = profile,
            plugin = self,
            on_state = function(state, err) self:on_session_state(session, state, err) end,
        }
        self.sessions[name] = session
    else
        session.profile = profile
    end

    if session:is_connected() then
        self:_open_app(session)
        return
    end

    self._pending_connect = session
    session:connect(function(ok, err)
        if self._pending_connect == session then self._pending_connect = nil end
        if not ok then
            if not self.app then
                -- never connected: don't keep a dead session around
                self.sessions[name] = nil
            end
            -- go back first, so the message is shown *on top of* whatever we return to
            if on_failure then on_failure() end
            UIManager:show(InfoMessage:new{
                text = T(_("Could not connect to %1: %2"), name, tostring(err)),
                timeout = 4,
            })
            return
        end
        self:_open_app(session)
    end)
end

--- Drops the connection to `name`, closing the viewer if it showed it.
function VNC:disconnect_session(name)
    local session = self.sessions[name]
    if not session then return end
    self.sessions[name] = nil
    self:_close_app_if(session)
    session:disconnect()
end

function VNC:_close_app_if(session)
    if self.app and self.app.session == session then
        self.app:restore_rotation()
        -- Coming back from a full-screen widget is a wholesale change: `UIManager:close` refreshes
        -- nothing on its own, so the file browser would stay off the panel (c.f. ReaderUI's close).
        UIManager:close(self.app, "full")
        self.app = nil
    end
end

--- Closes the viewer but keeps every connection alive for later pickup.
function VNC:leave_app()
    if self.app then
        self.app:restore_rotation()
        -- `UIManager:close` refreshes nothing on its own: without an explicit full refresh the
        -- file browser is repainted into the framebuffer but never pushed to an e-ink panel.
        UIManager:close(self.app, "full")
        self.app = nil
    end
    for _, session in pairs(self.sessions) do
        session:detach()
    end
end

-- ---------------------------------------------------------------- profiles

function VNC:save_profile(profile, existing_name)
    local ok, err = self.settings:save_profile(profile, existing_name)
    if not ok then
        logger.warn("vnc: could not save profile:", err)
        return false, err
    end
    if existing_name and existing_name ~= profile.name then
        -- keep the live session attached to the renamed profile
        local session = self.sessions[existing_name]
        if session then
            self.sessions[existing_name] = nil
            session.profile = self.settings:get_profile(profile.name)
            self.sessions[profile.name] = session
        end
    end
    self.settings:flush()
    return true
end

function VNC:delete_profile(name)
    if self.sessions[name] then
        self:disconnect_session(name)
    end
    self.settings:delete_profile(name)
    self.settings:flush()
end

return VNC

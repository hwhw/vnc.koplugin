--[[--
vncviewer.koplugin — a VNC (RFB 3.8) client for KOReader.

Adds one entry to the file-browser main menu ("More tools - VNC viewer") and owns the
lifecycle of the single viewer app and of the connection sessions. Sessions outlive the app:
leaving the app only detaches it, so the connection (and the plane) is still there when the
viewer is reopened.

@module vncviewer.main
]]

local _ = require("gettext")
local T = require("ffi/util").template

local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local Dialogs = require("vncviewer/dialogs")
local Session = require("vncviewer/session")
local Settings = require("vncviewer/settings")
local ViewerApp = require("vncviewer/app")

local VNCViewer = WidgetContainer:extend{
    name = "vncviewer",
    is_doc_only = false,
    settings_file = nil, -- set in init()
    settings = nil,      -- @{vncviewer.settings} store
    sessions = {},       -- profile name -> @{vncviewer.session}
    app = nil,           -- the (single) live @{vncviewer.app}
    connection_list = nil, -- the connection list while it is on screen
}

function VNCViewer:init()
    self.settings_file = DataStorage:getSettingsDir() .. "/vncviewer.lua"
    self.settings = Settings.open(self.settings_file)

    -- File manager only (we have nothing to show inside a document).
    if self.ui and self.ui.menu and not self.ui.document then
        self.ui.menu:registerToMainMenu(self)
    end
end

function VNCViewer:addToMainMenu(menu_items)
    menu_items.vncviewer = {
        text = _("VNC viewer"),
        sorting_hint = "more_tools",
        callback = function() self:show() end,
    }
end

function VNCViewer:onFlushSettings()
    if self.settings then self.settings:flush() end
end

-- ---------------------------------------------------------------- sessions

--- Reports session transitions. Errors are shown even when the app is open, except while a
--- connect attempt is in flight: that attempt's own callback reports the failure, and saying it
--- twice would stack two messages on screen.
function VNCViewer:on_session_state(session, state, err)
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
function VNCViewer:show(profile_name)
    if self.app then
        UIManager:show(self.app)
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
function VNCViewer:show_connection_list()
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
function VNCViewer:close_connection_list()
    local menu = self.connection_list
    self.connection_list = nil
    if menu then UIManager:close(menu) end
end

--- Opens (or reopens) the viewer app for `session` and attaches it.
function VNCViewer:_open_app(session)
    if not self.app then
        self.app = ViewerApp:new{ plugin = self, session = session }
        UIManager:show(self.app)
        -- After showing: the app records the pre-existing rotation mode first.
        self.app:apply_default_orientation()
    else
        UIManager:show(self.app)
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
function VNCViewer:connect_profile(name, on_failure)
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
function VNCViewer:disconnect_session(name)
    local session = self.sessions[name]
    if not session then return end
    self.sessions[name] = nil
    self:_close_app_if(session)
    session:disconnect()
end

function VNCViewer:_close_app_if(session)
    if self.app and self.app.session == session then
        self.app:restore_rotation()
        UIManager:close(self.app)
        self.app = nil
    end
end

--- Closes the viewer but keeps every connection alive for later pickup.
function VNCViewer:leave_app()
    if self.app then
        self.app:restore_rotation()
        UIManager:close(self.app)
        self.app = nil
    end
    for _, session in pairs(self.sessions) do
        session:detach()
    end
end

-- ---------------------------------------------------------------- profiles

function VNCViewer:save_profile(profile, existing_name)
    local ok, err = self.settings:save_profile(profile, existing_name)
    if not ok then
        logger.warn("vncviewer: could not save profile:", err)
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

function VNCViewer:delete_profile(name)
    if self.sessions[name] then
        self:disconnect_session(name)
    end
    self.settings:delete_profile(name)
    self.settings:flush()
end

return VNCViewer

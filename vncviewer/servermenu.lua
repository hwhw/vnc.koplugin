--[[--
The "VNC server" section of KOReader's Network menu.

A checkable entry that also opens a submenu to start and stop the server and to configure where it
listens (IP address, port) and whether it asks for a password. The layout follows KOReader's own
HTTP inspector plugin, which is the established precedent for a plugin that opens a port (its menu
structure, its status line, its port dialog and its Kindle firewall hole).

@module vncviewer.servermenu
]]

local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local ServerMenu = {}

--- Shows a short message over the menu (used for start failures).
local function report(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 4 })
end

--- A text-entry dialog for one server setting.
local function edit_text(title, hint, value, text_type, on_save)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = tostring(value or ""),
        input_hint = hint,
        text_type = text_type,
        buttons = { {
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("OK"),
                is_enter_default = true,
                callback = function()
                    local text = dialog:getInputValue()
                    UIManager:close(dialog)
                    on_save(text)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--[[--
Adds the server section to the menu table.

--- @tparam table plugin the @{main} plugin instance (it owns the server and the settings)
--- @tparam table menu_items the table `addToMainMenu` was given
]]
function ServerMenu.register(plugin, menu_items)
    local function server_settings()
        return plugin.settings:server()
    end

    local function restart_if_running()
        local server = plugin.server
        if server and server:is_running() then
            local ok, err = server:start()      -- start() re-binds with the new settings
            if not ok then report(err) end
        end
    end

    menu_items.vncviewer_server = {
        text = _("VNC server"),
        sorting_hint = "network",
        -- The section itself carries the state, the submenu the controls.
        checked_func = function()
            return plugin.server ~= nil and plugin.server:is_running()
        end,
        sub_item_table = {
            {
                text_func = function()
                    if plugin.server and plugin.server:is_running() then
                        return _("Stop VNC server")
                    end
                    return _("Start VNC server")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local server = plugin.server
                    if server:is_running() then
                        server:stop()
                    else
                        local ok, err = server:start()
                        if not ok then
                            report(T(_("Could not start the VNC server: %1"), tostring(err)))
                        end
                    end
                    touchmenu_instance:updateItems()
                end,
            },
            {
                text_func = function()
                    local server = plugin.server
                    if not server:is_running() then
                        return server.last_error and T(_("Not running (%1)"), server.last_error)
                            or _("Not running")
                    end
                    local n = server:client_count()
                    local where = server:status_text()
                    return n > 0 and T(_("Listening on %1 (%2 connected)"), where, n)
                        or T(_("Listening on %1"), where)
                end,
                enabled_func = function()
                    return plugin.server and plugin.server:is_running()
                end,
                separator = true,
            },
            {
                text_func = function()
                    return T(_("IP address: %1"), server_settings().ip)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    edit_text(_("IP address to listen on"), _("0.0.0.0 listens on every interface"),
                        server_settings().ip, nil, function(text)
                            text = text:gsub("^%s+", ""):gsub("%s+$", "")
                            if text == "" then text = "0.0.0.0" end
                            server_settings().ip = text
                            plugin.settings:flush()
                            restart_if_running()
                            touchmenu_instance:updateItems()
                        end)
                end,
            },
            {
                text_func = function()
                    return T(_("Port: %1"), server_settings().port)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    edit_text(_("Set the port"), _("Port number (default is 5900)"),
                        server_settings().port, "number", function(text)
                            local port = tonumber(text)
                            if not port or port < 1 or port > 65535 then
                                return report(T(_("The port must be a number between 1 and %1."), 65535))
                            end
                            local server = plugin.server
                            local was_running = server and server:is_running()
                            if was_running then server:stop() end
                            server_settings().port = math.floor(port)
                            plugin.settings:flush()
                            if was_running then
                                local ok, err = server:start()
                                if not ok then report(err) end
                            end
                            touchmenu_instance:updateItems()
                        end)
                end,
            },
            {
                text_func = function()
                    if server_settings().password ~= "" then
                        return _("Password: set")
                    end
                    return _("Password: not set")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    edit_text(_("Password (empty for none)"),
                        _("Clients must authenticate with this password; empty accepts anybody"),
                        server_settings().password, "password", function(text)
                            server_settings().password = text
                            plugin.settings:flush()
                            restart_if_running()
                            touchmenu_instance:updateItems()
                        end)
                end,
            },
        },
    }
end

return ServerMenu

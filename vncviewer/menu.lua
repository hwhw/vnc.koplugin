--[[--
The in-app menu.

Built fresh on every open, so the checkmarks and the status row always reflect the live
session state.

@module vncviewer.menu
]]

local _ = require("gettext")
local T = require("ffi/util").template

local Device = require("device")
local ConfirmBox = require("ui/widget/confirmbox")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")

local Dialogs = require("vncviewer/dialogs")
local Keysyms = require("vncviewer/keysyms")

local Screen = Device.screen

local MenuBuilder = {}

local ZOOM_CHOICES = {
    { label = _("Fit framebuffer"), value = "fit" },
    { label = "25%", value = 0.25 },
    { label = "50%", value = 0.5 },
    { label = "75%", value = 0.75 },
    { label = "100%", value = 1 },
    { label = "150%", value = 1.5 },
    { label = "200%", value = 2 },
    { label = "400%", value = 4 },
}

local ROTATIONS = {
    { label = _("Portrait"), mode = 0 },
    { label = _("Landscape"), mode = 1 },
    { label = _("Portrait inverted"), mode = 2 },
    { label = _("Landscape inverted"), mode = 3 },
}

local function zoom_label(mode)
    for _i, choice in ipairs(ZOOM_CHOICES) do
        if choice.value == mode then return choice.label end
    end
    return tostring(mode)
end

local function rotation_label(mode)
    for _i, rotation in ipairs(ROTATIONS) do
        if rotation.mode == mode then return rotation.label end
    end
    return tostring(mode)
end

--- Opens the in-app menu for `app`.
--- @tparam table app the @{vncviewer.app} instance
--- @treturn table the Menu
function MenuBuilder.open(app)
    local plugin = app.plugin
    local settings = app.settings
    local session = app.session
    local profile = session:get_profile()
    local remote = session:get_remote()
    local menu

    -- Delegating to the app keeps its menu handle in sync, so a later open_menu() cannot
    -- hand back a widget that is already closed.
    local function close_menu()
        app:close_menu()
    end
    local function action(fn)
        return function()
            close_menu()
            fn()
        end
    end
    -- A failed attempt must come back to a menu, not leave the user staring at the canvas.
    local function back_into_menu() app:open_menu() end

    local item_table = {}

    -- ---- a lost / failed connection: offer a retry right at the top
    if profile and session:get_state() == "error" then
        item_table[#item_table + 1] = {
            text = T(_("Reconnect to %1"), profile.name),
            callback = action(function() plugin:connect_profile(profile.name, back_into_menu) end),
        }
    end

    -- ---- connections
    local connections = {}
    for _, p in ipairs(plugin.settings:profiles()) do
        connections[#connections + 1] = {
            text = p.name,
            mandatory = string.format("%s:%d", p.host, p.port),
            callback = action(function() plugin:connect_profile(p.name, back_into_menu) end),
        }
    end
    connections[#connections + 1] = {
        text = _("New connection…"),
        -- the menu is closed by now, so there is nothing to return to but the canvas
        callback = action(function() Dialogs.edit_profile(plugin, nil, {}) end),
    }
    item_table[#item_table + 1] = { text = _("Connections…"), sub_item_table = connections }

    -- ---- status (not selectable)
    local status
    if not profile then
        status = _("No active session")
    elseif session:get_state() == "error" then
        status = T(_("Connection lost: %1"), tostring(session:get_error()))
    elseif session:get_state() == "connected" and remote then
        status = T(_("Connected to %1 (%2×%3)"), profile.name, remote:get_size())
    else
        status = T(_("Not connected (%1)"), session:get_state())
    end
    item_table[#item_table + 1] = { text = status, select_enabled = false }

    -- ---- zoom
    local zoom_items = {}
    for _i, choice in ipairs(ZOOM_CHOICES) do
        zoom_items[#zoom_items + 1] = {
            text = choice.label,
            mandatory = settings.zoom_mode == choice.value and "✓" or nil,
            callback = action(function()
                app:zoom_to(choice.value)
                plugin.settings:flush()
            end),
        }
    end
    item_table[#item_table + 1] = {
        text = _("Zoom…"),
        sub_item_table = zoom_items,
        mandatory = zoom_label(settings.zoom_mode),
    }

    -- ---- keyboard
    item_table[#item_table + 1] = {
        text = _("Keyboard always visible"),
        mandatory = settings.keyboard_always_visible and "✓" or "-",
        callback = action(function()
            settings.keyboard_always_visible = not settings.keyboard_always_visible
            plugin.settings:flush()
            app:_sync_keyboard()
        end),
    }
    item_table[#item_table + 1] = {
        text = app.vk_visible and _("Hide keyboard") or _("Show keyboard"),
        callback = action(function() app:toggle_keyboard() end),
    }

    -- ---- orientation
    local rotation_items = {}
    for _i, rotation in ipairs(ROTATIONS) do
        rotation_items[#rotation_items + 1] = {
            text = rotation.label,
            mandatory = settings.orientation == rotation.mode and _("default") or nil,
            callback = action(function() app:set_rotation_mode(rotation.mode) end),
        }
    end
    item_table[#item_table + 1] = {
        text = _("Screen orientation"),
        sub_item_table = rotation_items,
        mandatory = rotation_label(Screen:getRotationMode()),
    }
    item_table[#item_table + 1] = {
        text = _("Rotate screen"),
        callback = action(function() app:rotate(1) end),
    }
    item_table[#item_table + 1] = {
        text = _("Use current orientation as default"),
        callback = action(function()
            settings.orientation = Screen:getRotationMode()
            plugin.settings:flush()
        end),
    }

    -- ---- keys the on-screen keyboard does not have
    local function send(keysym)
        return action(function()
            app:send_key(keysym, true)
            app:send_key(keysym, false)
        end)
    end
    item_table[#item_table + 1] = {
        text = _("Send key"),
        sub_item_table = {
            { text = _("Enter"), callback = send(Keysyms.special.Press) },
            { text = _("Tab"), callback = send(Keysyms.special.Tab) },
            { text = _("Esc"), callback = send(Keysyms.special.Back) },
            { text = _("Delete"), callback = send(Keysyms.special.Del) },
        },
    }

    -- ---- session
    item_table[#item_table + 1] = {
        text = _("Disconnect"),
        callback = action(function()
            UIManager:show(ConfirmBox:new{
                text = profile and T(_("Disconnect from %1?"), profile.name) or _("Disconnect?"),
                ok_text = _("Disconnect"),
                dismissable = false,
                ok_callback = function() app:disconnect_session() end,
            })
        end),
    }
    item_table[#item_table + 1] = {
        text = _("Leave (keep connection)"),
        callback = action(function() app:leave() end),
    }

    menu = Menu:new{
        title = profile and T(_("VNC — %1"), profile.name) or _("VNC viewer"),
        item_table = item_table,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        close_callback = function()
            app.menu = nil
            app:_sync_keyboard_later()
        end,
    }
    UIManager:show(menu)
    return menu
end

return MenuBuilder

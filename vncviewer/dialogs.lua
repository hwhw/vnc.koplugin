--[[--
Connection list, profile actions, profile editor and delete confirmation.

Every surface here has an explicit way back, and each one returns to the surface it was
opened from: the list is the root, `profile_actions` goes back to the list, the editor goes
back to whatever opened it, and a failed connection returns to the list instead of dropping
the user out of the plugin. `Menu`, `ButtonDialog` and the editor's own `id = "close"` button
(which `InputDialog:onCloseDialog` invokes for the Back key) all funnel into those callbacks.

@module vncviewer.dialogs
]]

local _ = require("gettext")
local T = require("ffi/util").template

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")

local Dialogs = {}

local DEFAULT_PORT = 5900

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

--[[--
Shows a (new) connection list. `plugin:show_connection_list()` is the way to *go back* to it,
since it also drops a list that is already on screen.

--- @tparam table plugin
--- @tparam[opt] table opts `{ on_close = fn }`
--- @treturn table the Menu that was shown
]]
function Dialogs.open_connection_list(plugin, opts)
    local menu = Dialogs.connection_list(plugin, opts)
    UIManager:show(menu)
    return menu
end

--[[--
The list of saved connections, plus "New connection…" and "Manage connections…".

--- @tparam table plugin
--- @tparam[opt] table opts `{ on_close = fn }`, `on_close` runs when the list is closed
--- @treturn table the Menu (the caller shows it)
]]
function Dialogs.connection_list(plugin, opts)
    opts = opts or {}
    local menu
    -- Where every sub-dialog returns to.
    local function back() plugin:show_connection_list() end

    local profiles = plugin.settings:profiles()
    local item_table = {}
    for _, profile in ipairs(profiles) do
        item_table[#item_table + 1] = {
            text = profile.name,
            mandatory = string.format("%s:%d", profile.host, profile.port),
            callback = function()
                plugin:close_connection_list()
                plugin:connect_profile(profile.name, back)
            end,
        }
    end
    table.insert(item_table, {
        text = _("New connection…"),
        callback = function()
            plugin:close_connection_list()
            Dialogs.edit_profile(plugin, nil, { on_back = back })
        end,
    })
    if #profiles > 0 then
        local manage = {}
        for _, profile in ipairs(profiles) do
            manage[#manage + 1] = {
                text = profile.name,
                callback = function()
                    plugin:close_connection_list()
                    UIManager:show(Dialogs.profile_actions(plugin, profile, { on_back = back }))
                end,
            }
        end
        table.insert(item_table, {
            text = _("Manage connections…"),
            sub_item_table = manage,
        })
    end

    menu = Menu:new{
        title = _("Connections"),
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        item_table = item_table,
        close_callback = opts.on_close,
    }
    return menu
end

--[[--
Connect / Edit / Delete for one connection, with a Back button that returns to `opts.on_back`
(the connection list). Tapping outside, or Back, does the same.

--- @tparam table plugin
--- @tparam table profile
--- @tparam[opt] table opts `{ on_back = fn }`
--- @treturn table the ButtonDialog (the caller shows it)
]]
function Dialogs.profile_actions(plugin, profile, opts)
    opts = opts or {}
    local function back()
        if opts.on_back then opts.on_back() else Dialogs.open_connection_list(plugin) end
    end
    local function reopen_actions()
        UIManager:show(Dialogs.profile_actions(plugin, profile, opts))
    end

    local dialog
    dialog = ButtonDialog:new{
        title = profile.name,
        buttons = {
            { {
                text = _("Connect"),
                callback = function()
                    UIManager:close(dialog)
                    plugin:connect_profile(profile.name, back)
                end,
            } },
            { {
                text = _("Edit"),
                callback = function()
                    UIManager:close(dialog)
                    Dialogs.edit_profile(plugin, profile, { on_back = reopen_actions })
                end,
            } },
            { {
                text = _("Delete"),
                callback = function()
                    UIManager:close(dialog)
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Delete connection %1?"), profile.name),
                        ok_text = _("Delete"),
                        cancel_text = _("Cancel"),
                        dismissable = false,
                        ok_callback = function()
                            plugin:delete_profile(profile.name)
                            back()
                        end,
                        cancel_callback = reopen_actions,
                    })
                end,
            } },
            { {
                text = _("Back"),
                callback = function()
                    UIManager:close(dialog)
                    back()
                end,
            } },
        },
        dismissable = true,
        tap_close_callback = back,
    }
    return dialog
end

--[[--
The connection editor. Cancel (or the Back key, which `InputDialog:onCloseDialog` routes to the
`id = "close"` button) and a successful save both call `opts.on_back`.

--- @tparam table plugin
--- @tparam[opt] table profile profile to edit, or nil to create one
--- @tparam[opt] table opts `{ on_back = fn }`
--- @treturn table the dialog that was shown
]]
function Dialogs.edit_profile(plugin, profile, opts)
    opts = opts or {}
    local dialog
    local function finish(saved)
        UIManager:close(dialog)
        if saved and opts.on_saved then opts.on_saved() end
        if opts.on_back then opts.on_back() end
    end
    local function report(message)
        UIManager:show(InfoMessage:new{ text = message, timeout = 3 })
    end

    dialog = MultiInputDialog:new{
        title = profile and _("Edit connection") or _("New connection"),
        fields = {
            {
                text = profile and profile.name or "",
                hint = _("Name"),
            },
            {
                text = profile and profile.host or "",
                hint = _("Host name or IP address"),
            },
            {
                text = profile and tostring(profile.port) or tostring(DEFAULT_PORT),
                hint = T(_("Port (default %1)"), DEFAULT_PORT),
                input_type = "number",
            },
            {
                text = profile and profile.password or "",
                hint = _("Password (optional)"),
                text_type = "password",
            },
        },
        buttons = { {
            {
                -- `id = "close"` makes this the dialog's cancel action: the Back key and the
                -- title bar's close button both end up here (see InputDialog:onCloseDialog).
                text = _("Cancel"),
                id = "close",
                callback = function() finish(false) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    local name = trim(fields[1])
                    local host = trim(fields[2])
                    local port_text = trim(fields[3])
                    local password = fields[4] or ""

                    if name == "" then
                        return report(_("Please give the connection a name."))
                    end
                    local existing = plugin.settings:get_profile(name)
                    if existing and (not profile or profile.name ~= name) then
                        return report(T(_("A connection named %1 already exists."), name))
                    end
                    if host == "" then
                        return report(_("Please enter a host name or IP address."))
                    end
                    local port = port_text == "" and DEFAULT_PORT or tonumber(port_text)
                    if not port or port < 1 or port > 65535 then
                        return report(T(_("The port must be a number between 1 and %1."), 65535))
                    end

                    plugin:save_profile({
                        name = name,
                        host = host,
                        port = math.floor(port),
                        password = password,
                    }, profile and profile.name or nil)
                    finish(true)
                end,
            },
        } },
        dismissable = false,
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return dialog
end

Dialogs.DEFAULT_PORT = DEFAULT_PORT

return Dialogs

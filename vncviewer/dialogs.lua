--[[--
Connection list, profile editor and delete confirmations.

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
The list of saved connections, plus "New connection…" and "Manage connections…".

--- @tparam table plugin
--- @tparam[opt] table opts `{ on_close = fn }`
--- @treturn table the Menu (call `UIManager:show()` on it)
]]
function Dialogs.connection_list(plugin, opts)
    opts = opts or {}
    local menu
    local profiles = plugin.settings:profiles()
    local item_table = {}
    for _, profile in ipairs(profiles) do
        item_table[#item_table + 1] = {
            text = profile.name,
            mandatory = string.format("%s:%d", profile.host, profile.port),
            callback = function()
                UIManager:close(menu)
                plugin:connect_profile(profile.name)
            end,
        }
    end
    table.insert(item_table, {
        text = _("New connection…"),
        callback = function()
            UIManager:close(menu)
            Dialogs.edit_profile(plugin, nil, opts.on_saved, opts.on_close)
        end,
    })
    if #profiles > 0 then
        local manage = {}
        for _, profile in ipairs(profiles) do
            manage[#manage + 1] = {
                text = profile.name,
                callback = function()
                    UIManager:close(menu)
                    UIManager:show(Dialogs.profile_actions(plugin, profile, opts))
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
Connect / Edit / Delete for one connection.
]]
function Dialogs.profile_actions(plugin, profile, opts)
    opts = opts or {}
    local dialog
    dialog = ButtonDialog:new{
        title = profile.name,
        buttons = {
            { {
                text = _("Connect"),
                callback = function()
                    UIManager:close(dialog)
                    plugin:connect_profile(profile.name)
                end,
            } },
            { {
                text = _("Edit"),
                callback = function()
                    UIManager:close(dialog)
                    Dialogs.edit_profile(plugin, profile, opts.on_saved, opts.on_close)
                end,
            } },
            { {
                text = _("Delete"),
                callback = function()
                    UIManager:close(dialog)
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Delete connection %1?"), profile.name),
                        ok_text = _("Delete"),
                        dismissable = false,
                        ok_callback = function()
                            plugin:delete_profile(profile.name)
                            if opts.on_saved then opts.on_saved() end
                        end,
                        cancel_callback = function()
                            UIManager:show(Dialogs.profile_actions(plugin, profile, opts))
                        end,
                    })
                end,
            } },
        },
        dismissable = false,
    }
    return dialog
end

--[[--
The connection editor. Validates in place: a rejected Save shows a message and leaves the
dialog open.
]]
function Dialogs.edit_profile(plugin, profile, on_saved, on_close)
    local dialog
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
                text = profile and profile.username or "",
                hint = _("User name (optional)"),
            },
            {
                text = profile and profile.password or "",
                hint = _("Password (optional)"),
                text_type = "password",
            },
        },
        buttons = { {
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                    if on_close then on_close() end
                end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    local name = trim(fields[1])
                    local host = trim(fields[2])
                    local port_text = trim(fields[3])
                    local username = fields[4] or ""
                    local password = fields[5] or ""

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
                        username = username,
                        password = password,
                    }, profile and profile.name or nil)
                    UIManager:close(dialog)
                    if on_saved then on_saved() end
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

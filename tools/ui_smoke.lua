#!/usr/bin/env luajit
--[[--
Headless test for the viewer's UI plumbing: the connection dialogs' back-flow and the toolbar's
reflow on rotation.

It drives the real @{vnc.main} plugin, its @{vnc.dialogs} and a real
@{vnc.app} against KOReader's widget stack (no KOReader process and no VNC server are
needed; a profile pointing at a closed port is used to exercise the failure path).

Run it from the KOReader root, with a writable data directory (KOReader wants a `cache/` dir):

  cd /usr/lib/koreader
  PLUGIN=~/.config/koreader/plugins/vnc.koplugin
  KO_HOME=/tmp/vncv_ui_home \
    LUA_PATH="$PLUGIN/?.lua;;" LUA_CPATH="./common/?.so;;" \
    ./luajit "$PLUGIN/tools/ui_smoke.lua"

Prints one `ok - <name>` line per check and exits 0 on success, 1 on the first failure.
]]

dofile("setupkoenv.lua")

local lfs = require("libs/libkoreader-lfs")
local tool_dir = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local plugin_dir = tool_dir .. "/.."

-- The widget stack needs a settings store and a data directory (for its cache).
local data_dir = os.getenv("KO_HOME") or "/tmp/vncv_ui_home"
if lfs.attributes(data_dir, "mode") ~= "directory" then
    lfs.mkdir(data_dir)
end
if lfs.attributes(data_dir .. "/cache", "mode") ~= "directory" then
    lfs.mkdir(data_dir .. "/cache")
end
_G.G_reader_settings = require("luasettings"):open(data_dir .. "/ui_smoke_settings.lua")
_G.G_reader_settings:flush()
_G.G_defaults = require("luasettings"):wrap(dofile("defaults.lua"))

local Device = require("device")
require("document/canvascontext"):init(Device)
local Screen = Device.screen
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")

package.path = plugin_dir .. "/?.lua;" .. package.path

-- ---------------------------------------------------------------- helpers

local failures = 0
local function check(name, fn)
    UIManager._window_stack = {}
    local ok, err = pcall(fn)
    UIManager._window_stack = {}
    if ok then
        print("ok - " .. name)
    else
        failures = failures + 1
        print(string.format("FAIL: %s: %s", name, tostring(err)))
    end
end

local function assert_true(value, message)
    if not value then error(message or "assertion failed", 2) end
end

local function stack()
    local out = {}
    for _, entry in ipairs(UIManager._window_stack) do out[#out + 1] = entry.widget end
    return out
end
local function top() local s = stack() return s[#s] end
local function stack_desc()
    local out = {}
    for _, w in ipairs(stack()) do
        local kind = "other"
        if w.title == "Connections" and w.item_table then kind = "list"
        elseif w.input_fields then kind = "editor"
        elseif w.ok_callback then kind = "confirm"
        elseif w.buttons then kind = "actions"
        elseif w.text then kind = "message" end
        out[#out + 1] = kind
    end
    return table.concat(out, " > ")
end
local function is_list(w) return w ~= nil and w.title == "Connections" and w.item_table ~= nil end
local function is_editor(w) return w ~= nil and w.input_fields ~= nil end
local function is_actions(w)
    return w ~= nil and w.buttons ~= nil and w.ok_callback == nil and w.input_fields == nil
        and w.buttons[1] ~= nil and w.buttons[1][1] ~= nil and w.buttons[1][1].text == "Connect"
end
local function count(pred)
    local n = 0
    for _, w in ipairs(stack()) do if pred(w) then n = n + 1 end end
    return n
end
local function expect_top(pred, what)
    assert_true(pred(top()), string.format("expected %s on top, stack: %s", what, stack_desc()))
end
local function find_button(widget, text)
    for _, row in ipairs(widget.buttons or {}) do
        for _, btn in ipairs(row) do
            if btn.text == text then return btn end
        end
    end
    error(string.format("no %q button in %s", text, stack_desc()), 2)
end
local function find_item(item_table, text)
    for _, item in ipairs(item_table or {}) do
        if item.text == text then return item end
    end
    error(string.format("no %q entry", text), 2)
end
--- Calls a list entry's callback, then runs the menu's own close callback like Menu does.
local function choose(plugin, text)
    find_item(plugin.connection_list.item_table, text).callback()
end
--- Emulates a ConfirmBox button (its callbacks run before it closes, c.f. confirmbox.lua).
local function answer_confirm(confirm, yes)
    if yes then confirm.ok_callback() else confirm.cancel_callback() end
    UIManager:close(confirm)
end

--- Reads a whole file as bytes (for the settings-file identity checks).
local function slurp(path)
    local f = assert(io.open(path, "rb"))
    local content = f:read("*a")
    f:close()
    return content
end

-- ---------------------------------------------------------------- a plugin with two profiles

local plugin_module = assert(dofile(plugin_dir .. "/main.lua"))
plugin_module.name = "vnc"
local settings_path = data_dir .. "/ui_smoke_store.lua"
os.remove(settings_path)
os.remove(settings_path .. ".old")
local plugin = plugin_module:new{ ui = { menu = { registerToMainMenu = function() end } } }
plugin.settings.ls.close = nil -- (the store is a plain object in this test)
local store = plugin.settings
store:save_profile{ name = "good", host = "127.0.0.1", port = 5900 }
store:save_profile{ name = "dead", host = "127.0.0.1", port = 1 } -- nothing listens there
store:flush()
plugin.settings_file = settings_path

-- ---------------------------------------------------------------- checks

check("connection_list_root", function()
    plugin:show_connection_list()
    expect_top(is_list, "the connection list")
    assert_true(plugin.connection_list == top(), "the plugin must track the open list")
    assert_true(count(is_list) == 1, "exactly one list: " .. stack_desc())
    -- every profile is listed, plus the two extras
    local names = {}
    for _, item in ipairs(plugin.connection_list.item_table) do names[#names + 1] = item.text end
    assert_true(#names == 4, "4 entries, got: " .. table.concat(names, ","))
end)

check("editor_cancel_returns_to_list", function()
    plugin:show_connection_list()
    choose(plugin, "New connection…")
    expect_top(is_editor, "the editor")
    assert_true(count(is_list) == 0, "the list must be closed while the editor is up")
    find_button(top(), "Cancel").callback()
    expect_top(is_list, "the list after cancelling the editor")
    assert_true(plugin.connection_list == top(), "the reopened list must be tracked")
    assert_true(count(is_list) == 1, "no stacked lists: " .. stack_desc())
end)

check("editor_save_returns_to_list", function()
    plugin:show_connection_list()
    choose(plugin, "New connection…")
    local editor = top()
    editor.input_fields[1]:setText("fresh")
    editor.input_fields[2]:setText("10.0.0.7")
    editor.input_fields[3]:setText("5901")
    find_button(editor, "Save").callback()
    expect_top(is_list, "the list after saving")
    local saved = store:get_profile("fresh")
    assert_true(saved and saved.host == "10.0.0.7" and saved.port == 5901, "the profile must be saved")
    assert_true(count(is_list) == 1, "no stacked lists: " .. stack_desc())
end)

check("editor_rejects_without_closing", function()
    plugin:show_connection_list()
    choose(plugin, "New connection…")
    local editor = top()
    editor.input_fields[1]:setText("")            -- no name
    find_button(editor, "Save").callback()
    local kept = false
    for _, w in ipairs(stack()) do if w == editor then kept = true end end
    assert_true(kept, "a rejected save must leave the editor open: " .. stack_desc())
    assert_true(count(function(w) return w ~= editor and w.text ~= nil end) == 1,
        "and must say why once: " .. stack_desc())
    UIManager:close(top())                        -- dismiss the message
    find_button(editor, "Cancel").callback()
    expect_top(is_list, "the list after cancelling")
    -- duplicate name is rejected too
    choose(plugin, "New connection…")
    editor = top()
    editor.input_fields[1]:setText("good")
    editor.input_fields[2]:setText("h")
    find_button(editor, "Save").callback()
    kept = false
    for _, w in ipairs(stack()) do if w == editor then kept = true end end
    assert_true(kept, "a duplicate name must leave the editor open")
end)

check("actions_back_returns_to_list", function()
    plugin:show_connection_list()
    find_item(find_item(plugin.connection_list.item_table, "Manage connections…").sub_item_table, "good").callback()
    expect_top(is_actions, "the actions dialog")
    assert_true(count(is_list) == 0, "the list must be closed while the actions dialog is up")
    find_button(top(), "Back").callback()
    expect_top(is_list, "the list after Back")
    assert_true(count(is_list) == 1, "no stacked lists: " .. stack_desc())
end)

check("actions_edit_cancel_returns_to_actions", function()
    plugin:show_connection_list()
    find_item(find_item(plugin.connection_list.item_table, "Manage connections…").sub_item_table, "good").callback()
    find_button(top(), "Edit").callback()
    expect_top(is_editor, "the editor")
    find_button(top(), "Cancel").callback()
    expect_top(is_actions, "the actions dialog after cancelling the editor")
end)

check("delete_confirm_cancel_returns_to_actions", function()
    plugin:show_connection_list()
    find_item(find_item(plugin.connection_list.item_table, "Manage connections…").sub_item_table, "good").callback()
    find_button(top(), "Delete").callback()
    local confirm = top()
    assert_true(confirm.ok_callback and confirm.cancel_callback, "expected a ConfirmBox: " .. stack_desc())
    answer_confirm(confirm, false)
    expect_top(is_actions, "the actions dialog after cancelling the delete")
    assert_true(store:get_profile("good"), "cancel must not delete")
end)

check("delete_confirm_ok_returns_to_list", function()
    plugin:show_connection_list()
    find_item(find_item(plugin.connection_list.item_table, "Manage connections…").sub_item_table, "good").callback()
    find_button(top(), "Delete").callback()
    answer_confirm(top(), true)
    expect_top(is_list, "the list after deleting")
    assert_true(not store:get_profile("good"), "the named profile must be deleted")
    assert_true(store:get_profile("dead"), "the other profile must survive")
    assert_true(plugin.sessions["good"] == nil, "no session for a deleted profile")
    -- put it back for the remaining checks
    store:save_profile{ name = "good", host = "127.0.0.1", port = 5900 }
    store:flush()
end)

check("failed_connect_returns_to_list", function()
    plugin:show_connection_list()
    choose(plugin, "dead")                        -- closed port: connection refused
    expect_top(function(w) return w ~= nil and w.text ~= nil and w.buttons == nil end,
        "the connection error message")
    assert_true(count(is_list) == 1, "the list must be back under the message: " .. stack_desc())
    assert_true(count(function(w) return w.text ~= nil and w.buttons == nil and w.options_stack == nil end) == 1,
        "exactly one error message: " .. stack_desc())
    assert_true(plugin.sessions["dead"] == nil, "a session that never connected must be dropped")
    UIManager:close(top())
    expect_top(is_list, "the list after dismissing the error")
    assert_true(plugin.connection_list == top(), "the list must stay tracked")
    assert_true(count(is_list) == 1, "no stacked lists: " .. stack_desc())
end)

-- ---------------------------------------------------------------- auto connect on start

check("autoconnect_flag_round_trips", function()
    local Settings = require("vnc/settings")
    local path = data_dir .. "/ui_smoke_autoconnect_roundtrip.lua"
    os.remove(path)
    os.remove(path .. ".old")

    -- off by default
    local s = Settings.open(path)
    s:save_profile{ name = "a", host = "h1", port = 5900 }
    s:save_profile{ name = "b", host = "h2", port = 5901 }
    assert_true(s:get_profile("a").autoconnect == false, "a profile defaults to no autoconnect")
    assert_true(s:autoconnect_profile() == nil, "and nothing is flagged")

    -- set it on one profile and write the file
    s:save_profile({ name = "a", host = "h1", port = 5900, autoconnect = true }, "a")
    s:flush()
    assert_true(s:autoconnect_profile().name == "a", "the store reports the flagged profile")
    local on_disk = dofile(path)
    assert_true(on_disk.profiles[1].autoconnect == true, "the flag is written to the settings file")
    assert_true(on_disk.profiles[2].autoconnect == false, "the other profile is written without it")
end)

check("autoconnect_flag_is_kept_by_an_edit_and_cleared_by_another", function()
    -- on the shared store, so the UI checks below can rely on its profiles
    store:set_autoconnect(nil)
    store:save_profile({ name = "good", host = "127.0.0.1", port = 5900, autoconnect = true }, "good")
    assert_true(store:get_profile("good").autoconnect == true, "good is flagged")

    -- an editor that does not know the field must not clear it
    store:save_profile({ name = "good", host = "127.0.0.1", port = 5900 }, "good")
    assert_true(store:get_profile("good").autoconnect == true,
        "an edit that does not mention autoconnect must keep the flag")

    -- flagging another profile clears the first (only one may carry it)
    store:save_profile({ name = "dead", host = "127.0.0.1", port = 1, autoconnect = true }, "dead")
    assert_true(store:get_profile("dead").autoconnect == true, "the new profile is flagged")
    assert_true(store:get_profile("good").autoconnect == false, "and the old one is cleared")

    -- and the file agrees
    store:flush()
    local on_disk = dofile(store.ls.file)
    for _, p in ipairs(on_disk.profiles) do
        if p.name == "dead" then assert_true(p.autoconnect == true, "dead is flagged on disk") end
        if p.name == "good" then assert_true(p.autoconnect == false, "good is clear on disk") end
    end

    store:set_autoconnect(nil)
    store:flush()
end)

check("settings_normalise_keeps_a_single_autoconnect", function()
    -- A hand-edited file may flag several profiles; loading must normalise it down to one.
    local Settings = require("vnc/settings")
    local writeToFile = require("util").writeToFile
    local path = data_dir .. "/ui_smoke_autoconnect_normalise.lua"
    os.remove(path)
    os.remove(path .. ".old")
    writeToFile([==[
{
    ["profiles"] = {
        { ["name"] = "first", ["host"] = "h1", ["port"] = 5900, ["autoconnect"] = true },
        { ["name"] = "second", ["host"] = "h2", ["port"] = 5901, ["autoconnect"] = true },
        { ["name"] = "third", ["host"] = "h3", ["port"] = 5902, ["autoconnect"] = "yes" },
    },
}
]==], path, true, true)

    local s = Settings.open(path)
    assert_true(s.data.profiles[1].autoconnect == true, "the first flagged profile keeps the flag")
    assert_true(s.data.profiles[2].autoconnect == false, "a second one is cleared on load")
    assert_true(s.data.profiles[3].autoconnect == false, "a hand-written non-boolean is not a flag")
    assert_true(s:autoconnect_profile().name == "first", "exactly one profile is flagged")

    s:set_autoconnect("second")
    assert_true(s:autoconnect_profile().name == "second", "setting one moves the flag")
    assert_true(s.data.profiles[1].autoconnect == false, "clearing the previous one")
    s:flush()
    local on_disk = dofile(path)
    assert_true(on_disk.profiles[2].autoconnect == true and on_disk.profiles[1].autoconnect == false,
        "and the single flag is what gets written")
end)

check("actions_toggle_autoconnect_and_list_marks_it", function()
    store:set_autoconnect(nil)
    plugin:show_connection_list()
    local function open_actions()
        find_item(find_item(plugin.connection_list.item_table, "Manage connections…").sub_item_table,
            "good").callback()
    end
    local function listed(name)
        for _, item in ipairs(plugin.connection_list.item_table) do
            if item.text == name or item.text == name .. " (auto connect)" then return item.text end
        end
    end

    assert_true(listed("good") == "good", "an unflagged profile is listed by its name")
    open_actions()
    expect_top(is_actions, "the actions dialog")
    find_button(top(), "Auto connect on start: off").callback()
    assert_true(store:get_profile("good").autoconnect == true, "the toggle must flag the profile")
    expect_top(is_actions, "the actions dialog reopened after the toggle")
    find_button(top(), "Auto connect on start: on")   -- its label must reflect the new state
    find_button(top(), "Back").callback()
    expect_top(is_list, "the list after the toggle")
    assert_true(listed("good") == "good (auto connect)",
        "the list must mark the flagged profile, got " .. tostring(listed("good")))
    assert_true(listed("dead") == "dead", "and leave an unflagged one alone")

    -- toggling off clears it and the marker
    open_actions()
    find_button(top(), "Auto connect on start: on").callback()
    assert_true(store:get_profile("good").autoconnect == false, "toggling off must clear it")
    find_button(top(), "Back").callback()
    assert_true(listed("good") == "good", "the marker must be gone, got " .. tostring(listed("good")))
    plugin:close_connection_list()
    UIManager._window_stack = {}
end)

check("boot_autoconnect_connects_only_the_flagged_profile", function()
    -- The network is stubbed (this is the boot *decision*, not a dial-out).
    store:set_autoconnect(nil)
    local real_connect = plugin.connect_profile
    local calls = {}
    plugin.connect_profile = function(_, name) calls[#calls + 1] = name end
    local ok, err = pcall(function()
        -- nothing flagged: the deferred tick must connect to nothing
        plugin:schedule_autoconnect()
        UIManager:_checkTasks()
        assert_true(#calls == 0, "with nothing flagged the boot must not connect")

        -- flagged: one attempt, for that profile, deferred to the tick
        store:set_autoconnect("good")
        plugin:schedule_autoconnect()
        assert_true(#calls == 0, "the connect must be deferred, not immediate")
        UIManager:_checkTasks()
        assert_true(#calls == 1 and calls[1] == "good",
            "the tick must connect the flagged profile once, got: " .. table.concat(calls, ","))

        -- and it does not re-arm
        UIManager:_checkTasks()
        assert_true(#calls == 1, "a second tick must not connect again")
    end)
    plugin.connect_profile = real_connect
    store:set_autoconnect(nil)
    store:flush()
    if not ok then error(err, 0) end
end)

check("boot_autoconnect_failure_is_reported_like_a_manual_one", function()
    -- "dead" points at a closed port, so the attempt fails deterministically (and locally).
    plugin.sessions = {}
    plugin.app = nil
    store:set_autoconnect("dead")
    local ok, err = pcall(function()
        plugin:schedule_autoconnect()
        UIManager:_checkTasks()
    end)
    store:set_autoconnect(nil)
    store:flush()
    assert_true(ok, "a failed boot connect must not raise: " .. tostring(err))
    local message
    for _, w in ipairs(stack()) do
        if type(w.text) == "string" and w.text:find("Could not connect to dead", 1, true) then
            message = w.text
        end
    end
    assert_true(message ~= nil, "the boot failure must be reported: " .. stack_desc())
    assert_true(plugin.app == nil, "no viewer may be opened on a failed boot connect")
    assert_true(plugin.sessions["dead"] == nil, "a session that never connected must be dropped")
    UIManager:close(top())
    UIManager._window_stack = {}
end)

check("start_with_entry_lands_in_the_submenu_only_while_flagged", function()
    -- The extension point is `sorting_hint = "start_with"`: KOReader's own MenuSorter nests such an
    -- item into the "Start with" submenu (whose id comes from ui/elements/filemanager_menu_order).
    local FileManagerMenu = require("apps/filemanager/filemanagermenu")
    local MenuSorter = require("ui/menusorter")
    local order = require("ui/elements/filemanager_menu_order")

    local function built_menu()
        local menu_items = {
            ["KOMenu:menu_buttons"] = {},
            filemanager_settings = { icon = "appbar.filebrowser" },
            setting = { icon = "appbar.settings" },
            tools = { icon = "appbar.tools" },
            search = { icon = "appbar.search" },
            main = { icon = "appbar.menu" },
            start_with = FileManagerMenu.getStartWithMenuTable({}),
        }
        plugin:addToMainMenu(menu_items)
        -- this scoped probe only has ids for the file-manager menus; drop the plugin's other items
        menu_items.vnc = nil
        menu_items.vnc_server = nil
        return menu_items, MenuSorter:mergeAndSort("filemanager", menu_items, order)
    end
    local function find_start_with(tbl)
        for _, it in pairs(tbl) do
            if type(it) == "table" then
                if it.id == "start_with" then return it end
                -- merged tabs are plain arrays of their items; items may nest via sub_item_table
                local found = find_start_with(it.sub_item_table or it)
                if found then return found end
            end
        end
    end
    local function texts(item)
        local items = item.sub_item_table_func and item.sub_item_table_func() or item.sub_item_table
        local out = {}
        for _, i in ipairs(items) do out[#out + 1] = i.text or (i.text_func and i.text_func()) end
        return out, items
    end
    local function index_of(list, text)
        for i, t in ipairs(list) do if t == text then return i end end
    end

    -- nothing flagged: KOReader's own five entries, and no VNC one
    store:set_autoconnect(nil)
    G_reader_settings:saveSetting("start_with", "filemanager")
    local _mi, built = built_menu()
    local sw = find_start_with(built)
    assert_true(sw ~= nil, "the core Start with submenu must still be there")
    local names = texts(sw)
    assert_true(#names == 5, "the core offers its five entries, got: " .. table.concat(names, ", "))
    assert_true(index_of(names, "VNC auto connect") == nil,
        "with nothing flagged the entry must be absent, got: " .. table.concat(names, ", "))

    -- flagged: the sorter nests the item at the end of the submenu, and it is offered
    store:set_autoconnect("good")
    local _mi2, built2 = built_menu()
    sw = find_start_with(built2)
    local sorted = sw.sub_item_table
    assert_true(sorted[#sorted].text == "VNC auto connect",
        "MenuSorter must nest the entry inside the submenu (last), got: "
        .. tostring(sorted[#sorted].text))
    local entry = sorted[#sorted]
    assert_true(entry.sorting_hint == "start_with", "it carries the documented sorting hint")
    names = texts(sw)
    assert_true(index_of(names, "VNC auto connect") == #names,
        "and it is offered last: " .. table.concat(names, ", "))

    -- the tick/callback: on records the choice, off clears the flag and the choice together
    assert_true(entry.checked_func() == false, "unticked while the stored setting is not ours")
    entry.callback()
    assert_true(G_reader_settings:readSetting("start_with") == plugin.START_WITH,
        "toggling on must store the plugin's value")
    assert_true(store:autoconnect_profile() ~= nil and store:autoconnect_profile().name == "good",
        "and keep the profile flagged")
    assert_true(entry.checked_func() == true, "so it reads as ticked")
    entry.callback()
    assert_true(G_reader_settings:readSetting("start_with") ~= plugin.START_WITH,
        "toggling off must clear the stored choice")
    assert_true(store:autoconnect_profile() == nil, "and the profile flag")
    assert_true(index_of(texts(sw), "VNC auto connect") == nil,
        "and the entry must then be gone from the submenu")

    -- the label: core cannot name our value, the additive wrapper can; the core values still work
    local core_item = FileManagerMenu.getStartWithMenuTable({})
    G_reader_settings:saveSetting("start_with", plugin.START_WITH)
    assert_true(core_item.text_func() == nil,
        "core alone labels our value as nothing (hence the wrapper)")
    assert_true(sw.text_func() == "Start with: VNC auto connect",
        "the wrapper names it, got: " .. tostring(sw.text_func()))
    G_reader_settings:saveSetting("start_with", "history")
    assert_true(sw.text_func() == "Start with: history",
        "and every core value still goes to the core label, got: " .. tostring(sw.text_func()))
    G_reader_settings:saveSetting("start_with", "filemanager")
    store:set_autoconnect(nil)
    store:flush()
end)

check("start_with_naming_us_without_a_flag_is_a_normal_start", function()
    -- KOReader's core only special-cases its own values; our sentinel is not one of them, so a
    -- stale `start_with` leaves it starting in the file browser. The plugin must then do nothing
    -- but log it.
    assert_true(plugin.START_WITH ~= "filemanager" and plugin.START_WITH ~= "last"
        and plugin.START_WITH ~= "history" and plugin.START_WITH ~= "favorites"
        and plugin.START_WITH ~= "folder_shortcuts",
        "our value must be one reader.lua does not know, so it falls back to the file browser")

    store:set_autoconnect(nil)
    G_reader_settings:saveSetting("start_with", plugin.START_WITH)
    local logger = require("logger")
    local real_warn, warned = logger.warn, {}
    logger.warn = function(...) warned[#warned + 1] = table.concat({ ... }, " ") end
    local real_connect = plugin.connect_profile
    local calls = 0
    plugin.connect_profile = function() calls = calls + 1 end
    local ok, err = pcall(function()
        plugin:schedule_autoconnect()
        UIManager:_checkTasks()
    end)
    logger.warn = real_warn
    plugin.connect_profile = real_connect
    G_reader_settings:saveSetting("start_with", "filemanager")
    store:flush()
    assert_true(ok, "a stale start_with must not raise: " .. tostring(err))
    assert_true(calls == 0, "and must not connect anything")
    local named = false
    for _, message in ipairs(warned) do
        if message:find("start_with", 1, true) and message:find(plugin.START_WITH, 1, true) then
            named = true
        end
    end
    assert_true(named, "the stale setting must be logged: " .. table.concat(warned, " | "))
end)

-- ---------------------------------------------------------------- a real viewer widget

--- Builds a shown viewer app with a fake session and plugin (no network involved).
--- @tparam[opt] number plane_w, plane_h the remote plane's size (400x300 by default)
--- @treturn table, table, table the app, its remote plane and a record of what it sent
local function new_app(plane_w, plane_h)
    local ViewerApp = require("vnc/app")
    local Remote = require("vnc/framebuffer")
    local remote = Remote.new(plane_w or 400, plane_h or 300)
    local sent = { pointer = {}, key = {} }
    local app = ViewerApp:new{
        plugin = {
            settings = {
                data = { settings = { orientation = 0, keyboard_always_visible = false,
                                      zoom_mode = "fit", enable_tight = false } },
                profiles = function() return {} end,
                flush = function() end,
            },
            leave_app = function() end,
            disconnect_session = function() end,
            connect_profile = function() end,
        },
        session = {
            get_remote = function() return remote end,
            send_pointer = function(_, x, y, mask)
                sent.pointer[#sent.pointer + 1] = { x = x, y = y, mask = mask }
            end,
            send_key = function(_, keysym, down) sent.key[#sent.key + 1] = { keysym = keysym, down = down } end,
            get_state = function() return "connected" end,
            get_error = function() return nil end,
            get_profile = function() return { name = "test" } end,
        },
    }
    -- Shown the way main.lua shows it: a full-screen widget asks for its own refresh.
    UIManager:show(app, "full")
    return app, remote, sent
end

check("canvas_covers_the_screen", function()
    local app, remote = new_app()
    local size = Screen:getSize()
    assert_true(app.canvas.x == 0 and app.canvas.y == 0,
        string.format("the canvas must start at the top left, got %s", tostring(app.canvas)))
    assert_true(app.canvas.w == size.w and app.canvas.h == size.h,
        string.format("the canvas (%dx%d) must cover the whole screen (%dx%d)",
            app.canvas.w, app.canvas.h, size.w, size.h))
    assert_true(app.top_bar == nil, "there is no permanent toolbar any more")

    -- and it follows a rotation
    local before = { w = app.canvas.w, h = app.canvas.h }
    app:set_rotation_mode((Screen:getRotationMode() + 1) % 4)
    size = Screen:getSize()
    assert_true(app.canvas.w == size.w and app.canvas.h == size.h,
        string.format("after rotation the canvas (%dx%d) must cover the screen (%dx%d)",
            app.canvas.w, app.canvas.h, size.w, size.h))
    assert_true(app.canvas.w ~= before.w or app.canvas.h ~= before.h,
        "the canvas must be re-laid out for the new orientation")
    assert_true(remote.scale > 0, "the view must still be usable")
    app:set_rotation_mode(Screen:getRotationMode())
    app:onCloseWidget()
    remote:free()
end)

check("zoom_modes_follow_the_keyboard", function()
    local app, remote = new_app()
    local size = Screen:getSize()
    local function near(a, b) return math.abs(a - b) < 1e-9 end

    -- the menu offers both fitted modes, under the names users are looking for
    app:open_menu()
    local labels
    for _, item in ipairs(app.menu.item_table) do
        if item.text == "Zoom…" then
            labels = {}
            for _, sub in ipairs(item.sub_item_table) do labels[#labels + 1] = sub.text end
        end
    end
    assert_true(labels ~= nil, "the menu must offer a zoom submenu")
    assert_true(labels[1] == "Fit screen", "the first choice is \"Fit screen\", got " .. tostring(labels[1]))
    assert_true(labels[2] == "Fit (with keyboard)",
        "the second choice is \"Fit (with keyboard)\", got " .. tostring(labels[2]))
    app:close_menu()
    UIManager:_checkTasks()

    app:zoom_to("fit")
    local fit = math.min(size.w / 400, size.h / 300)
    assert_true(near(remote:get_scale(), fit),
        string.format("\"fit screen\" fits the screen: %s", remote:get_scale()))

    app:set_keyboard_visible(true)
    local kbd_h = app.vk:getSize().h
    assert_true(kbd_h > 0, "the keyboard must have a height")

    app:zoom_to("fit_with_keyboard")
    local fit_kbd = math.min(size.w / 400, (size.h - kbd_h) / 300)
    assert_true(near(remote:get_scale(), fit_kbd),
        string.format("\"fit (with keyboard)\" fits the space above the keyboard: %s", remote:get_scale()))
    assert_true(fit_kbd < fit, "which is smaller than fitting the screen here")

    -- it follows the keyboard, which is the point of the mode
    app:set_keyboard_visible(false)
    assert_true(near(remote:get_scale(), fit), "with the keyboard hidden it is a plain fit again")
    app:set_keyboard_visible(true)
    assert_true(near(remote:get_scale(), fit_kbd), "and it shrinks again when the keyboard returns")

    -- a fixed ratio is never touched by the keyboard
    app:zoom_to(0.5)
    assert_true(near(remote:get_scale(), 0.5), "a fixed ratio is applied as-is")
    app:set_keyboard_visible(false)
    app:set_keyboard_visible(true)
    assert_true(near(remote:get_scale(), 0.5), "and the keyboard does not change it")

    app:onCloseWidget()
    remote:free()
end)

check("a_view_that_fits_goes_above_the_keyboard", function()
    local app, remote = new_app()
    local size = Screen:getSize()

    app:set_keyboard_visible(true)
    local kbd_h = app.vk:getSize().h
    assert_true(kbd_h > 0, "the keyboard must have a height")

    -- 50% of the 400x300 plane is 200x150: it fits in the space the keyboard leaves
    app:zoom_to(0.5)
    assert_true(app.canvas.h == size.h - kbd_h,
        string.format("the canvas must be the space above the keyboard, got %d of %d", app.canvas.h, size.h))
    assert_true(remote:get_scale() == 0.5, "placing the view must not change the zoom")
    local dx, dy, dw, dh = remote:rect_to_canvas({ x = 0, y = 0, w = 400, h = 300 }, app.canvas.x, app.canvas.y)
    assert_true(dy >= app.canvas.y and dy + dh <= app.canvas.y + app.canvas.h + 1,
        string.format("the whole remote screen must be above the keyboard: y %d..%d, keyboard at %d",
            dy, dy + dh, app.canvas.y + app.canvas.h))
    assert_true(dx >= 0 and dx + dw <= size.w + 1, "and inside the screen horizontally")

    -- a view that cannot fit there keeps the full canvas
    app:zoom_to(4)
    assert_true(app.canvas.h == size.h, "a view too big for that space spans the screen")

    -- "fit screen" lands there too whenever its scale leaves the room for it
    app:zoom_to("fit")
    local fitted = 300 * remote:get_scale()
    if fitted <= size.h - kbd_h then
        assert_true(app.canvas.h == size.h - kbd_h, "a fitted view that leaves room goes above the keyboard")
    else
        assert_true(app.canvas.h == size.h, "one that does not fills the screen")
    end

    -- a pinch that lands on a fitting zoom is re-placed as well
    app:zoom_to(4)
    assert_true(app.canvas.h == size.h, "at 400% the view spans the screen")
    app:_live_zoom({ pos = { x = 100, y = 100 }, span = 50, start_span = 400 })
    app:onPinch()
    assert_true(remote:get_scale() < 1, "the pinch zoomed out")
    assert_true(app.canvas.h == size.h - kbd_h, "and the view moved above the keyboard")

    -- "fit (with keyboard)" always fits there, by choosing the scale
    app:zoom_to("fit_with_keyboard")
    assert_true(app.canvas.h == size.h - kbd_h, "the keyboard-aware fit uses the space above the keyboard")
    local _dx2, dy2, _dw2, dh2 = remote:rect_to_canvas({ x = 0, y = 0, w = 400, h = 300 },
        app.canvas.x, app.canvas.y)
    assert_true(dy2 >= app.canvas.y and dy2 + dh2 <= app.canvas.y + app.canvas.h + 1,
        "and the whole remote screen is inside it")

    app:onCloseWidget()
    remote:free()
end)

check("keyboard_overlaps_without_rescaling", function()
    local app, remote = new_app()
    local size = Screen:getSize()
    -- a view too big for the space above the keyboard keeps the whole screen: the keyboard
    -- overlays it and the user pans
    app:zoom_to(4)
    local canvas = { w = app.canvas.w, h = app.canvas.h }
    local scale = remote.scale
    local view = { x = remote.view_x, y = remote.view_y }

    app:set_keyboard_visible(true)
    assert_true(app.vk_visible, "the keyboard must be visible")
    assert_true(app.vk:getSize().h > 0, "the keyboard must have a height")
    assert_true(app.canvas.w == canvas.w and app.canvas.h == canvas.h,
        "a view that cannot fit above the keyboard must keep the full canvas")
    assert_true(math.abs(remote.scale - scale) < 1e-9,
        string.format("showing the keyboard must not rescale the view (%s -> %s)", scale, remote.scale))
    assert_true(math.abs(remote.view_x - view.x) < 1e-9 and math.abs(remote.view_y - view.y) < 1e-9,
        "showing the keyboard must not move a view that does not fit above it")

    app:set_keyboard_visible(false)
    assert_true(not app.vk_visible, "the keyboard must hide again")
    assert_true(math.abs(remote.scale - scale) < 1e-9, "hiding it must not rescale either")
    assert_true(app.canvas.h == size.h, "and the canvas covers the screen again")
    app:onCloseWidget()
    remote:free()
end)

check("keyboard_follows_rotation", function()
    local app, remote = new_app()
    app:set_keyboard_visible(true)
    assert_true(app.vk_visible, "the keyboard must be visible")

    -- VirtualKeyboard anchors itself in a BottomContainer sized Screen:getSize() at init time,
    -- and sizes its keys from Screen:getWidth(): both must have been refreshed.
    local container = app.vk[1].dimen
    local size = Screen:getSize()
    assert_true(container.w == size.w and container.h == size.h,
        string.format("the keyboard container (%dx%d) must match the screen (%dx%d)",
            container.w, container.h, size.w, size.h))
    local width_before = app.vk:getSize().w

    app:set_rotation_mode((Screen:getRotationMode() + 1) % 4)
    size = Screen:getSize()
    container = app.vk[1].dimen
    assert_true(container.w == size.w and container.h == size.h,
        string.format("after rotation the keyboard container (%dx%d) must match the screen (%dx%d)",
            container.w, container.h, size.w, size.h))
    assert_true(app.vk:getSize().w ~= width_before,
        "the keyboard must be laid out for the new screen width")
    assert_true(app.vk_visible, "the keyboard must stay visible across a rotation")

    app:set_rotation_mode(Screen:getRotationMode())
    app:set_keyboard_visible(false)
    app:onCloseWidget()
    remote:free()
end)

check("menu_opens_on_swipe_only", function()
    local app, remote, sent = new_app()

    -- no tap zone may exist: the top strip must stay available to the remote desktop
    assert_true(not app:checkRegisterTouchZone("vnc_menu_tap"),
        "there must be no menu tap zone")
    assert_true(not app:checkRegisterTouchZone("vnc_menu_tap_ext"),
        "there must be no menu tap zone")
    assert_true(app:checkRegisterTouchZone("vnc_menu_swipe"),
        "the menu swipe zone must be registered")
    assert_true(app:checkRegisterTouchZone("vnc_menu_swipe_ext"),
        "the extended menu swipe zone must be registered")

    local zone = G_defaults:readSetting("DTAP_ZONE_MENU")
    local size = Screen:getSize()
    local gs_range = app._zones["vnc_menu_swipe"].gs_range
    assert_true(math.abs(gs_range.range.w - size.w * zone.w) < 1,
        "the menu swipe zone must cover KOReader's DTAP_ZONE_MENU width")
    assert_true(math.abs(gs_range.range.h - size.h * zone.h) < 1,
        "the menu swipe zone must cover KOReader's DTAP_ZONE_MENU height")

    -- dispatch: a tap inside that zone must click the remote, not open the menu
    local inside = Geom:new{ x = 10, y = 10 }
    app.menu = nil
    sent.pointer = {}
    app:onGesture({ ges = "tap", pos = inside })
    assert_true(app.menu == nil, "a tap must never open the menu")
    assert_true(#sent.pointer == 3, "a tap in the top zone must click the remote, got "
        .. #sent.pointer .. " pointer events")

    -- dispatch: a south swipe there opens the menu, other directions do not
    app:onGesture({ ges = "swipe", direction = "south", pos = inside })
    assert_true(app.menu ~= nil, "a swipe down in the top zone must open the menu")
    app:close_menu()
    app:onGesture({ ges = "swipe", direction = "north", pos = inside })
    assert_true(app.menu == nil, "only a south swipe opens the menu")

    -- and a tap anywhere else is a click too
    sent.pointer = {}
    app:onGesture({ ges = "tap", pos = Geom:new{ x = 10, y = size.h - 10 } })
    assert_true(#sent.pointer == 3, "a tap below the zone must click the remote")
    assert_true(app.menu == nil, "and must not open the menu")

    app:onCloseWidget()
    remote:free()
end)

check("server_section_is_in_the_network_menu", function()
    -- The plugin's own menu table, as `addToMainMenu` builds it.
    local menu_items = {}
    plugin:addToMainMenu(menu_items)

    assert_true(menu_items.vnc == nil or menu_items.vnc.text == "VNC viewer",
        "the viewer entry stays")
    local section = menu_items.vnc_server
    assert_true(section ~= nil, "a VNC server section must be registered")
    assert_true(section.text == "VNC server", "named \"VNC server\", got " .. tostring(section.text))
    assert_true(section.sorting_hint == "network", "it belongs in the Network menu")
    assert_true(type(section.checked_func) == "function", "it must be checkable")
    assert_true(section.checked_func() == false, "and not checked while the server is stopped")

    local items = section.sub_item_table
    assert_true(type(items) == "table" and #items >= 4, "it must offer a submenu")
    local labels = {}
    for _, item in ipairs(items) do
        labels[#labels + 1] = item.text or (item.text_func and item.text_func())
    end
    local function has(pattern)
        for _, l in ipairs(labels) do
            if type(l) == "string" and l:find(pattern) then return l end
        end
        return nil
    end
    assert_true(has("^Start VNC server$") ~= nil,
        "a start/stop entry, got: " .. table.concat(labels, " | "))
    assert_true(has("^Not running$") ~= nil, "a status line, got: " .. table.concat(labels, " | "))
    assert_true(has("^IP address: 0%.0%.0%.0$") ~= nil,
        "the IP address with its default, got: " .. table.concat(labels, " | "))
    assert_true(has("^Port: 5900$") ~= nil,
        "the port with its default, got: " .. table.concat(labels, " | "))
    assert_true(has("^Password: not set$") ~= nil,
        "the optional password, got: " .. table.concat(labels, " | "))
    assert_true(plugin.settings:server().ip == "0.0.0.0"
        and plugin.settings:server().port == 5900
        and plugin.settings:server().password == "",
        "and the defaults it shows are the stored ones")
end)

check("server_menu_offers_autostart", function()
    -- The entry is a checkbox over the stored setting, and toggling it persists to the file.
    local menu_items = {}
    plugin:addToMainMenu(menu_items)
    local item = find_item(menu_items.vnc_server.sub_item_table, "Start with KOReader")
    assert_true(type(item.checked_func) == "function", "the autostart entry must be a checkbox")

    store.data.server.autostart = false
    assert_true(item.checked_func() == false, "the item must show the stored setting (off by default)")

    item.callback({ updateItems = function() end })
    assert_true(store.data.server.autostart == true, "toggling must set the stored setting")
    assert_true(item.checked_func() == true, "and the item must then show it")
    local persisted = dofile(store.ls.file)
    assert_true(persisted.server.autostart == true,
        "the toggle must have been flushed to the settings file")

    item.callback({ updateItems = function() end })
    assert_true(store.data.server.autostart == false, "and toggling again clears it")
    persisted = dofile(store.ls.file)
    assert_true(persisted.server.autostart == false, "which is flushed too")
end)

check("server_environment_rules", function()
    -- The parsing seam: a lookup function stands in for os.getenv, so every documented rule can be
    -- exercised without touching the real environment.
    local Settings = require("vnc/settings")
    local E = Settings.ENV
    local function read(map)
        return Settings.read_env(function(name) return map[name] end)
    end

    -- enable: unset, set-but-empty and whitespace-only all mean "no opinion"
    for _, map in ipairs({ {}, { [E.enable] = "" }, { [E.enable] = "   " } }) do
        assert_true(read(map).enable == nil, "an empty enable variable must mean no opinion")
    end
    -- the disable words, trimmed and case-insensitive
    for _, word in ipairs({ "0", "no", "false", " NO ", "False" }) do
        assert_true(read({ [E.enable] = word }).enable == false,
            string.format("enable=%q must mean do not start", word))
    end
    -- anything else non-empty means start
    for _, word in ipairs({ "1", "yes", "true", "anything", " no! " }) do
        assert_true(read({ [E.enable] = word }).enable == true,
            string.format("enable=%q must mean start", word))
    end

    -- host: empty/unset leave the stored value; otherwise the trimmed address
    assert_true(read({}).host == nil and read({ [E.host] = "" }).host == nil
        and read({ [E.host] = "  " }).host == nil, "an empty host must mean no opinion")
    assert_true(read({ [E.host] = " 10.0.0.9 " }).host == "10.0.0.9", "the host is trimmed")

    -- port: an integer in range, else ignored (and warned about, never applied)
    assert_true(read({ [E.port] = "5901" }).port == 5901, "a valid port is applied")
    assert_true(read({ [E.port] = " 5902 " }).port == 5902, "surrounding space is tolerated")
    assert_true(read({ [E.port] = "1" }).port == 1 and read({ [E.port] = "65535" }).port == 65535,
        "the ends of the range are valid")
    local logger = require("logger")
    local real_warn, warned = logger.warn, {}
    logger.warn = function(...) warned[#warned + 1] = table.concat({ ... }, " ") end
    local ok, err = pcall(function()
        for _, value in ipairs({ "0", "65536", "70000", "abc", "5900.5", "" }) do
            assert_true(read({ [E.port] = value }).port == nil,
                string.format("port=%q must be ignored", value))
        end
    end)
    logger.warn = real_warn
    if not ok then error(err) end
    assert_true(#warned == 6, "each invalid port must be warned about, got " .. #warned)
    for _, message in ipairs(warned) do
        assert_true(message:find("VNC_KOPLUGIN_SERVER_PORT", 1, true) ~= nil,
            "the warning must name the variable: " .. message)
    end

    -- password: set-but-empty is a meaningful "no password", kept verbatim
    assert_true(read({}).password == nil, "an unset password must mean no opinion")
    assert_true(read({ [E.password] = "" }).password == "",
        "an empty password must be kept as an override")
    assert_true(read({ [E.password] = " with space " }).password == " with space ",
        "a password must not be trimmed")

    -- all four variables at once
    local all = read({ [E.enable] = "1", [E.host] = "10.0.0.9", [E.port] = "5999", [E.password] = "pw" })
    assert_true(all.enable == true and all.host == "10.0.0.9" and all.port == 5999
        and all.password == "pw", "the four variables are read together")
end)

check("server_environment_overrides_the_stored_settings", function()
    local Settings = require("vnc/settings")
    local E = Settings.ENV
    local function env(map) return function(name) return map[name] end end
    local path = data_dir .. "/ui_smoke_env_precedence.lua"
    os.remove(path)
    os.remove(path .. ".old")

    -- stored: do not autostart, listen on 127.0.0.1:5901 with a password
    local s = Settings.open(path)
    s.data.server.ip, s.data.server.port = "127.0.0.1", 5901
    s.data.server.password, s.data.server.autostart = "stored", false
    s:flush()

    -- no environment at all: the stored setting decides and the stored table is used as-is
    local plain = Settings.open(path)
    assert_true(plain:should_autostart() == false, "without the environment the stored setting decides")
    assert_true(plain:server_for_run() == plain.data.server,
        "without overrides the running server shares the stored table")

    -- a set-but-empty enable variable is no opinion: the stored setting still decides
    local blank = Settings.open(path, env({ [E.enable] = "" }))
    assert_true(blank:should_autostart() == false,
        "an empty enable variable leaves the stored setting in charge")
    s.data.server.autostart = true
    s:flush()
    assert_true(Settings.open(path, env({ [E.enable] = "" })):should_autostart() == true,
        "and the stored setting can turn it on")

    -- the environment decides regardless of the stored setting
    assert_true(Settings.open(path, env({ [E.enable] = "1" })):should_autostart() == true,
        "enable=1 starts with the stored setting on")
    s.data.server.autostart = false
    s:flush()
    assert_true(Settings.open(path, env({ [E.enable] = "1" })):should_autostart() == true,
        "enable=1 starts even with the stored setting off")
    assert_true(Settings.open(path, env({ [E.enable] = "0" })):should_autostart() == false,
        "enable=0 does not start")
    s.data.server.autostart = true
    s:flush()
    assert_true(Settings.open(path, env({ [E.enable] = "no" })):should_autostart() == false,
        "enable=no does not start even with the stored setting on")

    -- host/port/password overrides are merged into the run, the stored values untouched
    local run = Settings.open(path, env({
        [E.host] = "10.9.8.7", [E.port] = "6001", [E.password] = "envsecret",
    }))
    local effective = run:server_for_run()
    assert_true(effective.ip == "10.9.8.7" and effective.port == 6001
        and effective.password == "envsecret", "the run must see the environment values")
    assert_true(effective ~= run.data.server, "the run must not get the stored table itself")
    assert_true(run.data.server.ip == "127.0.0.1" and run.data.server.port == 5901
        and run.data.server.password == "stored", "the stored values must be untouched")

    -- an empty password override really means "no password"; the other fields stay stored
    local no_pw = Settings.open(path, env({ [E.password] = "" })):server_for_run()
    assert_true(no_pw.password == "" and no_pw.ip == "127.0.0.1" and no_pw.port == 5901,
        "an empty password is applied while the other stored values stay")
end)

check("server_environment_is_not_persisted", function()
    local Settings = require("vnc/settings")
    local E = Settings.ENV
    local path = data_dir .. "/ui_smoke_env_store.lua"
    os.remove(path)
    os.remove(path .. ".old")

    -- a canonical file, written the way the plugin writes it
    local s = Settings.open(path)
    s.data.server.ip, s.data.server.port = "127.0.0.1", 5901
    s.data.server.password, s.data.server.autostart = "stored", false
    s:flush()
    local before = slurp(path)

    -- reopen with a full set of overrides and force a flush (what an exit-time save does)
    local run = Settings.open(path, function(name)
        return ({ [E.enable] = "1", [E.host] = "10.9.8.7",
                  [E.port] = "6001", [E.password] = "envsecret" })[name]
    end)
    assert_true(run:server_for_run().password == "envsecret", "the overrides are in effect for the run")
    run:flush()
    assert_true(slurp(path) == before,
        "a flush after the overrides must leave the settings file byte-identical")

    -- and nothing must have leaked into the stored table either
    local reloaded = Settings.open(path)
    assert_true(reloaded.data.server.ip == "127.0.0.1" and reloaded.data.server.port == 5901
        and reloaded.data.server.password == "stored" and reloaded.data.server.autostart == false,
        "the file still holds the stored values")
end)

check("server_autostart_starts_once_the_tick_runs", function()
    local socket = require("socket")
    local probe = assert(socket.bind("127.0.0.1", 0))
    local _, port = probe:getsockname()
    probe:close()

    local server_settings = store.data.server
    local saved = { ip = server_settings.ip, port = server_settings.port,
                    password = server_settings.password, autostart = server_settings.autostart,
                    env = plugin.settings.env }
    server_settings.ip = "127.0.0.1"
    server_settings.port = port
    server_settings.password = ""
    plugin.settings.env = {}

    local ok, err = pcall(function()
        -- off: the deferred tick starts nothing
        server_settings.autostart = false
        plugin:schedule_autostart()
        UIManager:_checkTasks()
        assert_true(not plugin.server:is_running(), "with autostart off nothing may start")

        -- on: the start is deferred to the next UI loop turn, and then it happens
        server_settings.autostart = true
        plugin:schedule_autostart()
        assert_true(not plugin.server:is_running(), "the start must be deferred, not immediate")
        UIManager:_checkTasks()
        assert_true(plugin.server:is_running(), "the next tick must start the server")
        assert_true(plugin.server:status_text() == "127.0.0.1:" .. port,
            "it must listen where the settings say, got " .. tostring(plugin.server:status_text()))

        -- and it does not re-arm: a manual stop stays a stop
        plugin.server:stop()
        UIManager:_checkTasks()
        assert_true(not plugin.server:is_running(), "a manual stop must not be undone")

        -- the environment decides too, with the stored setting off
        server_settings.autostart = false
        plugin.settings.env = { enable = true }
        plugin:schedule_autostart()
        UIManager:_checkTasks()
        assert_true(plugin.server:is_running(), "the environment must be able to start it")
        plugin.server:stop()
        UIManager:_checkTasks()
        assert_true(not plugin.server:is_running(), "and it stops again")

        -- a boot start that cannot bind is warned about and left in the server's state
        local holder = assert(socket.bind("127.0.0.1", 0))
        server_settings.port = select(2, holder:getsockname())
        server_settings.autostart = true
        plugin.settings.env = {}
        local logger = require("logger")
        local real_warn, warned = logger.warn, 0
        logger.warn = function() warned = warned + 1 end
        local started, start_err = pcall(function()
            plugin:schedule_autostart()
            UIManager:_checkTasks()
        end)
        logger.warn = real_warn
        holder:close()
        if not started then error(start_err) end
        assert_true(not plugin.server:is_running(), "a start that cannot bind must not report running")
        assert_true(plugin.server.last_error ~= nil,
            "the failure must be visible in the server state (the menu's status line)")
        assert_true(warned >= 1, "a failed boot start must be logged as a warning")
    end)

    if plugin.server:is_running() then plugin.server:stop() end
    plugin.server.last_error = nil
    server_settings.ip, server_settings.port = saved.ip, saved.port
    server_settings.password, server_settings.autostart = saved.password, saved.autostart
    plugin.settings.env = saved.env
    if not ok then error(err, 0) end
end)

check("settings_file_is_kept_in_shape", function()
    -- There is no schema version and no migration; the store still has to survive a file that a
    -- user edited by hand (or that does not exist yet). `LuaSettings` caches one instance per
    -- path (and flushing on close would overwrite the file), so each case gets its own path.
    local Settings = require("vnc/settings")
    local writeToFile = require("util").writeToFile   -- (data, path, force_flush, lua_dofile_ready)

    local fresh = data_dir .. "/ui_smoke_settings_fresh.lua"
    local s = Settings.open(fresh)
    assert_true(s.data.settings.zoom_mode == "fit", "a fresh install gets the defaults")
    assert_true(type(s.data.profiles) == "table" and #s.data.profiles == 0, "and no profiles")

    local junk = data_dir .. "/ui_smoke_settings_junk.lua"
    -- (`lua_dofile_ready` makes writeToFile add the `return`, so the content is the table itself)
    writeToFile([==[
-- hand-edited, with junk in it
{
    ["settings"] = { ["zoom_mode"] = "fit_with_keyboard", ["bogus"] = 1 },
    ["profiles"] = {
        { ["name"] = "ok", ["host"] = "h", ["port"] = 5901, ["password"] = "p" },
        { ["host"] = "no name" },
        "not a table",
    },
    ["settings_version"] = 1,
}
]==], junk, true, true)
    s = Settings.open(junk)
    assert_true(s.data.settings.zoom_mode == "fit_with_keyboard", "the settings that are there survive")
    assert_true(s.data.settings.bogus == nil, "unknown settings are dropped")
    assert_true(s.data.settings_version == nil, "so are unknown top-level keys")
    assert_true(#s.data.profiles == 1, "only the usable profiles are kept")
    local profile = s.data.profiles[1]
    assert_true(profile.name == "ok" and profile.host == "h" and profile.port == 5901
        and profile.password == "p", "and they keep their fields")

    local empty = data_dir .. "/ui_smoke_settings_empty.lua"
    writeToFile("{}\n", empty, true, true)
    s = Settings.open(empty)
    assert_true(s.data.settings.zoom_mode == "fit" and #s.data.profiles == 0,
        "an empty file is filled in rather than breaking the viewer")
end)

check("keyboard_yields_to_popups", function()
    -- The keyboard belongs to the framebuffer view: a menu or dialog above it takes it out of the
    -- way, and it comes back when that popup is gone.
    local app, remote = new_app()
    app.settings.keyboard_always_visible = true
    app:set_keyboard_visible(true)
    assert_true(app.vk_visible, "with the setting on the keyboard covers the framebuffer")

    app:open_menu()
    assert_true(not app.vk_visible, "opening the menu must hide the keyboard")
    assert_true(app:is_keyboard_wanted(), "without forgetting that it was asked for")
    UIManager:_checkTasks()
    assert_true(not app.vk_visible, "and it must stay hidden while the menu is open")

    -- the menu's own keyboard item must describe the wish, not the state the menu just forced
    local label
    for _, item in ipairs(app.menu.item_table) do
        if item.text == "Hide keyboard" or item.text == "Show keyboard" then label = item.text end
    end
    assert_true(label == "Hide keyboard", "the item must still offer to hide it, got " .. tostring(label))

    app:close_menu()
    UIManager:_checkTasks()
    assert_true(app.vk_visible, "closing the menu must bring the keyboard back")

    -- any popup above the view, ours or not
    local InfoMessage = require("ui/widget/infomessage")
    local dialog = InfoMessage:new{ text = "dialog" }
    UIManager:show(dialog)
    app:_sync_keyboard_later()                 -- what the repaint watcher does when a popup appears
    UIManager:_checkTasks()
    assert_true(not app.vk_visible, "a dialog above the view must hide the keyboard")

    UIManager:close(dialog)
    app:_sync_keyboard_later()
    UIManager:_checkTasks()
    assert_true(app.vk_visible, "and closing it must bring the keyboard back")

    -- "Hide keyboard" has to work even with the setting on, or the item would lie
    app:open_menu()
    app:toggle_keyboard()
    assert_true(not app.settings.keyboard_always_visible, "the setting must follow the user's wish")
    assert_true(not app:is_keyboard_wanted(), "and the wish is recorded")
    assert_true(not app.vk_visible, "still hidden while the menu is open")
    app:close_menu()
    UIManager:_checkTasks()
    assert_true(not app.vk_visible, "and hidden after the menu closes")

    -- leaving the viewer never resurrects the keyboard over whatever comes next
    app.settings.keyboard_always_visible = true
    app:evaluate_keyboard()
    assert_true(app.vk_visible, "the setting on again")
    local popup = InfoMessage:new{ text = "after the viewer" }
    app:onCloseWidget()
    UIManager:show(popup)
    app:_sync_keyboard_later()
    UIManager:_checkTasks()
    assert_true(not app.vk:isVisible(), "no keyboard may appear after the viewer closed")
    UIManager:close(popup)

    remote:free()
end)

check("menu_keyboard_items_work", function()
    -- A real tap goes through Menu:onMenuSelect, which runs the item callback *and* the menu's
    -- close callback; the latter used to switch the keyboard off again right after the item
    -- had switched it on.
    local app, remote = new_app()
    local function choose_menu_item(text)
        app:open_menu()
        local menu = app.menu
        for _, item in ipairs(menu.item_table) do
            if item.text == text then
                menu:onMenuSelect(item)
                UIManager:_checkTasks()   -- run the deferred keyboard sync
                return
            end
        end
        local have = {}
        for _i, item in ipairs(menu.item_table) do have[#have + 1] = tostring(item.text) end
        error(string.format("no %q menu item, only: %s", text, table.concat(have, ", ")))
    end

    assert_true(not app.vk_visible, "the keyboard starts hidden")
    choose_menu_item("Show keyboard")
    assert_true(app.menu == nil, "choosing an item closes the menu")
    assert_true(app.vk_visible, "\"Show keyboard\" must leave the keyboard shown")

    choose_menu_item("Hide keyboard")
    assert_true(not app.vk_visible, "\"Hide keyboard\" must leave it hidden")

    -- with the setting on, the keyboard survives a menu round trip. (The item is labelled
    -- "Hide keyboard" throughout: it describes the wish, not the state the open menu forces.)
    app.settings.keyboard_always_visible = true
    app:set_keyboard_visible(true)
    app:open_menu()
    assert_true(not app.vk_visible, "the menu hides the keyboard while it is open")
    app:close_menu()
    UIManager:_checkTasks()
    assert_true(app.vk_visible, "the setting must bring it back when the menu closes")

    app.settings.keyboard_always_visible = false
    app:set_keyboard_visible(false)
    assert_true(not app.vk_visible, "and it can be hidden again once the setting is off")

    app:onCloseWidget()
    remote:free()
end)

check("text_input_reaches_the_remote", function()
    -- SDL 3 only delivers SDL_EVENT_TEXT_INPUT after SDL_StartTextInput() ("not received by
    -- default"), and KOReader's input widgets are the only core callers of it. The viewer must
    -- therefore enable it itself, or typing on a hardware keyboard reaches nobody.
    local started, stopped = 0, 0
    local original_start, original_stop = Device.startTextInput, Device.stopTextInput
    Device.startTextInput = function() started = started + 1 end
    Device.stopTextInput = function() stopped = stopped + 1 end

    local ok, err = pcall(function()
        local app, remote, sent = new_app()
        assert_true(started == 1, "showing the viewer must enable platform text input")
        assert_true(stopped == 0, "and must not disable it")

        -- What SDL 3's backend does afterwards: the device's SDL event handler turns
        -- SDL_EVENT_TEXT_INPUT into a TextInput event for the widget stack.
        local SDL_EVENT_TEXT_INPUT = 0x303
        Device.input:handleSdlEv({ code = SDL_EVENT_TEXT_INPUT, value = "hi" })
        assert_true(#sent.key == 4, "typing must reach the remote, got " .. #sent.key .. " key events")
        assert_true(sent.key[1].keysym == 0x68 and sent.key[1].down == true, "h down")
        assert_true(sent.key[2].keysym == 0x68 and sent.key[2].down == false, "h up")
        assert_true(sent.key[3].keysym == 0x69 and sent.key[4].keysym == 0x69, "i down/up")

        -- the second character set: a real keypress must not re-enable it over and over
        Device.input:handleSdlEv({ code = SDL_EVENT_TEXT_INPUT, value = "A" })
        assert_true(started == 1, "text input must be asserted once, not per key")
        sent.key = {}
        app:onKeyPress(require("device/key"):new("Left", {}))
        assert_true(started == 1, "and a key event must not re-assert it either")
        assert_true(#sent.key == 1, "while still forwarding the key")

        -- one of our own dialogs (a text field) turns it off: we must get it back
        Device.stopTextInput()                      -- as InputText:onCloseWidget would
        assert_true(stopped == 1, "the simulated dialog turned text input off")
        app:reassert_text_input()
        assert_true(started == 2, "a closed dialog must lead to a re-assert")

        sent.key = {}
        Device.input:handleSdlEv({ code = SDL_EVENT_TEXT_INPUT, value = "ok" })
        assert_true(#sent.key == 4, "and typing must work again")

        -- closing the viewer hands text input back
        app:onCloseWidget()
        assert_true(stopped == 2, "closing the viewer must disable platform text input again")
        remote:free()
    end)

    Device.startTextInput, Device.stopTextInput = original_start, original_stop
    if not ok then error(err) end
end)

check("keys_forward_to_the_remote", function()
    local Key = require("device/key")
    local app, remote, sent = new_app()
    assert_true(Device:hasKeyboard(), "this check is about devices that have a keyboard")

    local function press(name)
        sent.key = {}
        app:onKeyPress(Key:new(name, {}))
        app:onKeyRelease(Key:new(name, {}))
        local out = {}
        for _, e in ipairs(sent.key) do
            out[#out + 1] = string.format("%s0x%X", e.down and "+" or "-", e.keysym)
        end
        return table.concat(out, ",")
    end

    local cases = {
        { "Back", "+0xFF1B,-0xFF1B" },          -- Escape: the remote gets it, we do not leave
        { "Press", "+0xFF0D,-0xFF0D" },         -- Enter
        { "Tab", "+0xFF09,-0xFF09" },
        { "Backspace", "+0xFF08,-0xFF08" },
        { "Left", "+0xFF51,-0xFF51" },
        { "ContextMenu", "+0xFF67,-0xFF67" },   -- the PC "menu" key
        { "F5", "+0xFFC2,-0xFFC2" },
    }
    for _, case in ipairs(cases) do
        local got = press(case[1])
        assert_true(got == case[2], string.format("%s must be forwarded as %s, got %s",
            case[1], case[2], got))
    end

    -- auto-repeat is another press
    sent.key = {}
    app:onKeyRepeat(Key:new("Left", {}))
    assert_true(#sent.key == 1 and sent.key[1].down and sent.key[1].keysym == 0xFF51,
        "a repeated key must be forwarded as a press")

    -- the Menu key is ours: it must not be sent, and it opens the menu
    sent.key = {}
    app:onKeyPress(Key:new("Menu", {}))
    assert_true(#sent.key == 0, "the Menu key must not be forwarded")
    assert_true(app.menu ~= nil, "the Menu key must open the menu")
    app:onKeyPress(Key:new("Menu", {}))
    assert_true(app.menu == nil, "the Menu key must close it again")
    app:onKeyRelease(Key:new("Menu", {}))
    assert_true(#sent.key == 0, "the Menu key release must not be forwarded either")

    -- on a device without a keyboard, Back leaves the viewer instead
    local left = false
    app.plugin.leave_app = function() left = true end
    app:onKeyPress(Key:new("Back", {}))
    assert_true(not left, "with a keyboard, Escape must not leave the viewer")
    local original = Device.hasKeyboard
    Device.hasKeyboard = function() return false end
    app:onKeyPress(Key:new("Back", {}))
    Device.hasKeyboard = original
    assert_true(left, "without a keyboard, Back must leave the viewer")

    app:onCloseWidget()
    remote:free()
end)

-- ---------------------------------------------------------------- the panel: what a refresh reaches

--[=[--
An e-ink panel, modelled.

A panel is a physical medium: a pixel only changes where a refresh asked for it, no matter what was
painted into `Screen.bb` in between. That is precisely the difference the viewer has to respect (and
the reason a full-screen widget must ask for the refresh it needs), so these checks compare the panel
against the framebuffer after every step.

Every kind of refresh ends up in `Screen:refreshFullImp` on the emulator too (the base class routes
them all there), so one hook sees them all.
]=]
local bb = require("ffi/blitbuffer")
local Widget = require("ui/widget/widget")
local panel, refresh_log
local real_refresh_full_imp = Screen.refreshFullImp
function Screen:refreshFullImp(x, y, w, h, dither)
    if panel then
        local bx, by, bw, bh = self.bb:getBoundedRect(x, y, w, h)
        refresh_log[#refresh_log + 1] = { x = bx, y = by, w = bw, h = bh }
        panel:blitFrom(self.bb, bx, by, bx, by, bw, bh)
    end
    return real_refresh_full_imp(self, x, y, w, h, dither)
end

--[[--
A blank panel, an empty paint/refresh queue (a fresh screen), and the "home screen" the viewer is
shown over: a full-screen widget with a pattern, so a panel that missed an update is recognisable.
]]
local function fresh_screen()
    local size = Screen:getSize()
    UIManager._window_stack = {}
    UIManager._dirty = {}
    UIManager._refresh_stack = {}
    UIManager._refresh_func_stack = {}
    panel = bb.new(size.w, size.h, Screen.bb:getType())
    refresh_log = {}   -- the hook may run before fresh_screen() is done
    panel:paintRect(0, 0, size.w, size.h, bb.COLOR_WHITE)
    local Home = Widget:extend{ covers_fullscreen = true }
    function Home:paintTo(target, x, y)
        target:paintRect(x, y, self.dimen.w, self.dimen.h, bb.COLOR_WHITE)
        for i = 0, 15 do
            target:paintRect(x, y + i * math.floor(self.dimen.h / 16), self.dimen.w,
                math.max(1, math.floor(self.dimen.h / 32)), bb.COLOR_GRAY_5)
        end
    end
    local home = Home:new{}
    home.dimen = Geom:new{ x = 0, y = 0, w = size.w, h = size.h }
    UIManager:show(home)
    UIManager:forceRePaint()
    refresh_log = {}   -- only what the viewer does from here on is asserted
end

--- A pixel as an independent value. `getPixel` hands back a *reference* into the buffer (LuaJIT
--- allows holding on to `p[0]`), so a value kept across a repaint would follow the repaint instead
--- of remembering it; `getColorRGB32()` builds a fresh one.
local function pixel_at(target, x, y)
    return target:getPixel(x, y):getColorRGB32()
end

--- Pixels the panel never received, i.e. what a user would still be seeing from before.
local function stale_pixels()
    local n = 0
    for py = 0, panel:getHeight() - 1 do
        for px = 0, panel:getWidth() - 1 do
            if pixel_at(panel, px, py) ~= pixel_at(Screen.bb, px, py) then n = n + 1 end
        end
    end
    return n
end

--- True when one of the refreshes applied since the last `refresh_log = {}` covered the screen.
local function flushed_full_screen()
    local size = Screen:getSize()
    for _, r in ipairs(refresh_log) do
        if r.w >= size.w and r.h >= size.h then return true end
    end
    return false
end

check("showing_the_viewer_pushes_the_whole_screen", function()
    fresh_screen()
    local app, remote = new_app()
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0,
        string.format("showing the viewer must reach the panel, %d px never arrived", stale_pixels()))
    assert_true(flushed_full_screen(), "and it must be a full-screen refresh, not a regional one")
    app:onCloseWidget()
    remote:free()
end)

check("a_wholesale_change_repaints_the_panel", function()
    fresh_screen()
    local app, remote = new_app()
    UIManager:forceRePaint()
    app:on_framebuffer_dirty({ x = 0, y = 0, w = 400, h = 300 })
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "a frame must reach the panel")

    -- a zoom changes the whole canvas at once
    refresh_log = {}
    app:zoom_to(0.5)
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "a zoom must leave the panel matching the framebuffer")
    assert_true(flushed_full_screen(), "a zoom is a wholesale change: it has to flash the screen")
    -- ...and the first frame after it carries the new geometry, so it is flashed too
    refresh_log = {}
    app:on_framebuffer_dirty({ x = 0, y = 0, w = 400, h = 300 })
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "the first frame after a zoom must reach the panel")
    assert_true(flushed_full_screen(), "and it is flashed, not blitted region by region")

    -- the keyboard appearing and going away is the same kind of change
    refresh_log = {}
    app:set_keyboard_visible(true)
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "showing the keyboard must not leave the panel behind")
    assert_true(flushed_full_screen(), "nor push it region by region")
    refresh_log = {}
    app:set_keyboard_visible(false)
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "and the same when it goes away again")

    -- a remote desktop resize
    refresh_log = {}
    remote:resize(800, 600)
    app:on_remote_resized()
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "a remote resize must leave the panel matching the framebuffer")
    assert_true(flushed_full_screen(), "a remote resize is a wholesale change as well")

    app:onCloseWidget()
    remote:free()
end)

check("the_menu_lands_on_the_panel", function()
    fresh_screen()
    local app, remote = new_app()
    UIManager:forceRePaint()
    app:zoom_to(1)                    -- 1:1, so a pixel probe below means what it says
    UIManager:forceRePaint()
    local dx, dy = remote:rect_to_canvas({ x = 0, y = 0, w = 400, h = 300 }, app.canvas.x, app.canvas.y)
    app:on_framebuffer_dirty({ x = 0, y = 0, w = 400, h = 300 })
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "the frame must reach the panel")
    local desktop = pixel_at(panel, dx + 5, dy + 5)

    refresh_log = {}
    app:open_menu()
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0,
        string.format("opening the menu must flush the whole screen, %d px are stale", stale_pixels()))
    assert_true(flushed_full_screen(), "a menu over a framebuffer is a wholesale change")
    assert_true(pixel_at(panel, dx + 5, dy + 5) ~= desktop,
        "and the panel has to show the menu, not the desktop")
    assert_true(app.menu.covers_fullscreen == true,
        "the menu must declare that it covers the screen, so the viewer underneath is not repainted")

    refresh_log = {}
    app:close_menu()
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "closing the menu must give the whole screen back to the viewer")
    assert_true(pixel_at(panel, dx + 5, dy + 5) == desktop,
        "and the panel has to show the desktop again")

    app:onCloseWidget()
    remote:free()
end)

check("a_popup_leaves_the_panel_alone_but_not_the_plane", function()
    fresh_screen()
    local app, remote = new_app()
    UIManager:forceRePaint()
    app:zoom_to(1)
    UIManager:forceRePaint()
    local dx, dy = remote:rect_to_canvas({ x = 0, y = 0, w = 400, h = 300 }, app.canvas.x, app.canvas.y)
    local plane = remote:get_plane()
    plane:paintRect(0, 0, 400, 300, bb.COLOR_GRAY_7)
    remote:mark_dirty()
    app:on_framebuffer_dirty({ x = 0, y = 0, w = 400, h = 300 })
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "the frame must reach the panel")

    app:open_menu()
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "the menu must reach the panel")
    local menu_px = pixel_at(panel, dx + 5, dy + 5)
    local flushes = #refresh_log

    -- the server changes the desktop while the menu is up
    local plane_before = pixel_at(plane, 5, 5)
    plane:paintRect(0, 0, 400, 300, bb.COLOR_GRAY_3)
    remote:mark_dirty()
    app:on_framebuffer_dirty({ x = 0, y = 0, w = 400, h = 300 })
    UIManager:forceRePaint()
    assert_true(#refresh_log == flushes, "a popup above us must leave the panel alone")
    assert_true(pixel_at(panel, dx + 5, dy + 5) == menu_px, "so the panel still shows the menu")
    assert_true(pixel_at(plane, 5, 5) ~= plane_before, "but the plane itself must stay current")

    -- and the flash that closing the menu asks for carries that change to the panel
    app:close_menu()
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "closing the menu must flush the whole screen")
    assert_true(pixel_at(panel, dx + 5, dy + 5) ~= menu_px,
        "and the panel must show the change that arrived while the menu was up")

    app:onCloseWidget()
    remote:free()
end)

check("closing_the_viewer_shows_the_home_screen", function()
    fresh_screen()
    local app, remote = new_app()
    UIManager:forceRePaint()
    app:on_framebuffer_dirty({ x = 0, y = 0, w = 400, h = 300 })
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "the viewer must be on the panel")
    local viewer_px = pixel_at(panel, 10, 10)

    -- Leave it with nothing but the viewer's own close path, with the keyboard up: closing the
    -- keyboard queues a refresh of just its own area, and that regional request used to be the last
    -- word on the whole screen (`UIManager:close` refreshes nothing by itself).
    app:set_keyboard_visible(true)
    UIManager:forceRePaint()
    refresh_log = {}
    UIManager:close(app)              -- the plain close: no refreshtype at all
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0,
        string.format("the home screen must reach the panel, %d px never arrived", stale_pixels()))
    assert_true(flushed_full_screen(), "and it must be a full-screen refresh")
    assert_true(pixel_at(panel, 10, 10) ~= viewer_px, "the panel must have moved on from the viewer")
end)

check("leaving_the_viewer_through_the_plugin_restores_the_home_screen", function()
    fresh_screen()
    local app, remote = new_app()
    UIManager:forceRePaint()
    app:on_framebuffer_dirty({ x = 0, y = 0, w = 400, h = 300 })
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "the viewer must be on the panel")
    local viewer_px = pixel_at(panel, 10, 10)

    app:set_keyboard_visible(true)
    UIManager:forceRePaint()
    plugin.sessions = {}
    plugin.app = app                  -- as VNC:_open_app leaves it
    plugin:leave_app()                -- main.lua's own path
    plugin.app = nil
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0,
        string.format("leave_app must leave the home screen on the panel, %d px never arrived", stale_pixels()))
    assert_true(flushed_full_screen(), "leave_app must ask for a full-screen refresh")
    assert_true(pixel_at(panel, 10, 10) ~= viewer_px, "the panel must have moved on from the viewer")
    remote:free()
end)

if failures > 0 then
    print(string.format("%d check(s) failed", failures))
    os.exit(1)
end
print("all checks passed")
os.exit(0)

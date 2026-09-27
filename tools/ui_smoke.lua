#!/usr/bin/env luajit
--[[--
Headless test for the viewer's UI plumbing: the connection dialogs' back-flow and the toolbar's
reflow on rotation.

It drives the real @{vncviewer.main} plugin, its @{vncviewer.dialogs} and a real
@{vncviewer.app} against KOReader's widget stack (no KOReader process and no VNC server are
needed; a profile pointing at a closed port is used to exercise the failure path).

Run it from the KOReader root, with a writable data directory (KOReader wants a `cache/` dir):

  cd /usr/lib/koreader
  PLUGIN=~/.config/koreader/plugins/vncviewer.koplugin
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

-- ---------------------------------------------------------------- a plugin with two profiles

local plugin_module = assert(dofile(plugin_dir .. "/main.lua"))
plugin_module.name = "vncviewer"
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

check("toolbar_reflows_on_rotation", function()
    local Settings = require("vncviewer/settings")
    local ViewerApp = require("vncviewer/app")
    local Remote = require("vncviewer/framebuffer")

    local remote = Remote.new(400, 300)
    local app = ViewerApp:new{
        plugin = {
            settings = { data = { settings = { orientation = 0, keyboard_always_visible = false,
                                               zoom_mode = "fit", enable_tight = false } } },
            leave_app = function() end,
            disconnect_session = function() end,
        },
        session = {
            get_remote = function() return remote end,
            send_pointer = function() end,
            send_key = function() end,
            get_state = function() return "connected" end,
            get_error = function() return nil end,
            get_profile = function() return { name = "t" } end,
        },
    }

    local function row_size()
        -- ButtonTable's container is a VerticalGroup; the button row is its widest child
        local container = app.top_bar[1]
        local best
        for _, child in ipairs(container) do
            local size = child:getSize()
            if size and size.w > 0 and (not best or size.w > best.w) then best = size end
        end
        return best
    end

    -- A ButtonTable sizes its buttons from the screen width at construction time, so after a
    -- rotation the row must have been rebuilt to the *new* width (it used to keep the old one
    -- and get clipped).
    local function expect_matches_screen(tag)
        local size = Screen:getSize()
        local row = row_size()
        assert_true(row.w <= size.w,
            string.format("%s: the toolbar (%d) must fit the screen (%d)", tag, row.w, size.w))
        assert_true(math.abs(row.w - size.w) <= 8,
            string.format("%s: the toolbar (%d) must match the screen width (%d)", tag, row.w, size.w))
        return row.w
    end

    local mode = Screen:getRotationMode()
    local first_w = expect_matches_screen("first orientation")

    app:set_rotation_mode((mode + 1) % 4)
    local rotated_w = expect_matches_screen("rotated")
    local rotated = Screen:getSize()
    assert_true(math.abs(rotated_w - rotated.w) < math.abs(first_w - rotated.w),
        "the toolbar must be rebuilt for the new screen width, not keep the old one")
    assert_true(rotated.w ~= rotated.h, "the rotation must have swapped the logical dimensions")

    app:set_rotation_mode(mode)
    local back_w = expect_matches_screen("back")
    assert_true(back_w == first_w, "rotating back must restore the original toolbar")

    app:onCloseWidget()
    remote:free()
end)

if failures > 0 then
    print(string.format("%d check(s) failed", failures))
    os.exit(1)
end
print("all checks passed")
os.exit(0)

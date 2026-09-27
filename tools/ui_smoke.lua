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

-- ---------------------------------------------------------------- a real viewer widget

--- Builds a shown viewer app with a fake session and plugin (no network involved).
--- @treturn table, table, table the app, its remote plane and a record of what it sent
local function new_app()
    local ViewerApp = require("vncviewer/app")
    local Remote = require("vncviewer/framebuffer")
    local remote = Remote.new(400, 300)
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
    UIManager:show(app)
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

check("keyboard_overlaps_without_rescaling", function()
    local app, remote = new_app()
    local canvas = { w = app.canvas.w, h = app.canvas.h }
    local scale = remote.scale
    local view = { x = remote.view_x, y = remote.view_y }

    app:set_keyboard_visible(true)
    assert_true(app.vk_visible, "the keyboard must be visible")
    assert_true(app.vk:getSize().h > 0, "the keyboard must have a height")
    assert_true(app.canvas.w == canvas.w and app.canvas.h == canvas.h,
        "showing the keyboard must not change the canvas")
    assert_true(math.abs(remote.scale - scale) < 1e-9,
        string.format("showing the keyboard must not rescale the view (%s -> %s)", scale, remote.scale))
    assert_true(math.abs(remote.view_x - view.x) < 1e-9 and math.abs(remote.view_y - view.y) < 1e-9,
        "showing the keyboard must not move the view")

    app:set_keyboard_visible(false)
    assert_true(not app.vk_visible, "the keyboard must hide again")
    assert_true(math.abs(remote.scale - scale) < 1e-9, "hiding it must not rescale either")
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
    assert_true(not app:checkRegisterTouchZone("vncviewer_menu_tap"),
        "there must be no menu tap zone")
    assert_true(not app:checkRegisterTouchZone("vncviewer_menu_tap_ext"),
        "there must be no menu tap zone")
    assert_true(app:checkRegisterTouchZone("vncviewer_menu_swipe"),
        "the menu swipe zone must be registered")
    assert_true(app:checkRegisterTouchZone("vncviewer_menu_swipe_ext"),
        "the extended menu swipe zone must be registered")

    local zone = G_defaults:readSetting("DTAP_ZONE_MENU")
    local size = Screen:getSize()
    local gs_range = app._zones["vncviewer_menu_swipe"].gs_range
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
        error(string.format("no %q menu item", text))
    end

    assert_true(not app.vk_visible, "the keyboard starts hidden")
    choose_menu_item("Show keyboard")
    assert_true(app.menu == nil, "choosing an item closes the menu")
    assert_true(app.vk_visible, "\"Show keyboard\" must leave the keyboard shown")

    choose_menu_item("Hide keyboard")
    assert_true(not app.vk_visible, "\"Hide keyboard\" must leave it hidden")

    -- with the setting on, the keyboard survives a menu round trip
    app.settings.keyboard_always_visible = true
    choose_menu_item("Show keyboard")
    assert_true(app.vk_visible, "with the setting on the keyboard must stay visible")

    -- and a popup that forced it away brings it back when it closes
    local InfoMessage = require("ui/widget/infomessage")
    local popup = InfoMessage:new{ text = "popup" }
    UIManager:show(popup)
    app:set_keyboard_visible(true)                    -- refused: a popup is above us
    assert_true(not app.vk_visible, "a popup must keep our keyboard hidden")
    UIManager:close(popup)
    app:_sync_keyboard_later()
    UIManager:_checkTasks()
    assert_true(app.vk_visible, "closing the popup must bring the keyboard back")

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

if failures > 0 then
    print(string.format("%d check(s) failed", failures))
    os.exit(1)
end
print("all checks passed")
os.exit(0)

--[[--
The on-screen keyboard, wired to the RFB KeyEvent stream.

`VirtualKeyboard` never type-checks its `inputbox`: it just calls 12 methods on it, so a
stub that forwards those calls to @{vncviewer.session} is all the glue that is needed.

Layouts that ship an IME (`zh`, `zh_CN`, `ja`, `ko_KR`, `vi`) export `wrapInputBox()`,
which is written for `InputText`: it proxies methods our stub does not have and buffers
typed characters into IME candidates. For the lifetime of this keyboard we therefore pin
the layout to `en` (restoring the user's choice in @{Keyboard.restore_layout}), so that a
tap always sends exactly the character on the key.

@module vncviewer.keyboard
]]

local Keysyms = require("vncviewer/keysyms")
local Util = require("vncviewer/util")

local Keyboard = {}

-- Saved G_reader_settings values while a keyboard created here is alive.
local saved_layout = nil

local function current_layout_name()
    if G_reader_settings:isFalse("keyboard_remember_layout") then
        return G_reader_settings:readSetting("keyboard_layout_default")
            or G_reader_settings:readSetting("keyboard_layout") or "en"
    end
    return G_reader_settings:readSetting("keyboard_layout")
        or G_reader_settings:readSetting("language") or "en"
end

local function layout_uses_ime(lang)
    local VirtualKeyboard = require("ui/widget/virtualkeyboard")
    local mod = (VirtualKeyboard.lang_to_keyboard_layout or {})[lang] or "en_keyboard"
    local ok, keyboard = pcall(require, "ui/data/keyboardlayouts/" .. mod)
    return ok and type(keyboard) == "table" and keyboard.wrapInputBox ~= nil
end

local function pin_latin_layout()
    local lang = current_layout_name()
    if not layout_uses_ime(lang) then return end
    saved_layout = {
        layout = G_reader_settings:readSetting("keyboard_layout"),
        default = G_reader_settings:readSetting("keyboard_layout_default"),
    }
    G_reader_settings:saveSetting("keyboard_layout", "en")
    if saved_layout.default ~= nil then
        G_reader_settings:saveSetting("keyboard_layout_default", "en")
    end
end

--- Restores the keyboard layout that @{Keyboard.new} pinned. Call once, when the keyboard
--- is destroyed.
function Keyboard.restore_layout()
    if not saved_layout then return end
    local function put(key, value)
        if value == nil then
            G_reader_settings:delSetting(key)
        else
            G_reader_settings:saveSetting(key, value)
        end
    end
    put("keyboard_layout", saved_layout.layout)
    put("keyboard_layout_default", saved_layout.default)
    saved_layout = nil
end

local function press(session, keysym)
    session:send_key(keysym, true)
    session:send_key(keysym, false)
end

--- Builds the inputbox stub the keyboard talks to.
local function make_stub(session, on_height_changed)
    local stub = {
        parent = { onKeyboardHeightChanged = on_height_changed },
    }
    local special = Keysyms.special

    function stub:addChars(chars)
        for _, ch in ipairs(Util.split_chars(chars)) do
            local keysym = Keysyms.from_char(ch)
            if keysym then press(session, keysym) end
        end
    end
    function stub:delChar() press(session, special.Backspace) end
    function stub:delWord() press(session, special.Backspace) end
    function stub:delToStartOfLine() end -- no equivalent single RFB event
    function stub:leftChar() press(session, special.Left) end
    function stub:rightChar() press(session, special.Right) end
    function stub:goToStartOfLine() press(session, special.Home) end
    function stub:goToEndOfLine() press(session, special.End) end
    function stub:upLine() press(session, special.Up) end
    function stub:downLine() press(session, special.Down) end
    function stub:scrollUp() end
    function stub:scrollDown() end

    return stub
end

--[[--
Creates the on-screen keyboard.

--- @tparam table session the @{vncviewer.session} to send key events to
--- @tparam function on_height_changed called when the keyboard height changes
--- @treturn table a ready-to-show VirtualKeyboard (`UIManager:show(vk)`)
]]
function Keyboard.new(session, on_height_changed)
    local VirtualKeyboard = require("ui/widget/virtualkeyboard")
    local stub = make_stub(session, on_height_changed)
    pin_latin_layout()
    local ok, vk = pcall(VirtualKeyboard.new, VirtualKeyboard, { inputbox = stub })
    if not ok then
        Keyboard.restore_layout()
        error(vk)
    end
    return vk
end

return Keyboard

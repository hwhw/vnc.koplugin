--[[--
The full-screen viewer widget.

The remote framebuffer owns the whole screen; the on-screen keyboard is drawn *over* it
(KOReader stacks it above us), so showing the keyboard never rescales the view — pan it if part
of the remote desktop ends up behind the keyboard. The menu is opened by a **swipe down** in
KOReader's own top screen zone (the `DTAP_ZONE_MENU` area); taps are *never* taken away from the
remote desktop, so a single tap means "click over there" everywhere on the screen. Rotations and
screen resizes go through KOReader's generic `SetRotationMode` / `ScreenResize` events, so that
the keyboard is re-laid out for the new dimensions as well.

It is a plain (non-modal) full-screen `InputContainer` flagged `is_always_active`, so that it
keeps receiving gestures even while one of its own popups is on top — hence the
`_input_target()` / `_modal_above()` guards on every canvas gesture.

@module vncviewer.app
]]

local bit = require("bit")
local _ = require("gettext")

local BD = require("ui/bidi")
local BB = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Keyboard = require("vncviewer/keyboard")
local Keysyms = require("vncviewer/keysyms")
local Util = require("vncviewer/util")

local Screen = Device.screen

local band = bit.band

local ViewerApp = InputContainer:extend{
    id = "vncviewer_app",
    name = "VNCViewerApp",
    covers_fullscreen = true, -- UIManager skips painting the widgets underneath us
    modal = false,            -- the keyboard and our dialogs stack above us normally
    disable_double_tap = true,
    is_always_active = true,
    dimen = nil,              -- set in init()
}

-- ---------------------------------------------------------------- init

function ViewerApp:init()
    self.settings = self.plugin.settings.data.settings
    self.dimen = Screen:getSize()
    self.remote = self.session:get_remote()
    self.canvas = nil
    self.vk_visible = false
    self.vk_wanted = false           -- the user's wish, independent of what is on top of us
    self._keyboard_sync_pending = false
    self._keyboard_watch_pending = false
    self.vk = Keyboard.new(self.session, function() self:on_keyboard_height_changed() end)
    self._drag_active = nil
    self._last_pinch_factor = nil
    self._zoom_start_span = nil
    self._vk_screen = self:_screen_signature()

    self:init_menu_zones()
    self:init_gestures()
    self:_reflow()
end

function ViewerApp:_screen_signature()
    local size = Screen:getSize()
    return string.format("%dx%d", size.w, size.h)
end

-- ---------------------------------------------------------------- menu activation

--[[--
Registers the "show the menu" gesture: a **swipe down** inside KOReader's own top menu zone
(`DTAP_ZONE_MENU`, plus its taller middle extension).

Taps are deliberately *not* registered: every single tap must stay a click on the remote
desktop, so the top zone is only taken away from the canvas for that one swipe. This also
ignores KOReader's global *activate menu on* preference on purpose — under "tap only" the menu
would otherwise become unreachable here.
]]
function ViewerApp:init_menu_zones()
    if not Device:isTouchDevice() then return end
    local function zone_ratios(geom)
        return { ratio_x = geom.x, ratio_y = geom.y, ratio_w = geom.w, ratio_h = geom.h }
    end
    local zone = G_defaults:readSetting("DTAP_ZONE_MENU") or { x = 0, y = 0, w = 1, h = 1 / 8 }
    local zone_ext = G_defaults:readSetting("DTAP_ZONE_MENU_EXT")
        or { x = 1 / 4, y = 0, w = 1 / 2, h = 1 / 5 }

    self:registerTouchZones({
        {
            id = "vncviewer_menu_swipe",
            ges = "swipe",
            screen_zone = zone_ratios(zone),
            handler = function(ges) return self:onMenuSwipe(ges) end,
        },
        {
            id = "vncviewer_menu_swipe_ext",
            ges = "swipe",
            screen_zone = zone_ratios(zone_ext),
            overrides = { "vncviewer_menu_swipe" },
            handler = function(ges) return self:onMenuSwipe(ges) end,
        },
    })
end

--- A swipe down in the top menu zone opens the menu; anything else falls through to the canvas.
function ViewerApp:onMenuSwipe(ges)
    if self.menu then return nil end
    if BD.flipDirectionIfMirroredUILayout(ges.direction) ~= "south" then return nil end
    self:open_menu()
    return true
end

--- Opens the menu, or closes it when it is already open.
function ViewerApp:toggle_menu()
    if self.menu then
        self:close_menu()
    else
        self:open_menu()
    end
end

function ViewerApp:init_gestures()
    local function canvas_range() return self:canvas_geom() end
    local function bottom_strip()
        local c = self:canvas_geom()
        return Geom:new{
            x = c.x, y = c.y + math.floor(c.h * 0.85),
            w = c.w, h = math.ceil(c.h * 0.15),
        }
    end
    local function upper_canvas()
        local c = self:canvas_geom()
        return Geom:new{ x = c.x, y = c.y, w = c.w, h = math.floor(c.h * 0.75) }
    end

    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = canvas_range } },
        Hold = { GestureRange:new{ ges = "hold", range = canvas_range } },
        HoldRelease = { GestureRange:new{ ges = "hold_release", range = canvas_range } },
        Pan = { GestureRange:new{ ges = "pan", range = canvas_range } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = canvas_range } },
        TwoFingerPan = { GestureRange:new{ ges = "two_finger_pan", range = canvas_range } },
        TwoFingerPanRelease = { GestureRange:new{ ges = "two_finger_pan_release", range = canvas_range } },
        InwardPan = { GestureRange:new{ ges = "inward_pan", range = canvas_range } },
        OutwardPan = { GestureRange:new{ ges = "outward_pan", range = canvas_range } },
        Pinch = { GestureRange:new{ ges = "pinch", range = canvas_range } },
        Spread = { GestureRange:new{ ges = "spread", range = canvas_range } },
        Rotate = { GestureRange:new{ ges = "rotate", range = canvas_range } },
        KbdShow = { GestureRange:new{ ges = "swipe", direction = "north", range = bottom_strip } },
        KbdHide = { GestureRange:new{ ges = "swipe", direction = "south", range = upper_canvas } },
    }
end

-- ---------------------------------------------------------------- layout

function ViewerApp:getSize()
    return self.dimen
end

--- The canvas is the whole widget: the remote framebuffer gets the full screen, and the
--- on-screen keyboard is drawn over it rather than shrinking it.
function ViewerApp:_layout(x, y)
    x, y = x or 0, y or 0
    local size = self.dimen
    return Geom:new{ x = x, y = y, w = size.w, h = size.h }
end

--- Recomputes the canvas and re-fits the view when the zoom mode asks for it.
function ViewerApp:_reflow()
    self.dimen = Screen:getSize()
    self.canvas = self:_layout()
    if self.remote and self.settings.zoom_mode == "fit" then
        self.remote:fit_view(self.canvas.w, self.canvas.h)
    end
end

--[[--
Re-initialises the on-screen keyboard when the screen dimensions changed.

`VirtualKeyboard` derives its key sizes from `Screen:getWidth()` and builds a bottom-anchored
`BottomContainer` sized `Screen:getSize()` - both *at construction time*. Without this, a
rotation would leave the keyboard laid out (and positioned) for the previous orientation.
]]
function ViewerApp:_refresh_keyboard()
    if not self.vk then return end
    local signature = self:_screen_signature()
    if signature == self._vk_screen then return end
    self.vk:init()
    self._vk_screen = signature
    UIManager:setDirty(self.vk, "ui")
end

--[[--
KOReader's generic screen-size change notification (also broadcast by the device backends).
]]
function ViewerApp:onScreenResize(dimen)
    if dimen then self.dimen = dimen end
    self:_reflow()
    self:_refresh_keyboard()
    self:updateTouchZonesOnScreenResize(self.dimen)
    return false
end

--[[--
KOReader's generic rotation entry point
(`UIManager:broadcastEvent(Event:new("SetRotationMode", mode))`).
]]
function ViewerApp:onSetRotationMode(mode)
    if mode == nil or mode == Screen:getRotationMode() then return nil end
    Screen:setRotationMode(mode)
    self:onScreenResize(Screen:getSize())
    UIManager:onRotation()
    return true
end

function ViewerApp:canvas_geom()
    if self.canvas then return self.canvas end
    local size = self.dimen or Screen:getSize()
    return Geom:new{ x = 0, y = 0, w = size.w, h = size.h }
end

-- ---------------------------------------------------------------- paint

function ViewerApp:paintTo(bb, x, y)
    local size = self:getSize()
    bb:paintRect(x, y, size.w, size.h, BB.COLOR_BLACK)
    self.canvas = self:_layout(x, y)

    -- Read once per paint: Screen.bb is replaced on rotation/resize.
    local dither = Screen.bb:getType() == BB.TYPE_BB8 and Screen.sw_dithering or false
    if not self.remote then
        self.remote = self.session:get_remote()
    end
    if self.remote then
        self.remote:draw_to(bb, self.canvas.x, self.canvas.y, self.canvas.w, self.canvas.h, dither)
    end

end

--[[--
Repaints just the part of the canvas a remote rect landed on.
--- @tparam table rect `{x, y, w, h}` in remote coordinates
]]
function ViewerApp:on_framebuffer_dirty(rect)
    if not self.canvas or not self.remote then return end
    local x, y, w, h = self.remote:rect_to_canvas(rect, self.canvas.x, self.canvas.y)
    local clipped = Util.intersect_rect(
        { x = x, y = y, w = w, h = h },
        { x = self.canvas.x, y = self.canvas.y, w = self.canvas.w, h = self.canvas.h })
    if clipped then
        UIManager:setDirty(self, "ui", Geom:new(clipped))
    end
end

function ViewerApp:on_remote_resized()
    self:_reflow()
    UIManager:setDirty(self, "ui")
end

function ViewerApp:on_bell()
    -- A status blip at the top of the screen, not a dialog: it may share the screen with the
    -- keyboard. ("toast" is also what keeps KOReader stacking it above everything else.)
    UIManager:show(Notification:new{ text = _("Bell"), timeout = 1, toast = true })
end

function ViewerApp:onCloseWidget()
    -- never leave our own menu orphaned on the window stack
    self:close_menu()
    if self._text_input_asserted then
        self._text_input_asserted = false
        Device:stopTextInput()
    end
    UIManager:unschedule(self._watch_keyboard_tick)
    self._keyboard_watch_pending = false
    if self.vk then
        self.vk:hideKeyboard()
        self.vk_visible = false
        self.vk_wanted = false
    end
    Keyboard.restore_layout()
    self.canvas = nil
end

-- ---------------------------------------------------------------- input plumbing

--[[--
True when no other widget is stacked above us, ignoring the virtual keyboard and toasts.

Without this guard a tap our own Menu does not consume would be forwarded to the server as
a pointer click.
]]
function ViewerApp:_input_target()
    local stack = UIManager._window_stack
    for i = #stack, 1, -1 do
        local w = stack[i].widget
        if w == self then return true end
        if not w.toast and w ~= self.vk then return false end
    end
    return false
end

--- True when a popup of ours (menu, dialog) is above us.
function ViewerApp:_modal_above()
    local stack = UIManager._window_stack
    for i = #stack, 1, -1 do
        local w = stack[i].widget
        if w == self then return false end
        if not w.toast and w ~= self.vk then return true end
    end
    return false
end

--- Canvas coordinates -> remote coordinates.
function ViewerApp:_to_remote(px, py)
    local c = self:canvas_geom()
    return self.remote:screen_to_remote(px - c.x, py - c.y)
end

function ViewerApp:send_pointer(x, y, mask)
    self.session:send_pointer(x, y, mask)
end

function ViewerApp:send_key(keysym, down)
    self.session:send_key(keysym, down)
end

-- ---------------------------------------------------------------- canvas gestures

function ViewerApp:onTap(_, ges)
    if not self:_input_target() then return nil end
    local rx, ry = self:_to_remote(ges.pos.x, ges.pos.y)
    -- move, press, release: what a real mouse click looks like on the wire
    self:send_pointer(rx, ry, 0)
    self:send_pointer(rx, ry, 1)
    self:send_pointer(rx, ry, 0)
    return true
end

function ViewerApp:onPan(_, ges)
    if not self:_input_target() then return nil end
    if self._drag_active == nil then
        -- A pan's `relative` is the accumulated delta since the first contact, so this
        -- recovers the exact press position without depending on `start_pos`.
        local rel = ges.relative or { x = 0, y = 0 }
        local rx, ry = self:_to_remote(ges.pos.x - rel.x, ges.pos.y - rel.y)
        self:send_pointer(rx, ry, 1)
        self._drag_active = true
    end
    local rx, ry = self:_to_remote(ges.pos.x, ges.pos.y)
    self:send_pointer(rx, ry, 1)
    return true
end

function ViewerApp:onPanRelease(_, ges)
    if self._drag_active == nil then return nil end
    self._drag_active = nil
    local rx, ry = self:_to_remote(ges.pos.x, ges.pos.y)
    self:send_pointer(rx, ry, 0)
    return true
end

function ViewerApp:onHold(_, ges)
    if not self:_input_target() then return nil end
    local rx, ry = self:_to_remote(ges.pos.x, ges.pos.y)
    self:send_pointer(rx, ry, 4)
    return true
end

function ViewerApp:onHoldRelease(_, ges)
    if not self:_input_target() then return nil end
    local rx, ry = self:_to_remote(ges.pos.x, ges.pos.y)
    self:send_pointer(rx, ry, 0)
    return true
end

function ViewerApp:onTwoFingerPan(_, ges)
    if not self:_input_target() then return nil end
    local rel = ges.relative or { x = 0, y = 0 }
    self.remote:pan_by(-rel.x, -rel.y)
    UIManager:setDirty(self, "fast")
    return true
end

function ViewerApp:onTwoFingerPanRelease(_, ges)
    -- swipe up from the bottom still needs to be able to mean "show keyboard"
    UIManager:setDirty(self, "ui")
    return true
end

function ViewerApp:_live_zoom(ges)
    if not self:_input_target() then return nil end
    local span = ges.span or 0
    local start_span = ges.start_span or 0
    if start_span <= 0 then return nil end
    if self._zoom_start_span ~= start_span then
        -- a new two-finger drag
        self._zoom_start_span = start_span
        self._last_pinch_factor = 1
    end
    local factor = span / start_span
    local step = factor / (self._last_pinch_factor or factor)
    self._last_pinch_factor = factor
    if step <= 0 then return nil end
    self.remote:zoom_at(ges.pos.x - self:canvas_geom().x, ges.pos.y - self:canvas_geom().y, step)
    UIManager:setDirty(self, "fast")
    return true
end

function ViewerApp:onInwardPan(_, ges) return self:_live_zoom(ges) end
function ViewerApp:onOutwardPan(_, ges) return self:_live_zoom(ges) end

function ViewerApp:onPinch()
    self._last_pinch_factor = nil
    self._zoom_start_span = nil
    UIManager:setDirty(self, "ui")
    return nil
end

function ViewerApp:onSpread()
    self._last_pinch_factor = nil
    self._zoom_start_span = nil
    UIManager:setDirty(self, "ui")
    return nil
end

function ViewerApp:onRotate(_, ges)
    if not self:_input_target() then return nil end
    self:rotate(ges.direction == "cw" and 1 or -1)
    return true
end

function ViewerApp:onKbdShow()
    if self.settings.keyboard_always_visible then return nil end
    self:set_keyboard_visible(true)
    return true
end

function ViewerApp:onKbdHide()
    if self.settings.keyboard_always_visible then return nil end
    self:set_keyboard_visible(false)
    return true
end

-- ---------------------------------------------------------------- physical keyboard

--[[--
Makes sure the platform delivers *text*, not just key events.

SDL 3 only sends `SDL_EVENT_TEXT_INPUT` after `SDL_StartTextInput()` ("Text input events are not
received by default", c.f. SDL_keyboard.h), and KOReader calls it from `InputText`/`InputDialog`
only, i.e. never while this viewer is up. Without this, typing on a hardware keyboard would
produce key events we deliberately ignore (the characters belong to the text input stream) and
nothing would reach the remote at all.
]]
function ViewerApp:_ensure_text_input()
    if self._text_input_asserted then return end
    self._text_input_asserted = true
    Device:startTextInput()
end

--[[--
Re-asserts text input after one of our own popups closed: the connection editor (and any other
KOReader text field) pairs `startTextInput` with `stopTextInput`, and would leave it off.
]]
function ViewerApp:reassert_text_input()
    self._text_input_asserted = false
    self:_ensure_text_input()
end

function ViewerApp:onShow()
    self:_ensure_text_input()
    self:evaluate_keyboard()
    self:_watch_keyboard_state()
end

--[[--
True for the one key we keep for ourselves: KOReader's `Menu` key opens (and closes) our menu,
which is also how a keyboard-only device reaches it. Everything else is forwarded to the remote
desktop — including Escape/Back, which is what a VNC client is expected to do; leaving the
viewer with a keyboard is done from the menu.
]]
function ViewerApp:_is_menu_key(key)
    return key.key == "Menu"
end

--- True when `Back` means "leave the viewer" rather than "send Escape".
--- On a device without a keyboard there is no other way to get out, so it leaves there.
function ViewerApp:_back_leaves(key)
    return key.key == "Back" and not Device:hasKeyboard()
end

function ViewerApp:onKeyPress(key)
    self:_ensure_text_input()
    if self:_is_menu_key(key) then
        self:toggle_menu()
        return true
    end
    if self:_back_leaves(key) then
        self:on_back()
        return true
    end
    local keysym = Keysyms.special[key.key]
    if keysym then
        self:send_key(keysym, true)
        return true
    end
    -- printable characters come through onTextInput, exactly once
    return nil
end

function ViewerApp:onKeyRelease(key)
    if self:_is_menu_key(key) or self:_back_leaves(key) then return true end
    local keysym = Keysyms.special[key.key]
    if keysym then
        self:send_key(keysym, false)
        return true
    end
    return nil
end

--- Auto-repeat is just another key press as far as the remote is concerned.
function ViewerApp:onKeyRepeat(key)
    if self:_is_menu_key(key) or self:_back_leaves(key) then return true end
    local keysym = Keysyms.special[key.key]
    if keysym then
        self:send_key(keysym, true)
        return true
    end
    return nil
end

function ViewerApp:onTextInput(text)
    if not self:_input_target() then return nil end
    for _, ch in ipairs(Util.split_chars(text)) do
        local codepoint = Keysyms.codepoint(ch)
        -- Control characters are what SDL delivers for Ctrl+letter; the modifier keydown
        -- was already forwarded, so sending these again would be wrong.
        if codepoint and codepoint >= 0x20 then
            local keysym = Keysyms.from_char(ch)
            if keysym then
                self:send_key(keysym, true)
                self:send_key(keysym, false)
            end
        end
    end
    return true
end

-- ---------------------------------------------------------------- keyboard

--- What the user asked for: the "keyboard always visible" setting, or their last manual choice.
function ViewerApp:is_keyboard_wanted()
    return self.settings.keyboard_always_visible or self.vk_wanted or false
end

--- The keyboard is only up while the framebuffer view owns the screen; a menu or dialog above it
--- takes the keyboard out of the way, and it comes back when that popup is gone.
function ViewerApp:_wanted_keyboard_visible()
    if self:_modal_above() then return false end
    return self:is_keyboard_wanted()
end

--- Applies the state implied by the setting, the user's wish and the window stack.
function ViewerApp:evaluate_keyboard()
    local want = self:_wanted_keyboard_visible()
    if want == self.vk_visible then
        -- The height may still have changed (layout switch); re-flow regardless.
        self.canvas = self:_layout()
        return
    end
    self.vk_visible = want
    -- The canvas does not change: the keyboard overlaps the framebuffer, so the view (and its
    -- scale) stays put and the user pans if something important ends up behind the keyboard.
    if want then
        self.vk:showKeyboard()
    else
        self.vk:hideKeyboard()
    end
    UIManager:setDirty(self, "ui")
end

--- Asks for a keyboard state for as long as the framebuffer view is the topmost window.
function ViewerApp:set_keyboard_visible(want)
    self.vk_wanted = want and true or false
    self:evaluate_keyboard()
end

--- Flips the keyboard, and keeps the "always visible" setting in sync: that setting wins over
--- the wish, so asking for the keyboard to go away while it is on would silently do nothing.
function ViewerApp:toggle_keyboard()
    local want = not self:is_keyboard_wanted()
    if not want and self.settings.keyboard_always_visible then
        self.settings.keyboard_always_visible = false
        self.plugin.settings:flush()
    end
    self:set_keyboard_visible(want)
end

--- How often the window stack is re-checked while the viewer is shown.
ViewerApp.KEYBOARD_WATCH_INTERVAL = 0.25

--- Re-evaluates the keyboard state on a short timer.
---
--- A popup opening above us cannot be noticed any other way: KOReader starts painting at the
--- topmost full-screen widget, so a widget shown *above* the viewer never repaints it (only
--- closing one dirties the widgets beneath). Popups we open ourselves notify us immediately;
--- this catches everything else (a message shown from outside the viewer, another plugin, ...).
function ViewerApp:_watch_keyboard_tick()
    self._keyboard_watch_pending = false
    if not UIManager:isWidgetShown(self) then return end
    if self.vk_visible ~= self:_wanted_keyboard_visible() then
        self:_sync_keyboard_later()
    end
    self:_watch_keyboard_state()
end

function ViewerApp:_watch_keyboard_state()
    if self._keyboard_watch_pending then return end
    self._keyboard_watch_pending = true
    UIManager:scheduleIn(ViewerApp.KEYBOARD_WATCH_INTERVAL, self._watch_keyboard_tick, self)
end

--- Deferred re-evaluation for the popup show/close paths (`_sync_keyboard_later`): by the time
--- the tick runs the window stack has settled.
function ViewerApp:_sync_keyboard_later()
    if self._keyboard_sync_pending then return end
    self._keyboard_sync_pending = true
    UIManager:nextTick(function()
        self._keyboard_sync_pending = false
        -- the viewer may have been left in the meantime: never bring a keyboard back on its own
        if not UIManager:isWidgetShown(self) then return end
        self:reassert_text_input()
        self:evaluate_keyboard()
    end)
end

--- The keyboard reports a new height (e.g. after a layout switch). It repaints itself; we
--- repaint the part of the canvas it used to cover.
function ViewerApp:on_keyboard_height_changed()
    UIManager:setDirty(self, "ui")
end

-- ---------------------------------------------------------------- zoom / orientation

function ViewerApp:zoom_to(mode)
    self.settings.zoom_mode = mode
    if mode == "fit" then
        local c = self:canvas_geom()
        self.remote:fit_view(c.w, c.h)
    else
        self.remote:set_scale(mode)
    end
    UIManager:setDirty(self, "ui")
end

function ViewerApp:rotate(delta)
    self:set_rotation_mode(band(Screen:getRotationMode() + delta, 3))
end

--- Asks for a new rotation mode, through KOReader's generic API, so that every widget
--- (including the on-screen keyboard, which we re-init in `onSetRotationMode`) follows.
function ViewerApp:set_rotation_mode(mode)
    if mode == nil or mode == Screen:getRotationMode() then return end
    UIManager:broadcastEvent(Event:new("SetRotationMode", mode))
end

--- Applies the session's default orientation, remembering the previous mode.
function ViewerApp:apply_default_orientation(default_mode)
    self.prev_rotation = self.prev_rotation or Screen:getRotationMode()
    if default_mode == nil then default_mode = self.settings.orientation end
    self:set_rotation_mode(default_mode)
end

--- Restores the rotation mode that was active before we were shown.
function ViewerApp:restore_rotation()
    if self.prev_rotation == nil then return end
    local mode = self.prev_rotation
    self.prev_rotation = nil
    self:set_rotation_mode(mode)
end

-- ---------------------------------------------------------------- menu / lifecycle

function ViewerApp:open_menu()
    if self.menu then return self.menu end
    self.menu = require("vncviewer/menu").open(self)
    -- The menu is on the window stack now: it owns the screen, so the keyboard gets out of the
    -- way (it is part of the framebuffer view, not of the menu).
    self:evaluate_keyboard()
    return self.menu
end

--- Closes the in-app menu when it is open.
function ViewerApp:close_menu()
    if self.menu then
        local menu = self.menu
        self.menu = nil
        UIManager:close(menu)
        -- `UIManager:close` does not run the menu's `close_callback`; hand the screen back to the
        -- framebuffer view (and its keyboard) ourselves.
        self:_sync_keyboard_later()
    end
end

function ViewerApp:disconnect_session()
    self.plugin:disconnect_session(self.session:get_profile().name)
end

function ViewerApp:on_session_error(err)
    local message = self.session:get_state() == "error" and self.session:get_error() or err
    UIManager:show(InfoMessage:new{
        text = _("VNC connection lost: ") .. tostring(message),
        timeout = 4,
    })
    -- it is above the framebuffer view now, and owns the screen until it goes away
    self:_sync_keyboard_later()
end

--- Leaves the app, keeping the connection alive.
function ViewerApp:on_back()
    if self:_modal_above() then return nil end
    self:leave()
    return true
end

function ViewerApp:leave()
    logger.dbg("vncviewer: leaving the app, keeping the session")
    self.plugin:leave_app()
end

return ViewerApp

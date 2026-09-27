--[[--
The full-screen viewer widget.

Owns the toolbar, the canvas (through @{vncviewer.framebuffer}), the gesture mapping to RFB
pointer events, the on-screen keyboard and the in-app menu. It is a plain (non-modal)
full-screen `InputContainer` flagged `is_always_active`, so that it keeps receiving gestures
even while one of its own popups is on top — hence the `_input_target()` / `_modal_above()`
guards on every canvas gesture.

@module vncviewer.app
]]

local bit = require("bit")
local _ = require("gettext")

local BB = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ButtonTable = require("ui/widget/buttontable")
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

ViewerApp.FALLBACK_BAR_HEIGHT = 40

-- ---------------------------------------------------------------- init

function ViewerApp:init()
    self.settings = self.plugin.settings.data.settings
    self.dimen = Screen:getSize()
    self.remote = self.session:get_remote()
    self.canvas = nil
    self.vk_visible = false
    self.vk = Keyboard.new(self.session, function() self:on_keyboard_height_changed() end)
    self._drag_active = nil
    self._last_pinch_factor = nil
    self._zoom_start_span = nil

    self:init_toolbar()
    self:init_gestures()
    self:_reflow()
end

function ViewerApp:init_toolbar()
    self.top_bar = ButtonTable:new{
        width = Screen:getWidth(),
        buttons = { {
            { text = _("Menu"), callback = function() self:open_menu() end },
            { text = _("Keyboard"), callback = function() self:toggle_keyboard() end },
            { text = _("Rotate"), callback = function() self:rotate(1) end },
            { text = _("Fit"), callback = function() self:zoom_to("fit") end },
        } },
    }
    -- Let WidgetContainer:propagateEvent reach the buttons (we paint them ourselves).
    self[1] = self.top_bar
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

function ViewerApp:_bar_height()
    local container = self.top_bar and self.top_bar[1]
    local size = container and container:getSize()
    if size and size.h and size.h > 0 then return size.h end
    return Screen:scaleBySize(self.FALLBACK_BAR_HEIGHT)
end

function ViewerApp:_layout(x, y)
    x, y = x or 0, y or 0
    local size = self.dimen
    local bar_h = self:_bar_height()
    local kbd_h = (self.vk_visible and self.vk and self.vk:getSize().h) or 0
    return Geom:new{
        x = x,
        y = y + bar_h,
        w = size.w,
        h = math.max(1, size.h - bar_h - kbd_h),
    }
end

--- Recomputes the canvas and re-fits the view when the zoom mode asks for it.
function ViewerApp:_reflow()
    self.dimen = Screen:getSize()
    self.canvas = self:_layout()
    if self.remote and self.settings.zoom_mode == "fit" then
        self.remote:fit_view(self.canvas.w, self.canvas.h)
    end
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
    self.top_bar:paintTo(bb, x, y)
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
    UIManager:show(Notification:new{ text = _("Bell"), timeout = 1 })
end

function ViewerApp:onCloseWidget()
    if self.vk then
        if self.vk:isVisible() then UIManager:close(self.vk) end
        self.vk_visible = false
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

function ViewerApp:onKeyPress(key)
    if key.key == "Back" then
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
    if key.key == "Back" then return true end
    local keysym = Keysyms.special[key.key]
    if keysym then
        self:send_key(keysym, false)
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

function ViewerApp:set_keyboard_visible(want)
    if self.settings.keyboard_always_visible then want = true end
    if self:_modal_above() then want = false end
    want = want and true or false
    if want == self.vk_visible then
        -- The height may still have changed (layout switch); re-flow regardless.
        self.canvas = self:_layout()
        return
    end
    self.vk_visible = want
    if want then
        UIManager:show(self.vk)
    else
        self.vk:hideKeyboard()
    end
    self:_reflow()
    UIManager:setDirty(self, "ui")
end

function ViewerApp:toggle_keyboard()
    self:set_keyboard_visible(not self.vk_visible)
end

function ViewerApp:_sync_keyboard()
    self:set_keyboard_visible(self.settings.keyboard_always_visible and true or false)
end

--- Deferred variant, for use in menu/dialog close callbacks: by then the popup is gone, so
--- `_modal_above()` sees the real state.
function ViewerApp:_sync_keyboard_later()
    UIManager:nextTick(function() self:_sync_keyboard() end)
end

function ViewerApp:on_keyboard_height_changed()
    self:_reflow()
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
    local mode = band(Screen:getRotationMode() + delta, 3)
    if mode == Screen:getRotationMode() then return end
    Screen:setRotationMode(mode)
    self:_reflow()
    self:updateTouchZonesOnScreenResize(self.dimen)
    UIManager:onRotation()
end

--- Applies the session's default orientation, remembering the previous mode.
function ViewerApp:apply_default_orientation(default_mode)
    self.prev_rotation = self.prev_rotation or Screen:getRotationMode()
    if default_mode == nil then default_mode = self.settings.orientation end
    if default_mode == nil then return end
    if default_mode ~= Screen:getRotationMode() then
        Screen:setRotationMode(default_mode)
        self:_reflow()
        UIManager:onRotation()
    end
end

--- Restores the rotation mode that was active before we were shown.
function ViewerApp:restore_rotation()
    if self.prev_rotation == nil then return end
    if Screen:getRotationMode() ~= self.prev_rotation then
        Screen:setRotationMode(self.prev_rotation)
        self:_reflow()
        UIManager:onRotation()
    end
    self.prev_rotation = nil
end

-- ---------------------------------------------------------------- menu / lifecycle

function ViewerApp:open_menu()
    require("vncviewer/menu").open(self)
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

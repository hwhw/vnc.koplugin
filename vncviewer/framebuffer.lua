--[[--
The remote framebuffer plane and the view transform that maps it onto the screen.

The plane is a `TYPE_BBRGB24` BlitBuffer holding the remote pixels 1:1 (that is the format
@{vncviewer.pxfmt} negotiates, so decoders write straight into it). The view transform is a
uniform `scale` (screen pixels per remote pixel) plus an offset `view_x, view_y` naming the
remote coordinate shown at the canvas' top-left corner.

@module vncviewer.framebuffer
]]

local BB = require("ffi/blitbuffer")
local logger = require("logger")

local Remote = {}
Remote.__index = Remote

Remote.MIN_SCALE = 0.05
Remote.MAX_SCALE = 8

--[[--
Creates a plane of `width` x `height` remote pixels.
--- @tparam number width
--- @tparam number height
]]
function Remote.new(width, height)
    local self = setmetatable({
        plane = BB.new(width, height, BB.TYPE_BBRGB24),
        w = width,
        h = height,
        scale = 1,
        view_x = 0,
        view_y = 0,
        cw = width,     -- canvas size (screen pixels) the view was last fitted to
        ch = height,
        version = 0,    -- bumped whenever the plane may have changed
        _scaled = nil,  -- cached scaled buffer for the current view
    }, Remote)
    return self
end

--[[--
The plane, for writing.

Handing the plane out advances the version counter, which invalidates the scale cache in
@{Remote:draw_to}.

Note that this happens *before* the write, and a decode can span several UI ticks (a frame
can be several hundred KiB), so a repaint may well happen while the plane is half written.
Every writer must therefore also call @{Remote:mark_dirty} once it is done (the session does
this from its `on_rect` callback).
--- @treturn BlitBuffer
]]
function Remote:get_plane()
    self.version = self.version + 1
    return self.plane
end

--- Marks the plane as possibly changed without handing it out (e.g. after a resize).
function Remote:mark_dirty()
    self.version = self.version + 1
end

--- @treturn number, number plane size in remote pixels
function Remote:get_size()
    return self.w, self.h
end

--- Zero-copy sub-window of the plane (shares its stride). The caller must not free it.
function Remote:viewport(x, y, w, h)
    return self:get_plane():viewport(x, y, w, h)
end

local function drop_cache(self)
    if self._scaled then
        self._scaled.bb:free()
        self._scaled = nil
    end
end

--[[--
Replaces the plane with one of the new size and re-fits the view.
]]
function Remote:resize(w, h)
    drop_cache(self)
    self.plane:free()
    self.plane = BB.new(w, h, BB.TYPE_BBRGB24)
    self.w, self.h = w, h
    self.version = self.version + 1
    if self.cw and self.ch and self.cw > 0 and self.ch > 0 then
        self:fit_view(self.cw, self.ch)
    else
        self.scale, self.view_x, self.view_y = 1, 0, 0
    end
end

--- Frees the plane and the cached scaled buffer.
function Remote:free()
    drop_cache(self)
    if self.plane then
        self.plane:free()
        self.plane = nil
    end
end

--- Keeps the view inside the plane (centring it when the plane is smaller than the canvas).
function Remote:_clamp()
    local cw, ch = self.cw, self.ch
    local span_x = cw / self.scale
    local span_y = ch / self.scale
    if self.w <= span_x then
        self.view_x = (self.w - span_x) / 2
    else
        self.view_x = math.max(0, math.min(self.view_x, self.w - span_x))
    end
    if self.h <= span_y then
        self.view_y = (self.h - span_y) / 2
    else
        self.view_y = math.max(0, math.min(self.view_y, self.h - span_y))
    end
end

local function clamp_scale(s)
    return math.max(Remote.MIN_SCALE, math.min(Remote.MAX_SCALE, s))
end

--[[--
Scales the plane so the whole thing is visible in `cw` x `ch` and centres it.
]]
function Remote:fit_view(cw, ch)
    self.cw, self.ch = cw, ch
    self.scale = clamp_scale(math.min(cw / self.w, ch / self.h))
    self:_clamp()
end

--[[--
Sets an absolute scale, keeping the current view centre.
]]
function Remote:set_scale(s)
    local ns = clamp_scale(s)
    local cx = self.view_x + self.cw / (2 * self.scale)
    local cy = self.view_y + self.ch / (2 * self.scale)
    self.scale = ns
    self.view_x = cx - self.cw / (2 * ns)
    self.view_y = cy - self.ch / (2 * ns)
    self:_clamp()
end

--[[--
Pans by a screen-pixel delta (positive = content moves right/down).
]]
function Remote:pan_by(dx, dy)
    self.view_x = self.view_x - dx / self.scale
    self.view_y = self.view_y - dy / self.scale
    self:_clamp()
end

--[[--
Multiplies the scale by `factor`, keeping the remote pixel under canvas `(sx, sy)` fixed.
]]
function Remote:zoom_at(sx, sy, factor)
    local rx = self.view_x + sx / self.scale
    local ry = self.view_y + sy / self.scale
    local ns = clamp_scale(self.scale * factor)
    self.scale = ns
    self.view_x = rx - sx / ns
    self.view_y = ry - sy / ns
    self:_clamp()
end

--- Canvas coordinates -> remote coordinates, clamped to the plane.
--- @treturn number, number
function Remote:screen_to_remote(sx, sy)
    local rx = math.floor(self.view_x + sx / self.scale)
    local ry = math.floor(self.view_y + sy / self.scale)
    rx = math.max(0, math.min(self.w - 1, rx))
    ry = math.max(0, math.min(self.h - 1, ry))
    return rx, ry
end

--- The source rect in plane coordinates that covers the canvas (may exceed the plane).
--- @treturn number, number, number, number x, y, w, h
function Remote:get_view_rect()
    return math.floor(self.view_x), math.floor(self.view_y),
        math.ceil(self.cw / self.scale), math.ceil(self.ch / self.scale)
end

--[[--
Maps a remote rect onto canvas coordinates, for dirty regions.

The result is deliberately generous by a pixel: a scaled rect's edges can land between
pixels, and repainting one extra row/column is cheaper than a missing one.
--- @tparam table rect `{x, y, w, h}` in remote coordinates
--- @tparam number cx, cy canvas origin
--- @treturn number, number, number, number
]]
function Remote:rect_to_canvas(rect, cx, cy)
    local x = cx + math.floor((rect.x - self.view_x) * self.scale)
    local y = cy + math.floor((rect.y - self.view_y) * self.scale)
    local w = math.ceil(rect.w * self.scale) + 1
    local h = math.ceil(rect.h * self.scale) + 1
    return x, y, w, h
end

--[[--
Draws the visible part of the plane into `bb` at `(cx, cy)`, using a canvas of `cw` x `ch`.

At 1:1 this is a straight blit; otherwise the source rect is scaled through
`RenderImage:scaleBlitBuffer` (MuPDF) and cached until the plane or the view changes.
--- @tparam BlitBuffer bb destination
--- @tparam boolean dither use the dithered blit (grey-screen screenshot path)
]]
function Remote:draw_to(bb, cx, cy, cw, ch, dither)
    if not self.plane or cw <= 0 or ch <= 0 then return end
    self.cw, self.ch = cw, ch

    -- Visible source rect, clipped to the plane.
    local sx0 = math.max(0, math.floor(self.view_x))
    local sy0 = math.max(0, math.floor(self.view_y))
    local sx1 = math.min(self.w, math.ceil(self.view_x + cw / self.scale))
    local sy1 = math.min(self.h, math.ceil(self.view_y + ch / self.scale))
    local copy_w, copy_h = sx1 - sx0, sy1 - sy0
    if copy_w <= 0 or copy_h <= 0 then return end

    local dx = cx + math.floor((sx0 - self.view_x) * self.scale)
    local dy = cy + math.floor((sy0 - self.view_y) * self.scale)

    local dst_w = math.max(1, math.floor(copy_w * self.scale))
    local dst_h = math.max(1, math.floor(copy_h * self.scale))

    if dst_w == copy_w and dst_h == copy_h then
        -- 1:1 (also covers scale == 1 exactly): the C blitter can do this directly.
        bb:blitFrom(self.plane, dx, dy, sx0, sy0, copy_w, copy_h)
        return
    end

    local cache = self._scaled
    if not (cache and cache.sx == sx0 and cache.sy == sy0 and cache.w == copy_w
            and cache.h == copy_h and cache.scale == self.scale
            and cache.version == self.version) then
        drop_cache(self)
        local RenderImage = require("ui/renderimage")
        local src = self.plane:viewport(sx0, sy0, copy_w, copy_h)
        local scaled = RenderImage:scaleBlitBuffer(src, dst_w, dst_h, false)
        if scaled == src then
            -- scaleBlitBuffer() returns its input untouched when the sizes match; that
            -- cannot happen here (we handled dst == copy above), but never cache a viewport.
            logger.warn("vncviewer: unexpected no-op scale, drawing without cache")
            scaled = nil
        end
        if scaled then
            cache = { bb = scaled, sx = sx0, sy = sy0, w = copy_w, h = copy_h,
                      scale = self.scale, version = self.version }
            self._scaled = cache
        end
    end

    local src_bb = cache and cache.bb
    if not src_bb then
        -- Fallback: direct nearest-neighbour-free blit of the viewport.
        bb:blitFrom(self.plane, dx, dy, sx0, sy0, copy_w, copy_h)
        return
    end

    local sw, sh = src_bb:getWidth(), src_bb:getHeight()
    if dither then
        bb:ditherblitFrom(src_bb, dx, dy, 0, 0, sw, sh)
    else
        bb:blitFrom(src_bb, dx, dy, 0, 0, sw, sh)
    end
end

return Remote

--[[--
Stylus annotations.

Freehand pen & highlighter annotations for PDF documents, driven by the stylus
callback API (Input:registerStylusCallback). On platforms without the stylus
callback (e.g., the Linux emulator), a touch-pan fallback lets drawing be
driven by finger/mouse drags while drawing is enabled.

Strokes are stored in native page coordinates (top-left origin, y pointing
down): points captured with ReaderView:screenToPageTransform are stored
verbatim (no y-flip, no rotation handling: KOReader rotates the framebuffer,
not the document).

Strokes are persisted to a document sidecar
(<sidecar_dir>/stylus_annotations.lua), as the only storage.

Only the PDF format is supported for now.

@module koplugin.stylus_annotations
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local Geometry = require("lib/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local ReaderHighlight = require("apps/reader/modules/readerhighlight")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonSelector = require("ui/widget/buttonselector")
local UIManager = require("ui/uimanager")
local Geom = require("ui/geometry")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local dbg = require("dbg")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen

local TOOL_TYPE_PEN = Device.input.TOOL_TYPE_PEN
local TOOL_TYPE_HIGHLIGHTER = Device.input.TOOL_TYPE_HIGHLIGHTER

local HIT_TEST_THRESHOLD_PX = 25
local SAVE_DELAY_MS = 800
local HOLD_TIME_S = 0.45
local HOLD_MOVE_THRESHOLD_PX = 15

local DEFAULT_WIDTH = 2
local DEFAULT_HIGHLIGHTER_WIDTH = 20
local DEFAULT_COLOR = "orange"

local WIDTH_CHOICES = { 1, 2, 3, 5, 8, 12 }

-- Colors offered only by this plugin, kept out of ReaderHighlight's
-- text-highlight palette. Entries: { localized label, color name, "#RRGGBB" }.
local EXTRA_COLORS = {
    {_("Black"), "black", "#000000"},
    {_("White"), "white", "#FFFFFF"},
}

-- Menu palette: reuse ReaderHighlight's text-highlight colors (so they aren't
-- duplicated here), extended with our black/white extras.
local COLOR_PALETTE = {}
for _, c in ipairs(ReaderHighlight.highlight_colors) do
    COLOR_PALETTE[#COLOR_PALETTE + 1] = { c[1], c[2] }
end
for _, c in ipairs(EXTRA_COLORS) do
    COLOR_PALETTE[#COLOR_PALETTE + 1] = { c[1], c[2] }
end

-- name -> "#RRGGBB". Values come from koreader's HIGHLIGHT_COLORS; gray is
-- part of the text-highlight palette but has no HIGHLIGHT_COLORS entry
-- (koreader renders it via Blitbuffer.gray), so give it a concrete value
-- here; black/white come from EXTRA_COLORS.
local COLOR_HEX = {}
for name, hex in pairs(Blitbuffer.HIGHLIGHT_COLORS) do
    COLOR_HEX[name] = hex
end
COLOR_HEX.gray = "#808080"
for _, c in ipairs(EXTRA_COLORS) do
    COLOR_HEX[c[2]] = c[3]
end

local StylusAnnotations = InputContainer:extend{
    name = "stylus_annotations",
    is_doc_only = true,

    strokes = nil,
    strokes_by_page = nil,     -- page -> array of indices into self.strokes
    bookmarked_pages = nil,    -- set of pages we created page-marker bookmarks for
    strokes_loaded = false,

    stylus_callback_registered = false,
    touch_zones_registered = false,

    current_stroke = nil,
    pen_x = 0,
    pen_y = 0,

    hold_timer = nil,
    hold_start_x = 0,
    hold_start_y = 0,

    dirty_region = nil,

    pending_save = nil,
}

function StylusAnnotations:init()
    self.strokes = {}
    self.strokes_by_page = {}
    self.bookmarked_pages = {}
    self.stroke_id_counter = 0

    self:loadSettings()

    self.view = self.ui.view
    self.view:registerViewModule("stylus_annotations", self)

    self:loadStrokes()

    self.ui.menu:registerToMainMenu(self)

    Dispatcher:registerAction("stylus_annotations_toggle", {
        category = "none",
        event = "StylusAnnotationsToggle",
        title = _("Stylus annotations: toggle drawing"),
        reader = true,
    })

    self:setupStylusCallback()
    self:setupTouchZones()

    -- The debug APK launches reader.lua with -d, which turns on per-event
    -- debug logging in the base input handler (~6 logcat writes per touch
    -- frame, synchronous in the Input thread). With the stylus now delivering
    -- the full ~380Hz sample rate, keeping those per-frame logs on would
    -- throttle the drain again, so force debug logging off here.
    dbg:turnOff()

    logger.info("StylusAnnotations: initialized, strokes =", #self.strokes)
end

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------

function StylusAnnotations:isEnabled()
    return G_reader_settings:readSetting("stylus_annotations_enabled") == true
end

function StylusAnnotations:setEnabled(enabled)
    G_reader_settings:saveSetting("stylus_annotations_enabled", enabled)
end

function StylusAnnotations:loadSettings()
    local ds = self.ui.doc_settings
    self.live_ink = ds:readSetting("stylus_annotations_live_ink") == true
    self.width = ds:readSetting("stylus_annotations_width") or DEFAULT_WIDTH
    self.highlighter_width = ds:readSetting("stylus_annotations_highlighter_width")
        or DEFAULT_HIGHLIGHTER_WIDTH
    self.color = ds:readSetting("stylus_annotations_color") or DEFAULT_COLOR
end

function StylusAnnotations:saveSettings()
    local ds = self.ui.doc_settings
    ds:saveSetting("stylus_annotations_live_ink", self.live_ink ~= false)
    ds:saveSetting("stylus_annotations_width", self.width)
    ds:saveSetting("stylus_annotations_highlighter_width", self.highlighter_width)
    ds:saveSetting("stylus_annotations_color", self.color)
end

--------------------------------------------------------------------------------
-- Input: stylus callback (low-latency drawing)
--------------------------------------------------------------------------------

function StylusAnnotations:setupStylusCallback()
    if self.stylus_callback_registered then return end
    local Input = Device.input
    if Input and Input.registerStylusCallback then
        local plugin = self
        Input:registerStylusCallback(function(input, slot)
            return plugin:onStylusEvent(input, slot)
        end)
        self.stylus_callback_registered = true
    else
        logger.warn("StylusAnnotations: stylus callback API not available")
    end
    -- The stylus callback exists on the emulator too, but mouse/finger input
    -- doesn't produce pen events there, so also offer the touch-pan fallback
    -- to keep drawing testable with a mouse. NOTE: isEmulator is a method
    -- (generic/device.lua defines `no = function() return false end`), so it
    -- must be called, not read as a boolean -- otherwise the fallback would
    -- wrongly register on real hardware and clobber the pen gestures.
    if Device:isEmulator() then
        self:setupTouchPenFallback()
    end
end

function StylusAnnotations:teardownStylusCallback()
    if not self.stylus_callback_registered then return end
    if self.current_stroke then
        self.current_stroke = nil
    end
    local Input = Device.input
    if Input and Input.unregisterStylusCallback then
        Input:unregisterStylusCallback()
    end
    self.stylus_callback_registered = false
end

-- Fallback for platforms without the stylus callback API (e.g., the Linux
-- emulator): route a single-finger drag as a pen stroke while drawing is
-- enabled. Overrides the reader's pan handlers so we see the gesture first,
-- then pass it through (return false) whenever we don't want to draw.
function StylusAnnotations:setupTouchPenFallback()
    if self.touch_pen_fallback_registered then return end
    self.ui:registerTouchZones({
        {
            id = "stylus_annotations_pen_pan",
            ges = "pan",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "rolling_pan",
                "rolling_pan_release",
                "paging_pan",
                "paging_pan_release",
            },
            handler = function(ges)
                return self:onPenPan(ges)
            end,
        },
        {
            id = "stylus_annotations_pen_pan_release",
            ges = "pan_release",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "rolling_pan_release",
                "paging_pan_release",
            },
            handler = function(ges)
                return self:onPenPanRelease(ges)
            end,
        },
    })
    self.touch_pen_fallback_registered = true
    logger.info("StylusAnnotations: touch-pan pen fallback registered")
end

function StylusAnnotations:onPenPan(ges)
    if self:isOverlayActive() then return false end
    if not self:isEnabled() then return false end
    local start = ges.start_pos or ges.pos
    local cur = ges.pos
    if self.current_stroke then
        self:addStrokePoint(cur.x, cur.y)
    else
        self:startStroke(start.x, start.y)
        if self.current_stroke then
            self:addStrokePoint(cur.x, cur.y)
        end
    end
    self.pen_x, self.pen_y = cur.x, cur.y
    return true
end

function StylusAnnotations:onPenPanRelease(ges)
    if self:isOverlayActive() then return false end
    if not self:isEnabled() then return false end
    if self.current_stroke then
        self:endStroke()
    end
    return true
end

-- Check if a menu or overlay is shown on top of the reader view.
-- When true, stylus input must pass through so the overlay can handle it.
function StylusAnnotations:isOverlayActive()
    local top = UIManager:getTopmostVisibleWidget()
    if not top then return false end
    return (top.name or top.id) ~= "ReaderUI"
end

-- Handle a stylus slot from the callback.
-- slot = {slot=N, id=N, x=N, y=N, tool=N, timev=timestamp}
-- id >= 0 means contact active, id == -1 means contact lifted/hovering.
function StylusAnnotations:onStylusEvent(input, slot)
    -- A widget (menu, dialog, ...) is on top: let the stylus drive the UI.
    if self:isOverlayActive() then return false end

    -- Drawing disabled: pass through so pen gestures (hold/double-tap
    -- stroke editing) keep working.
    if not self:isEnabled() then return false end

    local tool = slot.tool or TOOL_TYPE_PEN
    if tool ~= TOOL_TYPE_PEN and tool ~= TOOL_TYPE_HIGHLIGHTER then return false end

    local x, y = slot.x or 0, slot.y or 0
    if slot.id and slot.id >= 0 then
        -- Contact active (down or move).
        if self.current_stroke then
            self:addStrokePoint(x, y)
        else
            self:startStroke(x, y, tool)
        end
        self.pen_x, self.pen_y = x, y
    else
        -- Contact lifted: end the stroke. A single point yields a small dot.
        if self.current_stroke then
            self:endStroke()
        end
    end

    -- Dominate: keep this pen event away from gesture detection.
    return true
end

function StylusAnnotations:clearHoldTimer()
    if self.hold_timer then
        UIManager:unschedule(self.hold_timer)
        self.hold_timer = nil
    end
end

--------------------------------------------------------------------------------
-- Live drawing
--------------------------------------------------------------------------------

function StylusAnnotations:startStroke(x, y, tool)
    local pos = self.ui.view:screenToPageTransform({ x = x, y = y })
    self.stroke_id_counter = self.stroke_id_counter + 1
    self.current_stroke = {
        id = tostring(self.stroke_id_counter),
        page = pos.page,
        tool = tool == TOOL_TYPE_HIGHLIGHTER and "highlighter" or "pen",
        points = { { x = pos.x, y = pos.y } },
        width = tool == TOOL_TYPE_HIGHLIGHTER and self.highlighter_width or self.width,
        color = self.color,
        alpha = tool == TOOL_TYPE_HIGHLIGHTER and 0.5 or 1.0,
        zoom = pos.zoom or 1,
        datetime = os.time(),
    }
    self.pen_x, self.pen_y = x, y
    self.dirty_region = nil

    -- Live-ink state: track where we last drew on the screen and the pending
    -- fast-refresh region accumulating while the pen is down.
    self.live_dirty = nil
    self.live_last_x, self.live_last_y = x, y

    -- While drawing is enabled the stylus callback dominates every event, so
    -- the gesture layer can never see a long-press. Arm a hold check ourselves:
    -- a pen held still (without drawing) opens the stroke menu instead.
    self.hold_start_x, self.hold_start_y = x, y
    if self.hold_timer then
        UIManager:unschedule(self.hold_timer)
    end
    local hold_action = function()
        self.hold_timer = nil
        self:onStrokeHoldTimer()
    end
    self.hold_timer = hold_action
    UIManager:scheduleIn(HOLD_TIME_S, hold_action)
end

function StylusAnnotations:addStrokePoint(x, y)
    local stroke = self.current_stroke
    if not stroke then return end
    local pos = self.ui.view:screenToPageTransform({ x = x, y = y })
    if pos.page ~= stroke.page then return end -- should not happen mid-stroke
    local last = stroke.points[#stroke.points]
    if last and last.x == pos.x and last.y == pos.y then return end
    table.insert(stroke.points, { x = pos.x, y = pos.y })

    -- Instant-ink: while the pen is down we only buffer the point and track the
    -- stroke's bounding box; nothing is drawn or committed to the panel. This
    -- panel settles region waves far too slowly to show per-point ink smoothly,
    -- so all panel work is deferred to endStroke(), which renders the whole
    -- stroke as a smooth spline into the shadow and refreshes it once.
    local sw = self:getStrokeScreenWidth(stroke)
    local half = math.floor(sw / 2)
    local seg_x = math.min(self.pen_x, x) - half
    local seg_y = math.min(self.pen_y, y) - half
    local seg_w = math.abs(x - self.pen_x) + sw
    local seg_h = math.abs(y - self.pen_y) + sw
    self:accumulateDirty(seg_x, seg_y, seg_w, seg_h)

    -- Live ink: draw the new segment into the shadow immediately so the pen tip
    -- is followed as it moves, then flush an immediate fast refresh to the
    -- panel. The segment bounding box (seg_*) doubles as the pending refresh
    -- region. endStroke() redraws/refreshes nothing extra in this mode: the
    -- fast refresh on pen-up just reveals what was already painted live.
    if self.live_ink ~= false then
        local swz = self:getPageZoom(stroke.page) * stroke.width
        self:drawStrokePath(Screen.bb,
            { { x = self.live_last_x, y = self.live_last_y }, { x = x, y = y } },
            swz, self:getRenderColor(stroke), stroke.alpha)
        self.live_last_x, self.live_last_y = x, y
        local ld = self.live_dirty
        if ld then
            local x0 = math.min(ld.x, seg_x)
            local y0 = math.min(ld.y, seg_y)
            local x1 = math.max(ld.x + ld.w, seg_x + seg_w)
            local y1 = math.max(ld.y + ld.h, seg_y + seg_h)
            self.live_dirty = { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
        else
            self.live_dirty = { x = seg_x, y = seg_y, w = seg_w, h = seg_h }
        end
        self:flushLive()
    end

    self.pen_x, self.pen_y = x, y

    -- Significant pen movement means drawing, not a long-press: cancel the
    -- pending hold check.
    if self.hold_timer
        and (math.abs(x - self.hold_start_x) > HOLD_MOVE_THRESHOLD_PX
            or math.abs(y - self.hold_start_y) > HOLD_MOVE_THRESHOLD_PX) then
        UIManager:unschedule(self.hold_timer)
        self.hold_timer = nil
    end
end

function StylusAnnotations:flushLive()
    local ld = self.live_dirty
    if not ld or ld.w <= 0 or ld.h <= 0 then return end
    self.live_dirty = nil
    local rx = math.max(0, math.floor(ld.x))
    local ry = math.max(0, math.floor(ld.y))
    local rw = math.min(Screen:getWidth() - rx, math.ceil(ld.w))
    local rh = math.min(Screen:getHeight() - ry, math.ceil(ld.h))
    if rw > 0 and rh > 0 then
        UIManager:setDirty(self.view, function()
            return "fast", Geom:new{x = rx, y = ry, w = rw, h = rh}
        end)
    end
end

-- Drop any pending live refresh state (called on pen-up).
function StylusAnnotations:cancelLive()
    self.live_dirty = nil
end

function StylusAnnotations:endStroke()
    if self.hold_timer then
        UIManager:unschedule(self.hold_timer)
        self.hold_timer = nil
    end
    local stroke = self.current_stroke
    local region = self.dirty_region
    self.current_stroke = nil
    self.dirty_region = nil
    if not stroke or #stroke.points == 0 then return end

    stroke.points = self:decimatePoints(stroke)

    table.insert(self.strokes, stroke)
    local idx = #self.strokes
    self.strokes_by_page[stroke.page] = self.strokes_by_page[stroke.page] or {}
    table.insert(self.strokes_by_page[stroke.page], idx)

    self:ensureBookmark(stroke.page)
    self:scheduleSave()

    self:cancelLive()
    -- Live ink already painted the buffer while the pen was down, so skip the
    -- (re-blending) full render. In the deferred mode nothing touched the panel
    -- yet, so render first, then do the crisp partial on pen-up either way.
    if self.live_ink == false then
        self:renderStrokeToScreen(stroke)
    end
    self:refreshRegion(region)
end

-- Reduce the number of stored points for a finished stroke. Points closer than
-- MIN_SPACING screen pixels to the last kept point are dropped (measured in
-- screen space via pageToScreenPoint so the threshold is resolution-independent).
-- First and last points are always kept so the stroke endpoints stay exact.
function StylusAnnotations:decimatePoints(stroke)
    local pts = stroke.points
    local n = #pts
    if n <= 2 then return pts end
    local MIN_SPACING = 2.5
    local kept = { pts[1] }
    local lx, ly = self:pageToScreenPoint(stroke.page, pts[1].x, pts[1].y)
    for i = 2, n do
        local p = pts[i]
        local sx, sy = self:pageToScreenPoint(stroke.page, p.x, p.y)
        local dx, dy = sx - lx, sy - ly
        if dx * dx + dy * dy >= MIN_SPACING * MIN_SPACING or i == n then
            kept[#kept + 1] = p
            lx, ly = sx, sy
        end
    end
    return kept
end

function StylusAnnotations:renderStrokeToScreen(stroke)
    local color = self:getRenderColor(stroke)
    local sw = self:getPageZoom(stroke.page) * stroke.width
    local pts = stroke.points
    local n = #pts
    if n == 0 then return end
    local sph = {}
    for i = 1, n do
        local sx, sy = self:pageToScreenPoint(stroke.page, pts[i].x, pts[i].y)
        if not sx then break end
        sph[i] = { x = sx, y = sy }
    end
    self:drawStrokePath(Screen.bb, sph, sw, color, stroke.alpha)
end

function StylusAnnotations:refreshRegion(region)
    local function refresh(mode, r)
        if r then
            local rx = math.max(0, math.floor(r.x))
            local ry = math.max(0, math.floor(r.y))
            local rw = math.min(Screen:getWidth() - rx, math.ceil(r.w))
            local rh = math.min(Screen:getHeight() - ry, math.ceil(r.h))
            if rw > 0 and rh > 0 then
                UIManager:setDirty(self.view, function()
                    return mode, Geom:new{x = rx, y = ry, w = rw, h = rh}
                end)
                return
            end
        end
        UIManager:setDirty(self.view, mode)
    end

    -- Deferred (live ink off): nothing touched the panel on pen-up, so a single
    -- GU16 partial commits the finished stroke in its final grey.
    -- Live (live ink on): the stroke was already painted by fast A2 commits
    -- while drawing; a GU16 partial on pen-up crisps it up.
    refresh("partial", region)
end

-- Pen-down without drawing for HOLD_TIME_S opens the stroke menu on the
-- annotation under the pen (cancelling the stillborn dot stroke).
function StylusAnnotations:onStrokeHoldTimer()
    local stroke = self.current_stroke
    if not stroke then return end
    local dx = self.pen_x - self.hold_start_x
    local dy = self.pen_y - self.hold_start_y
    -- Pen actually moved: this is a (slow) stroke, not a long-press.
    if dx * dx + dy * dy > HOLD_MOVE_THRESHOLD_PX * HOLD_MOVE_THRESHOLD_PX then return end
    -- Long-press: cancel the stillborn stroke, repaint to erase the live dot,
    -- then open the stroke menu.
    self.current_stroke = nil
    self.dirty_region = nil
    UIManager:setDirty(self.view, "partial")
    self:showStrokeMenuAt(self.hold_start_x, self.hold_start_y)
end

function StylusAnnotations:showStrokeMenuAt(x, y)
    local stroke = self:findStrokeAt({ pos = { x = x, y = y } })
    if not stroke then return end
    self:showStrokeMenu(stroke)
end

function StylusAnnotations:getStrokeScreenWidth(stroke)
    return math.max(1, math.floor(stroke.width * (stroke.zoom or 1) + 0.5))
end

function StylusAnnotations:getRenderColor(stroke)
    local hex = COLOR_HEX[stroke.color]
    local color
    if hex then
        color = Blitbuffer.colorFromString(hex)
        if Screen.night_mode then
            local r, g, b = hex:match("#(..)(..)(..)")
            color = Blitbuffer.colorFromString(string.format("#%02x%02x%02x",
                255 - tonumber(r, 16), 255 - tonumber(g, 16), 255 - tonumber(b, 16)))
        end
    else
        color = self.ui.highlight
            and self.ui.highlight:getHighlightColor(stroke.color)
            or Blitbuffer.COLOR_BLACK
    end
    local rgb = color:getColorRGB32()
    local alpha = math.floor((stroke.alpha or 1.0) * 255)
    return Blitbuffer.ColorRGB32(rgb.r, rgb.g, rgb.b, alpha)
end

function StylusAnnotations:accumulateDirty(x, y, w, h)
    if not self.dirty_region then
        self.dirty_region = { x = x, y = y, w = w, h = h }
    else
        local r = self.dirty_region
        local x0 = math.min(r.x, x)
        local y0 = math.min(r.y, y)
        local x1 = math.max(r.x + r.w, x + w)
        local y1 = math.max(r.y + r.h, y + h)
        self.dirty_region = { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
    end
end

--------------------------------------------------------------------------------
-- Rendering (view module)
--------------------------------------------------------------------------------

function StylusAnnotations:paintTo(bb, x, y)
    if not self.ui.paging then return end
    local pages = self:getVisiblePages()
    if not pages then return end
    for _, page in ipairs(pages) do
        for _, idx in ipairs(self.strokes_by_page[page] or {}) do
            self:paintStroke(bb, x, y, self.strokes[idx])
        end
    end
    if self.current_stroke then
        self:paintStroke(bb, x, y, self.current_stroke)
    end
end

function StylusAnnotations:getVisiblePages()
    local view = self.view
    if view.page_scroll then
        local pages = {}
        for _, state in ipairs(view.page_states) do
            pages[#pages + 1] = state.page
        end
        return pages
    else
        if not view.state or not view.state.page then return nil end
        return { view.state.page }
    end
end

function StylusAnnotations:paintStroke(bb, x, y, stroke)
    local color = self:getRenderColor(stroke)
    local alpha = stroke.alpha
    local sw = self:getPageZoom(stroke.page) * stroke.width
    local pts = stroke.points
    local n = #pts
    if n == 0 then return end
    local sph = {}
    for i = 1, n do
        local sx, sy = self:pageToScreenPoint(stroke.page, pts[i].x, pts[i].y)
        if not sx then return end
        sph[i] = { x = x + sx, y = y + sy }
    end
    self:drawStrokePath(bb, sph, sw, color, alpha)
end

-- Render a stroke as a connected thick polyline: march an overlapping stamp along
-- every segment between consecutive points. With the digitizer's full sample rate
-- now reaching koreader (~380Hz, via the input_android history-unroll), the points
-- land ~1-2px apart, so line segments read as a continuous smooth stroke.
function StylusAnnotations:drawStrokePath(bb, sph, sw, color, alpha)
    local n = #sph
    if n == 0 then return end
    local half = math.floor(sw / 2)
    local function stamp(sx, sy)
        bb:blendRectRGB32(math.floor(sx) - half, math.floor(sy) - half, sw, sw, color)
    end
    if n == 1 then
        stamp(sph[1].x, sph[1].y)
        return
    end
    -- Draw a connected thick polyline: march an overlapping stamp along every
    -- segment between consecutive points (not isolated per-sample dots), so the
    -- stroke reads as a continuous line through all captured digitizer positions.
    local x1, y1 = sph[1].x, sph[1].y
    stamp(x1, y1)
    for i = 2, n do
        local x2, y2 = sph[i].x, sph[i].y
        local dx, dy = x2 - x1, y2 - y1
        local dist_sq = dx * dx + dy * dy
        if dist_sq >= 1 then
            local steps = math.ceil(math.sqrt(dist_sq))
            for s = 1, steps do
                stamp(x1 + dx * (s / steps), y1 + dy * (s / steps))
            end
        else
            -- Sub-pixel segment (slow movement): stamp the endpoint so the
            -- stroke stays continuous; otherwise such points draw no ink at all.
            stamp(x2, y2)
        end
        x1, y1 = x2, y2
    end
end

function StylusAnnotations:getPageZoom(page)
    local view = self.view
    if view.page_scroll then
        for _, state in ipairs(view.page_states) do
            if state.page == page then
                return state.zoom or 1
            end
        end
        return 1
    else
        return view.state and view.state.zoom or 1
    end
end

-- Inverse of ReaderView:getSinglePagePosition / getScrollPagePosition:
-- native page point -> screen coordinates relative to the view widget.
function StylusAnnotations:pageToScreenPoint(page, x_p, y_p)
    local view = self.view
    if view.page_scroll then
        local acc_y = 0
        for _, state in ipairs(view.page_states) do
            if state.page == page then
                local sx = state.offset.x + x_p * state.zoom - state.visible_area.x
                local sy = acc_y + state.offset.y + y_p * state.zoom - state.visible_area.y
                return sx, sy
            end
            acc_y = acc_y + state.visible_area.h + view.page_gap.height
        end
        return nil
    else
        local st = view.state
        if not st or st.page ~= page then return nil end
        local sx = st.offset.x + x_p * st.zoom - view.visible_area.x
        local sy = st.offset.y + y_p * st.zoom - view.visible_area.y
        return sx, sy
    end
end

--------------------------------------------------------------------------------
-- Gestures (stroke editing)
--------------------------------------------------------------------------------

function StylusAnnotations:setupTouchZones()
    if self.touch_zones_registered then return end
    self.ui:registerTouchZones({
        {
            id = "stylus_annotations_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "readerfooter_holding",
                "tap_forward",
                "tap_backward",
            },
            handler = function(ges)
                return self:onStrokeTap(ges)
            end,
        },
        {
            id = "stylus_annotations_double_tap",
            ges = "double_tap",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            handler = function(ges)
                return self:onStrokeDoubleTap(ges)
            end,
        },
    })
    self.touch_zones_registered = true
end

function StylusAnnotations:onStrokeTap(ges)
    if self:isOverlayActive() then return false end
    local stroke = self:findStrokeAt(ges)
    if not stroke then return false end
    self:showStrokeMenu(stroke)
    return true
end

function StylusAnnotations:onStrokeDoubleTap(ges)
    if self:isOverlayActive() then return false end
    local stroke = self:findStrokeAt(ges)
    if not stroke then return false end
    self:deleteStroke(stroke)
    return true
end

function StylusAnnotations:findStrokeAt(ges)
    if #self.strokes == 0 or not ges or not ges.pos then return nil end
    local pos = self.ui.view:screenToPageTransform({ x = ges.pos.x, y = ges.pos.y })
    local zoom = pos.zoom or 1
    local threshold = HIT_TEST_THRESHOLD_PX / zoom
    local best, best_sq
    for _, stroke in ipairs(self.strokes) do
        if stroke.page == pos.page then
            local d = Geometry.strokeDistanceSq(pos.x, pos.y, stroke)
            if d <= threshold * threshold and (not best_sq or d < best_sq) then
                best, best_sq = stroke, d
            end
        end
    end
    return best
end

function StylusAnnotations:showStrokeMenu(stroke)
    -- Same widget & layout as the text-highlight edit popup
    -- (ReaderHighlight:showHighlightDialog): a rounded ButtonDialog whose first
    -- row is the trash/deletion icon plus the per-item actions.
    local dialog
    dialog = ButtonDialog:new{
        buttons = {
            {
                {
                    text = "\u{F48E}", -- Trash can (same icon as highlight delete)
                    callback = function()
                        UIManager:close(dialog)
                        self:deleteStroke(stroke)
                    end,
                },
                {
                    text = _("Color"),
                    callback = function()
                        UIManager:close(dialog)
                        self:chooseStrokeColor(stroke)
                    end,
                },
                {
                    text = _("Width"),
                    callback = function()
                        UIManager:close(dialog)
                        self:chooseStrokeWidth(stroke)
                    end,
                },
            },
        },
    }
    self.stroke_dialog = dialog
    UIManager:show(dialog, "[ui]")
end

-- Swatch color picker, mirroring ReaderHighlight:editHighlightColor
-- (the same ButtonSelector the text highlights pop for "Color").
function StylusAnnotations:chooseStrokeColor(stroke)
    local color_selector
    local bg_colors = {}
    for i, c in ipairs(COLOR_PALETTE) do
        bg_colors[i] = Blitbuffer.colorFromString(COLOR_HEX[c[2]] or "#808080")
    end
    color_selector = ButtonSelector:new{
        current_value = stroke.color,
        values = COLOR_PALETTE,
        bg_colors = bg_colors,
        callback = function(value)
            self:setStrokeColor(stroke, value)
            UIManager:close(color_selector)
        end,
    }
    UIManager:show(color_selector)
end

-- Default pen color picker, same ButtonSelector (color swatches) as the text
-- highlights pop for "Color", so the two menus look identical.
function StylusAnnotations:choosePenColor()
    local color_selector
    local bg_colors = {}
    for i, c in ipairs(COLOR_PALETTE) do
        bg_colors[i] = Blitbuffer.colorFromString(COLOR_HEX[c[2]] or "#808080")
    end
    color_selector = ButtonSelector:new{
        current_value = self.color,
        values = COLOR_PALETTE,
        bg_colors = bg_colors,
        callback = function(value)
            self.color = value
            self:saveSettings()
            UIManager:close(color_selector)
        end,
    }
    UIManager:show(color_selector)
end

function StylusAnnotations:chooseStrokeWidth(stroke)
    local width_selector
    local width_choices = {}
    for _, w in ipairs(WIDTH_CHOICES) do
        width_choices[#width_choices + 1] = { tostring(w), w }
    end
    width_selector = ButtonSelector:new{
        current_value = stroke.width,
        values = width_choices,
        callback = function(value)
            self:setStrokeWidth(stroke, value)
            UIManager:close(width_selector)
        end,
    }
    UIManager:show(width_selector)
end

function StylusAnnotations:setStrokeColor(stroke, color)
    stroke.color = color
    self:afterStrokeModified(stroke)
end

function StylusAnnotations:setStrokeWidth(stroke, width)
    stroke.width = width
    self:afterStrokeModified(stroke)
end

function StylusAnnotations:afterStrokeModified(stroke)
    self:scheduleSave()
    UIManager:setDirty(self.view, "partial")
end

function StylusAnnotations:deleteStroke(stroke)
    local page = stroke.page
    for i, s in ipairs(self.strokes) do
        if s == stroke then
            table.remove(self.strokes, i)
            break
        end
    end
    self:rebuildPageIndex()
    self:maybeRemoveBookmark(page)
    self:scheduleSave()
    UIManager:setDirty(self.view, "partial")
end

function StylusAnnotations:rebuildPageIndex()
    self.strokes_by_page = {}
    for i, stroke in ipairs(self.strokes) do
        self.strokes_by_page[stroke.page] = self.strokes_by_page[stroke.page] or {}
        table.insert(self.strokes_by_page[stroke.page], i)
    end
end

--------------------------------------------------------------------------------
-- Bookmarks (page markers for navigability)
--------------------------------------------------------------------------------

function StylusAnnotations:ensureBookmark(page)
    if not self.ui.paging then return end
    if not self.ui.annotation or not self.ui.bookmark then return end
    if self.bookmarked_pages[page] then return end
    if self.ui.bookmark:getDogearBookmarkIndex(page) then
        self.bookmarked_pages[page] = true
        return
    end
    local item = { page = page }
    local index = self.ui.annotation:addItem(item)
    self.ui:handleEvent(Event:new("AnnotationsModified", { item, index_modified = index }))
    self.bookmarked_pages[page] = true
end

function StylusAnnotations:maybeRemoveBookmark(page)
    if not self.ui.annotation or not self.bookmarked_pages[page] then return end
    if #(self.strokes_by_page[page] or {}) > 0 then return end
    local index = self.ui.bookmark and self.ui.bookmark:getDogearBookmarkIndex(page)
    if index then
        local item = table.remove(self.ui.annotation.annotations, index)
        self.ui:handleEvent(Event:new("AnnotationsModified", { item, index_modified = -index }))
    end
    self.bookmarked_pages[page] = nil
end

--------------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------------

function StylusAnnotations:getStrokesFilePath()
    local sidecar_dir = self.ui.doc_settings and self.ui.doc_settings.doc_sidecar_dir
    if sidecar_dir then
        return sidecar_dir .. "/stylus_annotations.lua"
    end
    return nil
end

function StylusAnnotations:scheduleSave()
    -- UIManager:scheduleIn returns nothing, so keep a reference to the action
    -- itself as the handle: unschedule() matches on the action reference.
    if self.pending_save then
        UIManager:unschedule(self.pending_save)
    end
    self.pending_save = function()
        self.pending_save = nil
        self:saveStrokes()
    end
    UIManager:scheduleIn(SAVE_DELAY_MS / 1000, self.pending_save)
end

function StylusAnnotations:saveStrokes()
    local filepath = self:getStrokesFilePath()
    if not filepath then
        logger.warn("StylusAnnotations: no sidecar dir available, skipping save")
        return
    end
    local sidecar_dir = self.ui.doc_settings.doc_sidecar_dir
    if sidecar_dir then
        local ok, err = lfs.mkdir(sidecar_dir)
        if not ok and err ~= "File exists" then
            logger.warn("StylusAnnotations: failed to create sidecar dir:", err)
        end
    end
    local data = { version = 1, strokes = self.strokes }
    local f, err = io.open(filepath, "w")
    if f then
        f:write("return " .. require("dump")(data))
        f:close()
    else
        logger.err("StylusAnnotations: failed to write strokes:", err)
    end
end

function StylusAnnotations:loadStrokes()
    local filepath = self:getStrokesFilePath()
    self.strokes = {}
    self.strokes_by_page = {}
    self.bookmarked_pages = {}
    self.strokes_loaded = true
    if not filepath then return end
    local f = io.open(filepath, "r")
    if not f then return end
    f:close()
    local ok, data = pcall(dofile, filepath)
    if ok and data and data.strokes then
        self.strokes = data.strokes
        self:rebuildPageIndex()
        logger.info("StylusAnnotations: loaded", #self.strokes, "strokes from", filepath)
    end
end

--------------------------------------------------------------------------------
-- Menu & Dispatcher
--------------------------------------------------------------------------------

function StylusAnnotations:onStylusAnnotationsToggle()
    self:setEnabled(not self:isEnabled())
    local state = self:isEnabled() and _("on") or _("off")
    UIManager:show(InfoMessage:new{
        text = T(_("Stylus annotations drawing: %1"), state),
        timeout = 1,
    })
    return true
end

function StylusAnnotations:addToMainMenu(menu_items)
    menu_items.stylus_annotations = {
        text = _("Stylus annotations"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Enable drawing"),
                checked_func = function()
                    return self:isEnabled()
                end,
                callback = function()
                    self:setEnabled(not self:isEnabled())
                    local state = self:isEnabled() and _("on") or _("off")
                    UIManager:show(InfoMessage:new{
                        text = T(_("Stylus annotations drawing: %1"), state),
                        timeout = 1,
                    })
                end,
            },
            {
                text = _("Live ink refresh"),
                checked_func = function()
                    return self.live_ink ~= false
                end,
                callback = function()
                    self.live_ink = not (self.live_ink ~= false)
                    self:saveSettings()
                    local state = self.live_ink and _("on") or _("off")
                    UIManager:show(InfoMessage:new{
                        text = T(_("Live ink refresh: %1"), state),
                        timeout = 1,
                    })
                end,
            },
            {
                text = _("Pen width"),
                sub_item_table = self:getWidthMenuItems(),
            },
            {
                text = _("Pen color"),
                callback = function()
                    self:choosePenColor()
                end,
            },
            {
                text = _("Delete all strokes"),
                callback = function()
                    self:deleteAllStrokes()
                end,
            },
        },
    }
end

function StylusAnnotations:getWidthMenuItems()
    local items = {}
    for _, w in ipairs(WIDTH_CHOICES) do
        items[#items + 1] = {
            text = tostring(w),
            checked_func = function()
                return self.width == w
            end,
            callback = function()
                self.width = w
                self:saveSettings()
            end,
        }
    end
    return items
end

function StylusAnnotations:deleteAllStrokes()
    local pages = {}
    for page, _ in pairs(self.strokes_by_page) do
        pages[#pages + 1] = page
    end
    UIManager:show(ConfirmBox:new{
        text = _("Delete all stylus annotations for this document?"),
        ok_text = _("Delete"),
        ok_callback = function()
            self.strokes = {}
            self:rebuildPageIndex()
            for _, page in ipairs(pages) do
                self:maybeRemoveBookmark(page)
            end
            self:scheduleSave()
            UIManager:setDirty(self.view, "partial")
        end,
    })
end

--------------------------------------------------------------------------------
-- Teardown
--------------------------------------------------------------------------------

function StylusAnnotations:onCloseDocument()
    if self.pending_save then
        UIManager:unschedule(self.pending_save)
        self.pending_save = nil
    end
    if self.hold_timer then
        UIManager:unschedule(self.hold_timer)
        self.hold_timer = nil
    end
    self.current_stroke = nil
    self:teardownStylusCallback()
    self:saveStrokes()
end

return StylusAnnotations

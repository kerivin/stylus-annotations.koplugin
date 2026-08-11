local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Geometry = require("lib/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local ReaderHighlight = require("apps/reader/modules/readerhighlight")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonSelector = require("ui/widget/buttonselector")
local InputDialog = require("ui/widget/inputdialog")
local SpinWidget = require("ui/widget/spinwidget")
local Widget = require("ui/widget/widget")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local dbg = require("dbg")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen

local COORD_SCALE = 4

local function pack(v)
    return math.floor(v * COORD_SCALE + 0.5)
end

local function unpack(v)
    return v / COORD_SCALE
end

local function stampDisc(bb, cx, cy, r, color)
    local r2 = r * r
    local cyi = math.floor(cy)
    for dy = -math.floor(r), math.floor(r) do
        local span = math.floor(math.sqrt(r2 - dy * dy) + 0.5)
        if span > 0 then
            bb:paintRectRGB32(math.floor(cx) - span, cyi + dy, 2 * span + 1, 1, color)
        end
    end
end

local function stampPath(bb, pts, ox, oy, r, color)
    local n = #pts
    if n == 0 then return end
    local px, py = pts[1].x, pts[1].y
    stampDisc(bb, ox + px, oy + py, r, color)
    for i = 2, n do
        local nx, ny = pts[i].x, pts[i].y
        local dx, dy = nx - px, ny - py
        local dist_sq = dx * dx + dy * dy
        if dist_sq >= 1 then
            local steps = math.ceil(math.sqrt(dist_sq))
            for s = 1, steps do
                stampDisc(bb, ox + px + dx * (s / steps), oy + py + dy * (s / steps), r, color)
            end
        else
            stampDisc(bb, ox + nx, oy + ny, r, color)
        end
        px, py = nx, ny
    end
end

local SELECTION_WHITE = Blitbuffer.ColorRGB32(0xFF, 0xFF, 0xFF, 0xFF)

local TOOL_TYPE_PEN = Device.input.TOOL_TYPE_PEN

local HIT_TEST_THRESHOLD_PX = 25
local SAVE_DELAY_MS = 800
local HOLD_TIME_S = 0.45
local HOLD_MOVE_THRESHOLD_PX = 15
local LIVE_REFRESH_DELAY_S = 0.7

local DEFAULT_WIDTH = 2
local DEFAULT_COLOR = "orange"

local STORAGE_VERSION = 1

local WIDTH_CHOICES = { 1, 2, 3, 5, 8, 12 }

local PREVIEW_POINTS = {
    {10.8,1.1}, {8.3,4.3}, {6.2,14.0}, {4.3,28.0}, {2.9,40.9}, {1.4,55.9},
    {0.4,68.8}, {0.0,81.7}, {0.4,94.6}, {2.9,100.0}, {5.2,98.9}, {8.1,92.5},
    {10.1,86.0}, {12.6,78.5}, {15.1,69.9}, {17.6,61.3}, {20.1,52.7}, {22.6,43.0},
    {25.1,34.4}, {27.3,25.8}, {29.6,19.4}, {31.7,11.8}, {34.2,5.4}, {36.6,0.0},
    {38.9,1.1}, {39.3,12.9}, {39.1,26.9}, {38.9,38.7}, {39.1,54.8}, {41.0,66.7},
    {43.9,68.8}, {46.6,64.5}, {49.5,58.1}, {51.8,51.6}, {53.8,46.2}, {56.5,41.9},
    {59.2,39.8}, {62.1,43.0}, {64.2,49.5}, {66.5,60.2}, {68.9,66.7}, {72.5,66.7},
    {74.9,62.4}, {77.8,57.0}, {81.0,49.5}, {84.3,40.9}, {87.6,33.3}, {90.5,28.0},
    {93.0,22.6}, {95.9,19.4}, {98.1,20.4}, {99.6,31.2}, {100.0,38.7},
}

local WidthPreview = Widget:extend{
    dimen = nil,
    get_width = function() return 2 end,
    get_zoom = function() return 1 end,
    padding = 12,
    paintTo = function(self, bb, x, y)
        local w = self:get_width() * self:get_zoom()
        local pad = self.padding
        local draw_w = self.dimen.w - 2 * pad
        local draw_h = self.dimen.h - 2 * pad
        local pts = {}
        for i = 1, #PREVIEW_POINTS do
            pts[i] = {
                x = x + pad + PREVIEW_POINTS[i][1] / 100 * draw_w,
                y = y + pad + PREVIEW_POINTS[i][2] / 100 * draw_h,
            }
        end
        stampPath(bb, pts, 0, 0, w / 2, Blitbuffer.COLOR_BLACK)
    end,
}

local EXTRA_COLORS = {
    {_("Black"), "black", "#000000"},
    {_("White"), "white", "#FFFFFF"},
}

local EXTRA_COLOR_NAMES = {}
for _, c in ipairs(EXTRA_COLORS) do
    EXTRA_COLOR_NAMES[c[2]] = true
end

local COLOR_PALETTE = {}
for _, c in ipairs(ReaderHighlight.highlight_colors) do
    COLOR_PALETTE[#COLOR_PALETTE + 1] = { c[1], c[2] }
end
for _, c in ipairs(EXTRA_COLORS) do
    COLOR_PALETTE[#COLOR_PALETTE + 1] = { c[1], c[2] }
end

local COLOR_HEX = {}
for name, hex in pairs(Blitbuffer.HIGHLIGHT_COLORS) do
    COLOR_HEX[name] = hex
end
COLOR_HEX.gray = "#808080"
for _, c in ipairs(EXTRA_COLORS) do
    COLOR_HEX[c[2]] = c[3]
end

local COLOR_DISPLAY_NAMES = {}
for _, c in ipairs(COLOR_PALETTE) do
    COLOR_DISPLAY_NAMES[c[2]] = c[1]
end

local StylusAnnotations = InputContainer:extend{
    name = "stylus_annotations",
    is_doc_only = true,

    strokes = nil,
    strokes_by_page = nil,

    stylus_callback_registered = false,
    touch_zones_registered = false,

    current_stroke = nil,
    pen_x = 0,
    pen_y = 0,

    hold_timer = nil,
    hold_start_x = 0,
    hold_start_y = 0,

    selected_strokes = {},
    selection_backup = nil,
    selection_backup_x = 0,
    selection_backup_y = 0,
    dirty_region = nil,
    refresh_timer = nil,
    pending_save = nil,
}

function StylusAnnotations:init()
    self.strokes = {}
    self.strokes_by_page = {}
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

    dbg:turnOff()

    logger.info("StylusAnnotations: initialized, strokes =", #self.strokes)
end

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
    self.color = ds:readSetting("stylus_annotations_color") or DEFAULT_COLOR
end

function StylusAnnotations:saveSettings()
    local ds = self.ui.doc_settings
    ds:saveSetting("stylus_annotations_live_ink", self.live_ink ~= false)
    ds:saveSetting("stylus_annotations_width", self.width)
    ds:saveSetting("stylus_annotations_color", self.color)
end

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

    if Device:isEmulator() then
        self:setupTouchPenFallback()
    end
end

function StylusAnnotations:teardownStylusCallback()
    if not self.stylus_callback_registered then return end
    local Input = Device.input
    if Input and Input.unregisterStylusCallback then
        Input:unregisterStylusCallback()
    end
    self.stylus_callback_registered = false
end

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

function StylusAnnotations:isOverlayActive()
    local top = UIManager:getTopmostVisibleWidget()
    if not top then return false end
    return (top.name or top.id) ~= "ReaderUI"
end

function StylusAnnotations:onStylusEvent(input, slot)

    if self:isOverlayActive() then return false end

    if not self:isEnabled() then return false end

    if (slot.tool or TOOL_TYPE_PEN) ~= TOOL_TYPE_PEN then return false end

    local x, y = slot.x or 0, slot.y or 0
    if slot.id and slot.id >= 0 then

        if self.current_stroke then
            self:addStrokePoint(x, y)
        else
            self:startStroke(x, y)
        end
        self.pen_x, self.pen_y = x, y
    else

        if self.current_stroke then
            self:endStroke()
        end
    end

    return true
end

function StylusAnnotations:startStroke(x, y)
    local pos = self.ui.view:screenToPageTransform({ x = x, y = y })
    self.stroke_id_counter = self.stroke_id_counter + 1
    self.current_stroke = {
        id = tostring(self.stroke_id_counter),
        page = pos.page,
        points = { pos.x, pos.y },
        width = self.width,
        color = self.color,
        alpha = 1.0,
        zoom = pos.zoom or 1,
        datetime = os.time(),
    }
    self.pen_x, self.pen_y = x, y
    self.dirty_region = nil

    if self.refresh_timer then
        UIManager:unschedule(self.refresh_timer)
        self.refresh_timer = nil
    end

    self.live_dirty = nil

    if self.live_ink ~= false then
        if self.live_snapshot then
            self.live_snapshot:free()
            self.live_snapshot = nil
        end
        self.live_snapshot = Screen.bb:copy()
    end

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
    if pos.page ~= stroke.page then return end
    local pts = stroke.points
    local m = #pts
    if m >= 2 and pts[m - 1] == pos.x and pts[m] == pos.y then return end
    pts[m + 1], pts[m + 2] = pos.x, pos.y

    local sw = self:getStrokeScreenWidth(stroke)
    local half = math.floor(sw / 2)
    local seg_x = math.min(self.pen_x, x) - half
    local seg_y = math.min(self.pen_y, y) - half
    local seg_w = math.abs(x - self.pen_x) + sw
    local seg_h = math.abs(y - self.pen_y) + sw
    self:accumulateDirty(seg_x, seg_y, seg_w, seg_h)

    if self.live_ink ~= false then
        self.live_dirty = Geometry.mergeRect(self.live_dirty, seg_x, seg_y, seg_w, seg_h)
        self:flushLiveStroke(stroke)
    end

    self.pen_x, self.pen_y = x, y

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
    local rx, ry, rw, rh = Geometry.clampRect(
        ld.x, ld.y, ld.w, ld.h, Screen:getWidth(), Screen:getHeight())
    if rx then
        UIManager:setDirty(self.view, function()
            return "fast", Geom:new{x = rx, y = ry, w = rw, h = rh}
        end)
    end
end

function StylusAnnotations:flushLiveStroke(stroke)
    local ld = self.live_dirty
    if not ld or ld.w <= 0 or ld.h <= 0 then return end
    local bb = Screen.bb
    local x0, y0, x1, y1 = self:getStrokeScreenBox(stroke)
    if not x0 then return end
    local pad = math.ceil(self:getStrokeScreenWidth(stroke) / 2)
    x0 = math.max(0, math.floor(x0 - pad))
    y0 = math.max(0, math.floor(y0 - pad))
    x1 = math.min(bb:getWidth() - 1, math.ceil(x1 + pad))
    y1 = math.min(bb:getHeight() - 1, math.ceil(y1 + pad))
    local rw = x1 - x0 + 1
    local rh = y1 - y0 + 1
    if self.live_snapshot then
        bb:blitFrom(self.live_snapshot, x0, y0, x0, y0, rw, rh)
    end
    self.live_dirty = Geometry.mergeRect(ld, x0, y0, rw, rh)
    self:renderStrokeToScreen(stroke)
    self:flushLive()
end

function StylusAnnotations:cancelLive()
    self.live_dirty = nil
    if self.live_snapshot then
        self.live_snapshot:free()
        self.live_snapshot = nil
    end
    if self.refresh_timer then
        UIManager:unschedule(self.refresh_timer)
        self.refresh_timer = nil
    end
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

    self:scheduleSave()

    self:cancelLive()

    if self.live_ink == false then
        self:renderStrokeToScreen(stroke)
    end

    self:refreshRegion(region)
    if self.live_ink ~= false then
        self:scheduleRefresh()
    end
end

function StylusAnnotations:scheduleRefresh()
    if self.refresh_timer then
        UIManager:unschedule(self.refresh_timer)
    end
    local refresh_timer = function()
        self.refresh_timer = nil
        UIManager:setDirty(self.view, "full")
    end
    self.refresh_timer = refresh_timer
    UIManager:scheduleIn(LIVE_REFRESH_DELAY_S, refresh_timer)
end

function StylusAnnotations:decimatePoints(stroke)
    local pts = stroke.points
    local num = math.floor(#pts / 2)
    if num <= 2 then return pts end
    local MIN_SPACING = 2.0
    local kept = { pts[1], pts[2] }
    local kept_s = { self:pageToScreenPoint(stroke.page, pts[1], pts[2]) }
    local lx, ly = kept_s[1], kept_s[2]
    for i = 2, num - 1 do
        local xi, yi = pts[2 * i - 1], pts[2 * i]
        local sx, sy = self:pageToScreenPoint(stroke.page, xi, yi)
        local dx, dy = sx - lx, sy - ly
        if dx * dx + dy * dy >= MIN_SPACING * MIN_SPACING then
            kept[#kept + 1], kept[#kept + 2] = xi, yi
            kept_s[#kept_s + 1], kept_s[#kept_s + 2] = sx, sy
            lx, ly = sx, sy
        end
    end
    kept[#kept + 1], kept[#kept + 2] = pts[#pts - 1], pts[#pts]
    local lx2, ly2 = self:pageToScreenPoint(stroke.page, pts[#pts - 1], pts[#pts])
    kept_s[#kept_s + 1], kept_s[#kept_s + 2] = lx2, ly2

    local num_kept = math.floor(#kept / 2)
    if num_kept <= 3 then return kept end
    local tol = math.min(3.0, math.max(0.75, self:getStrokeScreenWidth(stroke) / 4))
    local idx = Geometry.rdpSimplifyIndices(kept_s, tol)
    if #idx == num_kept then return kept end
    local out = {}
    for p = 1, #idx do
        local k = idx[p]
        out[#out + 1] = kept[2 * k - 1]
        out[#out + 1] = kept[2 * k]
    end
    return out
end

function StylusAnnotations:renderStrokeToScreen(stroke)
    self:paintStroke(Screen.bb, 0, 0, stroke)
end

function StylusAnnotations:refreshRegion(region)

    if region then
        local rx, ry, rw, rh = Geometry.clampRect(
            region.x, region.y, region.w, region.h, Screen:getWidth(), Screen:getHeight())
        if rx then
            UIManager:setDirty(self.view, function()
                return "partial", Geom:new{x = rx, y = ry, w = rw, h = rh}
            end)
            return
        end
    end
    UIManager:setDirty(self.view, "partial")
end

function StylusAnnotations:onStrokeHoldTimer()
    local stroke = self.current_stroke
    if not stroke then return end
    local dx = self.pen_x - self.hold_start_x
    local dy = self.pen_y - self.hold_start_y
    if dx * dx + dy * dy > HOLD_MOVE_THRESHOLD_PX * HOLD_MOVE_THRESHOLD_PX then return end
    self:onStrokeCancel()
    self:showStrokeMenuAt(self.hold_start_x, self.hold_start_y)
end

function StylusAnnotations:onStrokeCancel()
    self.current_stroke = nil
    self.dirty_region = nil
    self:cancelLive()
    UIManager:setDirty(self.view, "partial")
end

function StylusAnnotations:showStrokeMenuAt(x, y)
    local stroke = self:findStrokeAt({ pos = { x = x, y = y } })
    if not stroke then return end
    self:showStrokeMenu({ stroke })
end

function StylusAnnotations:getStrokeScreenWidth(stroke)
    return math.max(1, math.floor(stroke.width * (stroke.zoom or 1) + 0.5))
end

function StylusAnnotations:colorDisplayName(name)
    return COLOR_DISPLAY_NAMES[name] or name
end

function StylusAnnotations:getPaletteColor(name)
    if self.ui.highlight and not EXTRA_COLOR_NAMES[name] then
        return self.ui.highlight:getHighlightColor(name, nil, Screen.night_mode)
    end
    local hex = COLOR_HEX[name]
    return hex and Blitbuffer.colorFromString(hex) or Blitbuffer.COLOR_BLACK
end

function StylusAnnotations:getRenderColor(stroke)
    local color = self:getPaletteColor(stroke.color)
    local rgb = color:getColorRGB32()
    local alpha = math.floor((stroke.alpha or 1.0) * 255)
    return Blitbuffer.ColorRGB32(rgb.r, rgb.g, rgb.b, alpha)
end

function StylusAnnotations:accumulateDirty(x, y, w, h)
    self.dirty_region = Geometry.mergeRect(self.dirty_region, x, y, w, h)
end

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

    for _, stroke in ipairs(self.selected_strokes) do
        local rx, ry, rw, rh = self:getSelectionRect(stroke, bb:getWidth(), bb:getHeight())
        if rx then
            bb:paintRect(rx, ry, rw, rh, Blitbuffer.COLOR_BLACK)
        end
    end
    for _, stroke in ipairs(self.selected_strokes) do
        self:paintStrokeSolid(bb, x, y, stroke, SELECTION_WHITE)
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
    local sw = self:getPageZoom(stroke.page) * stroke.width
    local pts = stroke.points
    local m = #pts
    if m == 0 then return end
    local sph = {}
    for i = 1, m, 2 do
        local sx, sy = self:pageToScreenPoint(stroke.page, pts[i], pts[i + 1])
        if not sx then return end
        sph[#sph + 1] = { x = x + sx, y = y + sy }
    end
    self:drawStrokePath(bb, sph, sw, color)
end

function StylusAnnotations:getStrokeScreenBox(stroke)
    local pts = stroke.points
    local m = #pts
    if m == 0 then return end
    local spts = {}
    for i = 1, m, 2 do
        local sx, sy = self:pageToScreenPoint(stroke.page, pts[i], pts[i + 1])
        if not sx then return end
        spts[#spts + 1], spts[#spts + 2] = sx, sy
    end
    return Geometry.screenBounds(spts)
end

function StylusAnnotations:getSelectionRect(stroke, width, height)
    local x0, y0, x1, y1 = self:getStrokeScreenBox(stroke)
    if not x0 then return end
    local pad = math.max(4, math.floor(stroke.width * (stroke.zoom or 1)) + 2)
    return Geometry.clampRect(x0 - pad, y0 - pad, (x1 - x0) + 2 * pad, (y1 - y0) + 2 * pad, width, height)
end

function StylusAnnotations:paintStrokeSolid(bb, x, y, stroke, color)
    local sw = self:getPageZoom(stroke.page) * stroke.width
    local pts = stroke.points
    local m = #pts
    if m == 0 then return end
    local sph = {}
    for i = 1, m, 2 do
        local sx, sy = self:pageToScreenPoint(stroke.page, pts[i], pts[i + 1])
        if not sx then return end
        sph[#sph + 1] = { x = x + sx, y = y + sy }
    end
    stampPath(bb, sph, 0, 0, sw / 2, color)
end

function StylusAnnotations:drawStrokePath(bb, sph, sw, color)
    local n = #sph
    if n == 0 then return end
    local half = math.floor(sw / 2)
    local min_x, min_y, max_x, max_y = Geometry.pointsBounds(sph)
    local box_x = math.max(0, math.floor(min_x - half))
    local box_y = math.max(0, math.floor(min_y - half))
    local box_w = math.ceil(max_x + half) - box_x
    local box_h = math.ceil(max_y + half) - box_y
    if box_w <= 0 or box_h <= 0 then return end
    box_w = math.min(bb:getWidth() - box_x, box_w)
    box_h = math.min(bb:getHeight() - box_y, box_h)
    if box_w <= 0 or box_h <= 0 then return end

    local mask = Blitbuffer.new(box_w, box_h, bb:getType())
    if not mask then return end
    mask:paintRect(0, 0, box_w, box_h, Blitbuffer.COLOR_WHITE)

    stampPath(mask, sph, -box_x, -box_y, sw / 2, color)

    if bb:getInverse() == 1 then
        local rb = color:getColorRGB32()
        local inv = Blitbuffer.ColorRGB32(rb.r, rb.g, rb.b, 0xFF):invert()
        bb:blendRectRGB32(box_x, box_y, box_w, box_h, inv)
    else
        bb:blitFrom(mask, box_x, box_y, 0, 0, box_w, box_h, bb.setPixelMultiply)
    end
    mask:free()
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
                "readerfooter_tap",
                "readerconfigmenu_tap",
                "readerconfigmenu_ext_tap",
                "tap_forward",
                "tap_backward",
                "readermenu_tap",
                "readermenu_ext_tap",
                "tap_top_left_corner",
                "tap_top_right_corner",
                "tap_left_bottom_corner",
                "tap_right_bottom_corner",
            },
            handler = function(ges)
                return self:onStrokeTap(ges)
            end,
        },

        {
            id = "stylus_annotations_hold",
            ges = "hold",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "readerhighlight_hold",
                "readerfooter_hold",
            },
            handler = function(ges)
                return self:onStrokeHold(ges)
            end,
        },
    })
    self.touch_zones_registered = true
end

function StylusAnnotations:onStrokeTap(ges)
    if self:isOverlayActive() then return false end
    local stroke = self:findStrokeAt(ges)
    if not stroke then

        return false
    end
    self:showStrokeMenu({ stroke })
    return true
end

function StylusAnnotations:onStrokeHold(ges)
    if self:isOverlayActive() then return false end
    local stroke = self:findStrokeAt(ges)
    if not stroke then

        return false
    end
    self:showStrokeMenu(self:selectStrokesChain(stroke))
    return true
end

function StylusAnnotations:selectStrokesChain(stroke)
    local selection = { stroke }
    local seen = { [stroke] = true }
    local queue = { stroke }
    local i = 1
    while i <= #queue do
        local cur = queue[i]
        i = i + 1
        for _, s in ipairs(self.strokes) do
            if not seen[s] and s.page == cur.page and Geometry.strokesIntersect(cur, s) then
                seen[s] = true
                selection[#selection + 1] = s
                queue[#queue + 1] = s
            end
        end
    end
    return selection
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

function StylusAnnotations:selectionsEqual(a, b)
    if #a ~= #b then return false end
    for _, sa in ipairs(a) do
        local found = false
        for _, sb in ipairs(b) do
            if sa == sb then
                found = true
                break
            end
        end
        if not found then return false end
    end
    return true
end

function StylusAnnotations:setSelection(strokes)
    if self:selectionsEqual(self.selected_strokes, strokes) then return end
    if #self.selected_strokes > 0 then self:clearSelection() end
    self.selected_strokes = strokes

    self:grabSelectionBackup()
    self:paintSelectionToScreen()
end

function StylusAnnotations:clearSelection()
    if #self.selected_strokes == 0 then return end
    self.selected_strokes = {}
    self:restoreSelectionBackup()
end

function StylusAnnotations:grabSelectionBackup()
    local width, height = Screen:getWidth(), Screen:getHeight()
    local x0, y0, x1, y1
    for _, stroke in ipairs(self.selected_strokes) do
        local rx, ry, rw, rh = self:getSelectionRect(stroke, width, height)
        if rx then
            if not x0 or rx < x0 then x0 = rx end
            if not y0 or ry < y0 then y0 = ry end
            if not x1 or rx + rw > x1 then x1 = rx + rw end
            if not y1 or ry + rh > y1 then y1 = ry + rh end
        end
    end
    if not x0 then return end
    local bw, bh = x1 - x0, y1 - y0
    if self.selection_backup then self.selection_backup:free() end
    self.selection_backup = Blitbuffer.new(bw, bh, Screen.bb:getType())
    self.selection_backup:blitFrom(Screen.bb, 0, 0, x0, y0, bw, bh)
    self.selection_backup_x, self.selection_backup_y = x0, y0
end

function StylusAnnotations:paintSelectionToScreen()
    local width, height = Screen:getWidth(), Screen:getHeight()
    for _, stroke in ipairs(self.selected_strokes) do
        local rx, ry, rw, rh = self:getSelectionRect(stroke, width, height)
        if rx then
            Screen.bb:paintRect(rx, ry, rw, rh, Blitbuffer.COLOR_BLACK)
        end
    end
    for _, stroke in ipairs(self.selected_strokes) do
        self:paintStrokeSolid(Screen.bb, 0, 0, stroke, SELECTION_WHITE)
    end
    self:refreshRegion()
end

function StylusAnnotations:restoreSelectionBackup()
    local backup = self.selection_backup
    if backup then
        local x, y = self.selection_backup_x, self.selection_backup_y
        local w, h = backup:getWidth(), backup:getHeight()
        Screen.bb:blitFrom(backup, x, y, 0, 0, w, h)
        backup:free()
        self.selection_backup = nil
        self:refreshRegion({ x = x, y = y, w = w, h = h })
    end
end

function StylusAnnotations:getSelectionUnionBox(strokes)
    local x0, y0, x1, y1
    for _, stroke in ipairs(strokes) do
        local sx0, sy0, sx1, sy1 = self:getStrokeScreenBox(stroke)
        if sx0 then
            if not x0 or sx0 < x0 then x0 = sx0 end
            if not y0 or sy0 < y0 then y0 = sy0 end
            if not x1 or sx1 > x1 then x1 = sx1 end
            if not y1 or sy1 > y1 then y1 = sy1 end
        end
    end
    return x0, y0, x1, y1
end

function StylusAnnotations:showStrokeMenu(strokes)
    self:setSelection(strokes)
    local dialog
    dialog = ButtonDialog:new{
        width_factor = 0.45,
        anchor = function()
            local x0, y0, x1, y1 = self:getSelectionUnionBox(strokes)
            if not x0 then return end
            local pad = math.max(4, math.floor(strokes[1].width * (strokes[1].zoom or 1)) + 2)
            return { x = x0 - pad, y = y0 - pad, w = (x1 - x0) + 2 * pad, h = (y1 - y0) + 2 * pad }
        end,
        tap_close_callback = function()
            self:clearSelection()
        end,
        buttons = {
            {
                {
                    text = "\u{F48E}",
                    callback = function()
                        local count = #strokes
                        self:clearSelection()
                        UIManager:close(dialog)
                        self:deleteStrokes(strokes, count > 1)
                    end,
                },
                {
                    text = _("Color"),
                    callback = function()
                        self:clearSelection()
                        UIManager:close(dialog)
                        self:chooseStrokeColor(strokes)
                    end,
                },
                {
                    text = _("Width"),
                    callback = function()
                        self:clearSelection()
                        UIManager:close(dialog)
                        self:chooseStrokeWidth(strokes)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog, "[ui]")
end

function StylusAnnotations:chooseStrokeColor(strokes)
    self:showColorPicker(strokes[1].color, function(value)
        self:setStrokeColor(strokes, value)
    end)
end

function StylusAnnotations:choosePenColor()
    self:showColorPicker(self.color, function(value)
        self.color = value
        self:saveSettings()
    end)
end

function StylusAnnotations:showColorPicker(current, apply)

    local values = {}
    for i, c in ipairs(COLOR_PALETTE) do
        values[i] = { c[1], c[2], self:getPaletteColor(c[2]) }
    end
    local selector
    selector = ButtonSelector:new{
        current_value = current,
        values = values,
        callback = function(value)
            apply(value)
            UIManager:close(selector)
        end,
    }
    UIManager:show(selector)
end

function StylusAnnotations:chooseStrokeWidth(strokes)
    self:showWidthPicker{
        start = strokes[1].width,
        on_apply = function(value)
            self:setStrokeWidth(strokes, value)
        end,
    }
end

function StylusAnnotations:setStrokeColor(strokes, color)
    for _, stroke in ipairs(strokes) do
        stroke.color = color
    end
    self:afterStrokeModified(strokes[1])
end

function StylusAnnotations:setStrokeWidth(strokes, width)
    for _, stroke in ipairs(strokes) do
        stroke.width = width
    end
    self:afterStrokeModified(strokes[1])
end

function StylusAnnotations:afterStrokeModified(stroke)
    self:scheduleSave()
    UIManager:setDirty(self.view, "partial")
end

function StylusAnnotations:deleteStrokes(strokes, notify)
    local to_delete = {}
    for _, stroke in ipairs(strokes) do
        to_delete[stroke] = true
    end
    local keep = {}
    local removed = 0
    for _, stroke in ipairs(self.strokes) do
        if to_delete[stroke] then
            removed = removed + 1
        else
            keep[#keep + 1] = stroke
        end
    end
    self.strokes = keep
    self:rebuildPageIndex()
    self:scheduleSave()
    UIManager:setDirty(self.view, "partial")
    if notify ~= false then
        self:notifyStrokeDeleted(removed)
    end
end

function StylusAnnotations:notifyStrokeDeleted(count)
    local text
    if count == 1 then
        text = _("1 stroke deleted")
    else
        text = T(_("%1 strokes deleted"), count)
    end
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = 2,
    })
end

function StylusAnnotations:rebuildPageIndex()
    self.strokes_by_page = {}
    for i, stroke in ipairs(self.strokes) do
        self.strokes_by_page[stroke.page] = self.strokes_by_page[stroke.page] or {}
        table.insert(self.strokes_by_page[stroke.page], i)
    end
end

function StylusAnnotations:getStrokesFilePath()
    local sidecar_dir = self.ui.doc_settings and self.ui.doc_settings.doc_sidecar_dir
    if sidecar_dir then
        return sidecar_dir .. "/stylus_annotations.lua"
    end
    return nil
end

function StylusAnnotations:scheduleSave()

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
    local strokes = self.strokes
    if #strokes == 0 then
        if lfs.attributes(filepath, "mode") == "file" then
            os.remove(filepath)
            logger.info("StylusAnnotations: no strokes, removed", filepath)
        end
        return
    end
    local sidecar_dir = self.ui.doc_settings.doc_sidecar_dir
    if sidecar_dir then
        local ok, err = lfs.mkdir(sidecar_dir)
        if not ok and err ~= "File exists" then
            logger.warn("StylusAnnotations: failed to create sidecar dir:", err)
        end
    end
    local out = { "return {", tostring(STORAGE_VERSION), ",strokes={" }
    for i = 1, #strokes do
        local stroke = strokes[i]
        if i > 1 then out[#out + 1] = "," end
        local pts = stroke.points
        local coords = {}
        for j = 1, #pts do
            coords[#coords + 1] = tostring(pack(pts[j]))
        end
        out[#out + 1] = "{id=" .. string.format("%q", tostring(stroke.id))
        out[#out + 1] = ",page=" .. tostring(stroke.page)
        out[#out + 1] = ",points={" .. table.concat(coords, ",") .. "}"
        out[#out + 1] = ",width=" .. tostring(stroke.width)
        out[#out + 1] = ",color=" .. string.format("%q", stroke.color)
        if (stroke.zoom or 1) ~= 1 then
            out[#out + 1] = ",zoom=" .. tostring(stroke.zoom or 1)
        end
        if (stroke.alpha or 1) ~= 1 then
            out[#out + 1] = ",alpha=" .. tostring(stroke.alpha or 1)
        end
        out[#out + 1] = ",datetime=" .. tostring(stroke.datetime or 0)
        out[#out + 1] = "}"
    end
    out[#out + 1] = "}}\n"

    local f, err = io.open(filepath, "w")
    if f then
        f:write(table.concat(out))
        f:close()
        logger.info("StylusAnnotations: saved", #strokes, "strokes")
    else
        logger.err("StylusAnnotations: failed to write strokes:", err)
    end
end

function StylusAnnotations:loadStrokes()
    local filepath = self:getStrokesFilePath()
    self.strokes = {}
    self.strokes_by_page = {}
    if not filepath then return end
    local f = io.open(filepath, "r")
    if not f then return end
    f:close()
    local ok, data = pcall(dofile, filepath)
    if ok and data and data.strokes then
        local saved_version = self:migrateStrokes(data)
        for _, stroke in ipairs(data.strokes) do
            local pts = stroke.points
            for i = 1, #pts do
                pts[i] = unpack(pts[i])
            end
            stroke.alpha = stroke.alpha or 1.0
            stroke.zoom = stroke.zoom or 1
        end
        self.strokes = data.strokes
        self:rebuildPageIndex()
        logger.info("StylusAnnotations: loaded", #self.strokes, "strokes from", filepath)
        if saved_version ~= STORAGE_VERSION then
            self:scheduleSave()
        end
    end
end

function StylusAnnotations:migrateStrokes(data)
    local version = data.version or STORAGE_VERSION
    if version > STORAGE_VERSION then
        logger.warn("StylusAnnotations: sidecar version", version,
            "newer than supported", STORAGE_VERSION, "; attempting to load anyway")
    end
    for v = version, STORAGE_VERSION - 1 do
        self:upgradeStrokesVersion(data, v)
    end
    data.version = STORAGE_VERSION
    return version
end

function StylusAnnotations:upgradeStrokesVersion(data, from)
    if from == STORAGE_VERSION then return end
end

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
        sorting_hint = "typeset",
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
                text = _("Live refresh"),
                checked_func = function()
                    return self.live_ink ~= false
                end,
                callback = function()
                    self.live_ink = (self.live_ink == false)
                    self:saveSettings()
                    local state = self.live_ink and _("on") or _("off")
                    UIManager:show(InfoMessage:new{
                        text = T(_("Live refresh: %1"), state),
                        timeout = 1,
                    })
                end,
            },
            {
                text_func = function()
                    return T(_("Width: %1"), self.width)
                end,
                callback = function()
                    self:choosePenWidth()
                end,
            },
            {
                text_func = function()
                    return T(_("Color: %1"), self:colorDisplayName(self.color))
                end,
                callback = function()
                    self:choosePenColor()
                end,
            },
            {
                text = _("Delete strokes on the current page"),
                callback = function()
                    self:deleteAllStrokesOnPage()
                end,
            },
            {
                text = _("Delete all strokes in the document"),
                callback = function()
                    self:deleteAllStrokes()
                end,
            },
        },
    }
end

function StylusAnnotations:choosePenWidth()
    self:showWidthPicker{
        start = self.width,
        on_apply = function(value)
            self.width = value
            self:saveSettings()
        end,
    }
end

function StylusAnnotations:showWidthPicker(opts)
    local zoom = self:getPageZoom((self:getVisiblePages() or {})[1])
    local start = opts.start or self.width
    local on_apply = opts.on_apply

    local index, use_presets = nil, false
    for i, w in ipairs(WIDTH_CHOICES) do
        if w == start then index, use_presets = i, true break end
    end

    local spin
    spin = SpinWidget:new{
        title_text = _("Width..."),
        wrap = true,
        value_table = use_presets and WIDTH_CHOICES or nil,
        value_index = index,
        value = start,
        value_min = 1,
        value_max = 30,
        value_step = 1,
        value_hold_step = 2,
        precision = "%d",
        ok_always_enabled = true,
        extra_text = _("Custom..."),
        extra_callback = function()

            local input_dialog
            input_dialog = InputDialog:new{
                title = _("Custom width"),
                input_type = "number",
                input_hint = T(_("%1 - %2 (current: %3)"), 1, 30, start),
                buttons = {
                    {
                        {
                            text = _("Cancel"),
                            id = "close",
                            callback = function()
                                UIManager:close(input_dialog)
                            end,
                        },
                        {
                            text = _("OK"),
                            is_enter_default = true,
                            callback = function()
                                local v = tonumber(input_dialog:getInputText())
                                if v and v >= 1 and v <= 30 then
                                    v = math.floor(v + 0.5)
                                    UIManager:close(input_dialog)
                                    self:showWidthPicker{
                                        start = v,
                                        on_apply = on_apply,
                                    }
                                else
                                    UIManager:show(InfoMessage:new{
                                        text = _("Invalid width (1 - 30)"),
                                        timeout = 2,
                                    })
                                end
                            end,
                        },
                    },
                },
            }
            UIManager:show(input_dialog)
        end,
        callback = function()
            on_apply(spin.value_widget:getValue())
        end,
    }

    local avail_w = spin:getAddedWidgetAvailableWidth()
    local ph = math.floor(avail_w / 5.2)
    spin:addWidget(WidthPreview:new{
        dimen = Geom:new{ w = avail_w, h = ph },
        get_zoom = function() return zoom end,
        get_width = function()
            return spin.value_widget and spin.value_widget:getValue() or start
        end,
    })
    UIManager:show(spin)
end

function StylusAnnotations:deleteAllStrokesOnPage()
    local pages = self:getVisiblePages()
    if not pages then return end
    local count = 0
    for _, page in ipairs(pages) do
        count = count + #(self.strokes_by_page[page] or {})
    end
    if count == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No strokes to delete."),
            timeout = 2,
        })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete all %1 strokes on this page?"), count),
        ok_text = _("Delete"),
        ok_callback = function()
            local keep = {}
            local removed = 0
            for i, stroke in ipairs(self.strokes) do
                local remove = false
                for _, page in ipairs(pages) do
                    if stroke.page == page then
                        remove = true
                        break
                    end
                end
                if remove then
                    removed = removed + 1
                else
                    keep[#keep + 1] = stroke
                end
            end
            self.strokes = keep
            self:rebuildPageIndex()
            self:scheduleSave()
            UIManager:setDirty(self.view, "partial")
            self:notifyStrokeDeleted(removed)
        end,
    })
end

function StylusAnnotations:deleteAllStrokes()
    local total = #self.strokes
    if total == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No strokes to delete."),
            timeout = 2,
        })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete all %1 strokes for this document?"), total),
        ok_text = _("Delete"),
        ok_callback = function()
            self.strokes = {}
            self:rebuildPageIndex()
            self:scheduleSave()
            UIManager:setDirty(self.view, "partial")
            self:notifyStrokeDeleted(total)
        end,
    })
end

function StylusAnnotations:onCloseDocument()
    if self.pending_save then
        UIManager:unschedule(self.pending_save)
        self.pending_save = nil
    end
    if self.hold_timer then
        UIManager:unschedule(self.hold_timer)
        self.hold_timer = nil
    end
    if self.refresh_timer then
        UIManager:unschedule(self.refresh_timer)
        self.refresh_timer = nil
    end
    self.current_stroke = nil
    self:teardownStylusCallback()
    self:saveStrokes()
end

return StylusAnnotations


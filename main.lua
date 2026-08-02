--[[--
Stylus annotations.

Freehand pen & highlighter annotations for PDF documents, driven by the stylus
callback API (Input:registerStylusCallback).

Strokes are stored in native page coordinates (top-left origin, y pointing
down), which is exactly the space MuPDF's ink annotations expect: points
captured with ReaderView:screenToPageTransform are stored verbatim (no y-flip,
no rotation handling: KOReader rotates the framebuffer, not the document).

Persistence is sidecar-only for now (<sidecar_dir>/stylus_annotations.lua).
Native PDF /Ink writing is not implemented yet.

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
local TouchMenu = require("ui/widget/touchmenu")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local time = require("ui/time")

local Screen = Device.screen

local TOOL_TYPE_PEN = 1
local TOOL_TYPE_HIGHLIGHTER = 3

local HIT_TEST_THRESHOLD_PX = 25
local REFRESH_INTERVAL_MS = 33
local SAVE_DELAY_MS = 800

local DEFAULT_WIDTH = 3
local DEFAULT_HIGHLIGHTER_WIDTH = 20
local DEFAULT_COLOR = "yellow"

local WIDTH_CHOICES = { 2, 3, 5, 8, 12 }

-- Shared with ReaderHighlight's text-highlight palette.
local COLOR_PALETTE = {
    {_("Red"), "red"},
    {_("Orange"), "orange"},
    {_("Yellow"), "yellow"},
    {_("Green"), "green"},
    {_("Olive"), "olive"},
    {_("Cyan"), "cyan"},
    {_("Blue"), "blue"},
    {_("Purple"), "purple"},
    {_("Gray"), "gray"},
}

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
    current_stroke_zoom = 1,
    pen_x = 0,
    pen_y = 0,

    last_refresh_time = 0,
    refresh_interval_ms = REFRESH_INTERVAL_MS,
    dirty_region = nil,

    pending_save = nil,
}

function StylusAnnotations:init()
    self.strokes = {}
    self.strokes_by_page = {}
    self.bookmarked_pages = {}
    self._page_dimen = {}
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
    self.width = ds:readSetting("stylus_annotations_width") or DEFAULT_WIDTH
    self.highlighter_width = ds:readSetting("stylus_annotations_highlighter_width")
        or DEFAULT_HIGHLIGHTER_WIDTH
    self.color = ds:readSetting("stylus_annotations_color") or DEFAULT_COLOR
end

function StylusAnnotations:saveSettings()
    local ds = self.ui.doc_settings
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
    if not Input or not Input.registerStylusCallback then
        logger.warn("StylusAnnotations: stylus callback API not available")
        return
    end
    local plugin = self
    Input:registerStylusCallback(function(input, slot)
        return plugin:onStylusEvent(input, slot)
    end)
    self.stylus_callback_registered = true
end

function StylusAnnotations:teardownStylusCallback()
    if not self.stylus_callback_registered then return end
    local Input = Device.input
    if Input and Input.unregisterStylusCallback then
        Input:unregisterStylusCallback()
    end
    self.stylus_callback_registered = false
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
        -- Contact lifted.
        if self.current_stroke then
            self:endStroke()
        end
    end

    -- Dominate: keep this pen event away from gesture detection.
    return true
end

--------------------------------------------------------------------------------
-- Live drawing
--------------------------------------------------------------------------------

function StylusAnnotations:getPageDimen(page)
    local dimen = self._page_dimen[page]
    if dimen then return dimen end
    local doc = self.ui.document
    if not doc or not doc.getPageDimensions then return nil end
    local rect = doc:getPageDimensions(page)
    if not rect or not rect.w or not rect.h then return nil end
    dimen = { w = rect.w, h = rect.h }
    self._page_dimen[page] = dimen
    return dimen
end

-- Reject points outside the native page bounds, so strokes can't be started
-- or continued over the footer/UI chrome (which would otherwise be stored as
-- off-page coordinates and mis-rendered later).
function StylusAnnotations:isPointInPage(pos)
    local dimen = self:getPageDimen(pos.page)
    if not dimen then return true end -- can't determine bounds: don't block
    return pos.x >= 0 and pos.y >= 0 and pos.x <= dimen.w and pos.y <= dimen.h
end

function StylusAnnotations:startStroke(x, y, tool)
    local pos = self.ui.view:screenToPageTransform({ x = x, y = y })
    if not self:isPointInPage(pos) then return end
    self.stroke_id_counter = self.stroke_id_counter + 1
    self.current_stroke = {
        id = tostring(self.stroke_id_counter),
        page = pos.page,
        tool = tool == TOOL_TYPE_HIGHLIGHTER and "highlighter" or "pen",
        points = { { x = pos.x, y = pos.y } },
        width = tool == TOOL_TYPE_HIGHLIGHTER and self.highlighter_width or self.width,
        color = self.color,
        alpha = tool == TOOL_TYPE_HIGHLIGHTER and 0.5 or 1.0,
        datetime = os.time(),
    }
    self.current_stroke_zoom = pos.zoom or 1
    self.last_refresh_time = time.now()
    self.dirty_region = nil

    -- Draw the first point immediately (a dot).
    local sw = self:getStrokeScreenWidth(self.current_stroke)
    local color = self:getRenderColor(self.current_stroke)
    local half = math.floor(sw / 2)
    Screen.bb:blendRectRGB32(x - half, y - half, sw, sw, color)
    self:accumulateDirty(x - half, y - half, sw, sw)
end

function StylusAnnotations:addStrokePoint(x, y)
    local stroke = self.current_stroke
    if not stroke then return end
    local pos = self.ui.view:screenToPageTransform({ x = x, y = y })
    if pos.page ~= stroke.page then return end -- should not happen mid-stroke
    if not self:isPointInPage(pos) then return end
    local last = stroke.points[#stroke.points]
    if last and last.x == pos.x and last.y == pos.y then return end
    table.insert(stroke.points, { x = pos.x, y = pos.y })

    -- Fast path: draw the new segment straight to the framebuffer, then
    -- refresh the dirty region on a throttle. The view-module repaint that
    -- follows stroke end redraws everything cleanly from stored coordinates.
    local sw = self:getStrokeScreenWidth(stroke)
    local color = self:getRenderColor(stroke)
    local x1, y1 = self.pen_x, self.pen_y
    local half = math.floor(sw / 2)
    self:drawSegment(Screen.bb, x1, y1, x, y, sw, color)
    self:accumulateDirty(math.min(x1, x) - half, math.min(y1, y) - half,
        math.abs(x - x1) + sw, math.abs(y - y1) + sw)

    local now = time.now()
    if time.to_ms(now - self.last_refresh_time) >= self.refresh_interval_ms then
        self.last_refresh_time = now
        self:flushDirtyRegion()
    end
end

function StylusAnnotations:endStroke()
    local stroke = self.current_stroke
    self.current_stroke = nil
    self.current_stroke_zoom = 1
    self.dirty_region = nil
    if not stroke or #stroke.points == 0 then return end

    table.insert(self.strokes, stroke)
    local idx = #self.strokes
    self.strokes_by_page[stroke.page] = self.strokes_by_page[stroke.page] or {}
    table.insert(self.strokes_by_page[stroke.page], idx)

    self:ensureBookmark(stroke.page)
    self:scheduleSave()

    -- Full repaint: replaces the raw framebuffer drawing with the
    -- view-module rendering of all strokes.
    UIManager:setDirty(self.view, "partial")
end

function StylusAnnotations:getStrokeScreenWidth(stroke)
    return math.max(1, math.floor(stroke.width * self.current_stroke_zoom + 0.5))
end

function StylusAnnotations:getRenderColor(stroke)
    local c = self.ui.highlight
        and self.ui.highlight:getHighlightColor(stroke.color)
        or Blitbuffer.COLOR_BLACK
    local rgb = c:getColorRGB32()
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

function StylusAnnotations:flushDirtyRegion()
    local r = self.dirty_region
    if not r then return end
    self.dirty_region = nil
    local rx = math.max(0, math.floor(r.x))
    local ry = math.max(0, math.floor(r.y))
    local rw = math.min(Screen:getWidth() - rx, math.ceil(r.w))
    local rh = math.min(Screen:getHeight() - ry, math.ceil(r.h))
    if rw > 0 and rh > 0 then
        Screen:refreshUI(rx, ry, rw, rh)
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
    local prev_sx, prev_sy
    for i = 1, n do
        local sx, sy = self:pageToScreenPoint(stroke.page, pts[i].x, pts[i].y)
        if not sx then return end
        if i == 1 then
            self:drawDot(bb, x + sx, y + sy, sw, color, alpha)
        else
            self:drawSegment(bb, x + prev_sx, y + prev_sy, x + sx, y + sy, sw, color, alpha)
        end
        prev_sx, prev_sy = sx, sy
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

function StylusAnnotations:drawDot(bb, x, y, width, color, alpha)
    local half = math.floor(width / 2)
    bb:blendRectRGB32(x - half, y - half, width, width, color)
end

function StylusAnnotations:drawSegment(bb, x1, y1, x2, y2, width, color, alpha)
    local dx, dy = x2 - x1, y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)
    local half = math.floor(width / 2)
    local function drawPixel(px, py)
        bb:blendRectRGB32(px - half, py - half, width, width, color)
    end
    if dist < 1 then
        drawPixel(x1, y1)
        return
    end
    local steps = math.max(1, math.ceil(dist))
    for i = 0, steps do
        drawPixel(math.floor(x1 + dx * i / steps), math.floor(y1 + dy * i / steps))
    end
end

--------------------------------------------------------------------------------
-- Gestures (stroke editing)
--------------------------------------------------------------------------------

function StylusAnnotations:setupTouchZones()
    if self.touch_zones_registered then return end
    self.ui:registerTouchZones({
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

function StylusAnnotations:onStrokeHold(ges)
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
    local menu = {}
    menu[#menu + 1] = {
        text = _("Delete stroke"),
        callback = function()
            self:deleteStroke(stroke)
        end,
    }

    local color_items = {}
    for _, c in ipairs(COLOR_PALETTE) do
        color_items[#color_items + 1] = {
            text = c[1],
            checked_func = function()
                return stroke.color == c[2]
            end,
            callback = function()
                self:setStrokeColor(stroke, c[2])
            end,
        }
    end
    menu[#menu + 1] = {
        text = _("Color"),
        sub_item_table = color_items,
    }

    local width_items = {}
    for _, w in ipairs(WIDTH_CHOICES) do
        width_items[#width_items + 1] = {
            text = tostring(w),
            checked_func = function()
                return stroke.width == w
            end,
            callback = function()
                self:setStrokeWidth(stroke, w)
            end,
        }
    end
    menu[#menu + 1] = {
        text = _("Width"),
        sub_item_table = width_items,
    }

    UIManager:show(TouchMenu:new{ items = menu })
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
-- Native PDF ink annotations
--------------------------------------------------------------------------------

function StylusAnnotations:getPageStrokes(page)
    local strokes = {}
    for _, idx in ipairs(self.strokes_by_page[page] or {}) do
        strokes[#strokes + 1] = self.strokes[idx]
    end
    return strokes
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
        sorting_hint = "more_tools",
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
                text = _("Pen width"),
                sub_item_table = self:getWidthMenuItems(),
            },
            {
                text = _("Pen color"),
                sub_item_table = self:getColorMenuItems(),
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

function StylusAnnotations:getColorMenuItems()
    local items = {}
    for _, c in ipairs(COLOR_PALETTE) do
        items[#items + 1] = {
            text = c[1],
            checked_func = function()
                return self.color == c[2]
            end,
            callback = function()
                self.color = c[2]
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
    self.current_stroke = nil
    self:teardownStylusCallback()
    self:saveStrokes()
end

return StylusAnnotations

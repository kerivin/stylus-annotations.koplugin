local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Geometry = require("core/geometry")
local Draw = require("core/draw")
local PagedAdapter = require("core/adapters/paged")
local ReflowAdapter = require("core/adapters/reflow")
local StrokeStore = require("core/store")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Event = require("ui/event")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonSelector = require("ui/widget/buttonselector")
local InputDialog = require("ui/widget/inputdialog")
local SpinWidget = require("ui/widget/spinwidget")
local Widget = require("ui/widget/widget")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local dbg = require("dbg")
local util = require("util")
local time = require("ui/time")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen

local Version = require("version")

local MIN_KOREADER_VERSION = 202607020060 -- nightly v2026.07.2-60-g74f37d14c
local current_version = Version:getNormalizedCurrentVersion()

if not current_version or current_version < MIN_KOREADER_VERSION then
    local warned = false
    local IncompatibleVersion = InputContainer:extend{
        name = "stylus_annotations",
        is_doc_only = true,
        init = function()
            if warned then return end
            warned = true
            UIManager:show(InfoMessage:new{
                text = T(
                    _("The Stylus annotations plugin requires 202607020060 (nightly) build of KOReader from 2026.08.12 or later.\n"
                      .. "Current version: %1"),
                    Version:getShortVersion()),
            })
        end,
    }
    return IncompatibleVersion
end

local TOOL_TYPE_PEN = Device.input.TOOL_TYPE_PEN

local SAVE_DELAY_MS = 800
local HOLD_MOVE_THRESHOLD_PX = 15
local LIVE_REFRESH_INTERVAL_MS = 33
local PEN_GRACE_TIME_S = 1.0

local DEFAULT_HOLD_INTERVAL_MS = 500

local DEFAULT_WIDTH = 2
local DEFAULT_COLOR = "orange"
local WIDTH_CHOICES = { 1, 2, 3, 5, 8, 12 }

local active_plugin = nil
local gesture_hook_added = false

local function holdIntervalSeconds()
    local ms = G_reader_settings:readSetting("ges_hold_interval_ms") or DEFAULT_HOLD_INTERVAL_MS
    return ms / 1000
end

local function installGestureHook()
    local Input = Device.input
    if not Input or not Input.registerGestureAdjustHook then return end
    if gesture_hook_added then return end
    gesture_hook_added = true
    Input:registerGestureAdjustHook(function(_, ges)
        if active_plugin and active_plugin:isPenActive() and not active_plugin:isOverlayActive() then
            ges.ges = "none"
        end
    end)
end

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
        Draw.stampPath(bb, pts, 0, 0, w / 2, Blitbuffer.COLOR_BLACK)
    end,
}

local StylusAnnotations = InputContainer:extend{
    name = "stylus_annotations",
    is_doc_only = true,

    store = nil,

    stylus_callback_registered = false,
    touch_pen_fallback_registered = false,
    touch_zones_registered = false,

    pen_active = false,
    pen_grace_until = 0,

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
    live_ink = true,
    live_snapshot = nil,
    live_dirty = nil,
    last_refresh_time = 0,
    pending_save = nil,
}

function StylusAnnotations:init()
    self.stroke_id_counter = 0
    active_plugin = self

    self.view = self.ui.view

    self.adapter = (self.ui.paging and PagedAdapter:new(self) or ReflowAdapter:new(self))
    self.store = StrokeStore:new(self.adapter, logger)

    self:loadSettings()

    self.view:registerViewModule("stylus_annotations", self)

    self.ui.menu:registerToMainMenu(self)

    Dispatcher:registerAction("stylus_annotations_toggle", {
        category = "none",
        event = "StylusAnnotationsToggle",
        title = _("Stylus annotations: toggle drawing"),
        reader = true,
    })

    self:setupStylusCallback()
    self:setupPenPanZones()
    self:setupTouchZones()
    installGestureHook()

    dbg:turnOff()

    logger.info("StylusAnnotations: initialized, strokes =", #self.store.strokes)
end

function StylusAnnotations:onReaderReady()
    self:loadStrokes()
    self.ui:handleEvent(Event:new("UpdatePos"))
end

function StylusAnnotations:isEnabled()
    return G_reader_settings:readSetting("stylus_annotations_enabled") == true
end

function StylusAnnotations:setEnabled(enabled)
    G_reader_settings:saveSetting("stylus_annotations_enabled", enabled)
end

function StylusAnnotations:loadSettings()
    local ds = self.ui.doc_settings
    local saved = ds:readSetting("stylus_annotations_live_ink")
    if saved ~= nil then
        self.live_ink = saved
    else
        self.live_ink = not Device:hasEinkScreen()
    end
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
end

function StylusAnnotations:teardownStylusCallback()
    if not self.stylus_callback_registered then return end
    local Input = Device.input
    if Input and Input.unregisterStylusCallback then
        Input:unregisterStylusCallback()
    end
    self.stylus_callback_registered = false
end

function StylusAnnotations:setupPenPanZones()
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
    logger.info("StylusAnnotations: pen pan gesture zones registered")
end

function StylusAnnotations:isPenActive()
    if self.pen_active then return true end
    return self.pen_grace_until > 0 and time.now() < self.pen_grace_until
end

function StylusAnnotations:onPenPan(ges)
    if self.current_stroke then
        if self.stylus_callback_registered then return true end
        local cur = ges.pos
        self:addStrokePoint(cur.x, cur.y)
        return true
    end

    if not self:isPenActive() then return false end
    if self:isOverlayActive() then return false end
    if not self:isEnabled() then return false end
    if self.stylus_callback_registered then return true end
    local start = ges.start_pos or ges.pos
    local cur = ges.pos
    self:startStroke(start.x, start.y)
    if self.current_stroke then
        self:addStrokePoint(cur.x, cur.y)
    end
    return true
end

function StylusAnnotations:onPenPanRelease(ges)
    if self.current_stroke then
        if not self.stylus_callback_registered then
            self:endStroke()
        end
        return true
    end

    if not self:isPenActive() then return false end
    if self:isOverlayActive() then return false end
    if not self:isEnabled() then return false end
    if self.stylus_callback_registered then return true end
    return true
end

function StylusAnnotations:isOverlayActive()
    local top = UIManager:getTopmostVisibleWidget()
    if not top then return false end
    return (top.name or top.id) ~= "ReaderUI"
end

function StylusAnnotations:onStylusEvent(input, slot)
    local x, y = slot.x or 0, slot.y or 0
    if (slot.tool or TOOL_TYPE_PEN) ~= TOOL_TYPE_PEN then return false end

    if slot.id and slot.id >= 0 then
        if self:isOverlayActive() then return false end
        if not self:isEnabled() then return false end
        if not self.pen_active then
            self.pen_active = true
            logger.info("StylusAnnotations: pen down at", x, y)
        end

        if self.current_stroke then
            self:addStrokePoint(x, y)
        else
            self:startStroke(x, y)
        end
        return true
    end

    local was_active = self.pen_active
    self.pen_active = false
    self.pen_grace_until = time.now() + time.s(PEN_GRACE_TIME_S)
    if self.current_stroke then
        self:endStroke()
    end

    if not self:isOverlayActive() and self:isEnabled() and was_active then
        return true
    end
    return false
end

function StylusAnnotations:startStroke(x, y)
    self.stroke_id_counter = self.stroke_id_counter + 1
    local stroke = {
        id = tostring(self.stroke_id_counter),
        width = self.width,
        color = self.color,
        alpha = 1.0,
        datetime = os.time(),
    }
    if not self.adapter:initStroke(stroke, x, y) then
        self.stroke_id_counter = self.stroke_id_counter - 1
        return
    end
    self.current_stroke = stroke
    self.pen_x, self.pen_y = x, y
    self.dirty_region = nil
    self.live_dirty = nil
    self.last_refresh_time = time.now()

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
    UIManager:scheduleIn(holdIntervalSeconds(), hold_action)
end

function StylusAnnotations:addStrokePoint(x, y)
    local stroke = self.current_stroke
    if not stroke then return end
    if not self.adapter:addPoint(stroke, x, y) then return end

    local sw = self:getStrokeScreenWidth(stroke)
    local pad = math.floor(sw / 2) + 1
    local seg_x = math.min(self.pen_x, x) - pad
    local seg_y = math.min(self.pen_y, y) - pad
    local seg_w = math.abs(x - self.pen_x) + 2 * pad
    local seg_h = math.abs(y - self.pen_y) + 2 * pad
    self:accumulateDirty(seg_x, seg_y, seg_w, seg_h)

    if self.live_ink ~= false then
        self.live_dirty = Geometry.mergeRect(self.live_dirty, seg_x, seg_y, seg_w, seg_h)
        self:flushLiveThrottled()
    end

    self.pen_x, self.pen_y = x, y

    if self.hold_timer
        and (math.abs(x - self.hold_start_x) > HOLD_MOVE_THRESHOLD_PX
            or math.abs(y - self.hold_start_y) > HOLD_MOVE_THRESHOLD_PX) then
        UIManager:unschedule(self.hold_timer)
        self.hold_timer = nil
    end
end

function StylusAnnotations:flushLiveThrottled()
    if self.live_ink == false or not self.live_snapshot then return end
    local ld = self.live_dirty
    if not ld or ld.w <= 0 or ld.h <= 0 then return end
    local now = time.now()
    if time.to_ms(now - self.last_refresh_time) < LIVE_REFRESH_INTERVAL_MS then return end
    self.last_refresh_time = now
    self.live_dirty = nil
    self:flushLive(ld, self.current_stroke)
end

function StylusAnnotations:flushLive(ld, stroke)
    if not self.live_snapshot then return end
    local bb = Screen.bb
    local restore = self.dirty_region or ld
    local rx, ry, rw, rh = Geometry.clampRect(
        restore.x, restore.y, restore.w, restore.h, Screen:getWidth(), Screen:getHeight())
    if not rx then return end
    bb:blitFrom(self.live_snapshot, rx, ry, rx, ry, rw, rh)
    if stroke then
        self:renderStrokeToScreen(stroke)
    end
    local dx, dy, dw, dh = Geometry.clampRect(
        ld.x, ld.y, ld.w, ld.h, Screen:getWidth(), Screen:getHeight())
    if dx then
        Screen:refreshUI(dx, dy, dw, dh)
    end
end

function StylusAnnotations:cancelLive()
    if self.live_snapshot then
        self.live_snapshot:free()
        self.live_snapshot = nil
    end
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

    stroke.points = self.store:decimatePoints(stroke)

    self.store:add(stroke)

    self:scheduleSave()

    if self.live_ink == false then
        self:cancelLive()
        self:renderStrokeToScreen(stroke)
        self:refreshRegion(region)
    else
        local ld = self.live_dirty
        if ld and (ld.w > 0 or ld.h > 0) then
            self:flushLive(region or ld, stroke)
        end
        self.live_dirty = nil
        self:cancelLive()
    end
end

function StylusAnnotations:renderStrokeToScreen(stroke)
    self.adapter:renderStrokeToScreen(stroke)
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
    local stroke = self.store:findStrokeAt(x, y)
    if not stroke then return end
    self:showStrokeMenu({ stroke })
end

function StylusAnnotations:getStrokeScreenWidth(stroke)
    return self.adapter:getStrokeScreenWidth(stroke)
end

function StylusAnnotations:accumulateDirty(x, y, w, h)
    self.dirty_region = Geometry.mergeRect(self.dirty_region, x, y, w, h)
end

function StylusAnnotations:paintTo(bb, x, y)
    self.adapter:paintTo(bb, x, y)
end

function StylusAnnotations:getVisiblePages()
    return self.adapter:getVisiblePages()
end

function StylusAnnotations:getPageZoom(page)
    return self.adapter:getPageZoom(page)
end

function StylusAnnotations:getSelectionRect(stroke, width, height)
    return self.store:getSelectionRect(stroke, width, height)
end

function StylusAnnotations:paintStrokeSolid(bb, x, y, stroke, color)
    self.adapter:paintStrokeSolid(bb, x, y, stroke, color)
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
    if self.current_stroke then return true end
    if self:isPenActive() then return true end
    if self:isOverlayActive() then return false end
    local stroke = self:findStrokeAt(ges)
    if not stroke then

        return false
    end
    self:showStrokeMenu({ stroke })
    return true
end

function StylusAnnotations:onStrokeHold(ges)
    if self.current_stroke then return true end
    if self:isPenActive() then return true end
    if self:isOverlayActive() then return false end
    local stroke = self:findStrokeAt(ges)
    if not stroke then
        return false
    end
    self:showStrokeMenu(self.store:selectStrokesChain(stroke))
    return true
end

function StylusAnnotations:findStrokeAt(ges)
    if #self.store.strokes == 0 or not ges or not ges.pos then return nil end
    return self.store:findStrokeAt(ges.pos.x, ges.pos.y)
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
    self.adapter:paintSelection(Screen.bb, 0, 0)
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

function StylusAnnotations:showStrokeMenu(strokes)
    self:setSelection(strokes)
    local dialog
    dialog = ButtonDialog:new{
        width_factor = 0.45,
        anchor = function()
            local x0, y0, x1, y1 = self.store:getSelectionUnionBox(strokes)
            if not x0 then return end
            return Geometry.paddedRect(x0, y0, x1, y1, Geometry.strokePad(strokes[1].width, strokes[1].zoom))
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
    local palette = Draw.getColorPalette()
    for i, c in ipairs(palette) do
        values[i] = { c[1], c[2], Draw.getPaletteColor(c[2], self.ui.highlight) }
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
    self.store:setField(strokes, "color", color)
    self:afterStrokeModified(strokes[1])
end

function StylusAnnotations:setStrokeWidth(strokes, width)
    self.store:setField(strokes, "width", width)
    self:afterStrokeModified(strokes[1])
end

function StylusAnnotations:afterStrokeModified(stroke)
    self:scheduleSave()
    UIManager:setDirty(self.view, "partial")
end

function StylusAnnotations:deleteStrokes(strokes, notify)
    local removed = self.store:remove(strokes)
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

function StylusAnnotations:getStrokesFilePath()
    local sidecar_dir = self.ui.doc_settings and self.ui.doc_settings.doc_sidecar_dir
    if sidecar_dir then
        return sidecar_dir .. "/stylus_annotations.lua", sidecar_dir
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
    local filepath, sidecar_dir = self:getStrokesFilePath()
    if not filepath then
        logger.warn("StylusAnnotations: no sidecar dir available, skipping save")
        return
    end
    local ok, err = util.makePath(sidecar_dir)
    if not ok and err then
        logger.warn("StylusAnnotations: failed to create sidecar dir:", err)
    end
    self.store:save(filepath)
end

function StylusAnnotations:loadStrokes()
    local filepath = self:getStrokesFilePath()
    if not filepath then
        self.store:load(nil)
        return
    end
    local migrated = self.store:load(filepath)
    if migrated then
        self:scheduleSave()
    end
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
                    return T(_("Color: %1"), Draw.colorDisplayName(self.color))
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
        count = count + #(self.store.strokes_by_page[page] or {})
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
            local removed = self.store:removeByPage(pages)
            self:scheduleSave()
            UIManager:setDirty(self.view, "partial")
            self:notifyStrokeDeleted(removed)
        end,
    })
end

function StylusAnnotations:deleteAllStrokes()
    local total = #self.store.strokes
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
            local removed = self.store:removeAll()
            self:scheduleSave()
            UIManager:setDirty(self.view, "partial")
            self:notifyStrokeDeleted(removed)
        end,
    })
end

function StylusAnnotations:onCloseDocument()
    if active_plugin == self then
        active_plugin = nil
    end
    if self.pending_save then
        UIManager:unschedule(self.pending_save)
        self.pending_save = nil
    end
    if self.hold_timer then
        UIManager:unschedule(self.hold_timer)
        self.hold_timer = nil
    end
    self.current_stroke = nil
    self:cancelLive()
    self:teardownStylusCallback()
    self:saveStrokes()
end

return StylusAnnotations

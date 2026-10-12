local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Geometry = require("core/geometry")
local Draw = require("core/draw")
local PenInput = require("core/pen")
local Paged = require("core/mapping/paged")
local Reflow = require("core/mapping/reflow")
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

local SAVE_DELAY_MS = 800
local HOLD_MOVE_THRESHOLD_PX = 15
local LIVE_REFRESH_INTERVAL_MS = 33
local FAST_LIVE_REFRESH_INTERVAL_MS = 80
local LIVE_MOVE_THRESHOLD_PX = 2
local LIVE_MOVE_THRESHOLD_PX2 = LIVE_MOVE_THRESHOLD_PX * LIVE_MOVE_THRESHOLD_PX
local LIVE_MODE_DEFERRED = "deferred"
local LIVE_MODE_ACCURATE = "live_accurate"
local LIVE_MODE_FAST = "live_fast"
local DEFAULT_HOLD_INTERVAL_MS = 500

local MIN_STROKE_WIDTH = 1
local MAX_STROKE_WIDTH = 30
local DEFAULT_WIDTH = 2
local DEFAULT_COLOR = "orange"
local WIDTH_CHOICES = { 1, 2, 3, 5, 8, 12 }
local TOOL_PEN = "pen"
local TOOL_ERASER = "eraser"
local TOOL_LASSO = "lasso"
local LASSO_POINT_SPACING_PX = 2
local LASSO_REFRESH_INTERVAL_MS = 80
local TOOLBAR_MOVE_DELAY_S = 0.5
local MAX_UNDO_ACTIONS = 30
local ERASER_RADIUS_PX = 20
local SELECTION_MOVE_REFRESH_INTERVAL_MS = 50

local FULL_SCREEN_ZONE = {
    ratio_x = 0, ratio_y = 0,
    ratio_w = 1, ratio_h = 1,
}

local function holdIntervalSeconds()
    local ms = G_reader_settings:readSetting("ges_hold_interval_ms") or DEFAULT_HOLD_INTERVAL_MS
    return ms / 1000
end

local function clampToScreen(x, y, w, h)
    return Geometry.clampRect(x, y, w, h, Screen:getWidth(), Screen:getHeight())
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

local EraserCursor = Widget:extend{
    name = "stylus_annotations_eraser_cursor",
    modal = false,
    cursor = nil,
    paintTo = function(self, bb, x, y)
        local cursor = self.cursor
        if not cursor then return end
        Draw.paintCircleOutline(bb, x + cursor.x, y + cursor.y, cursor.radius + 1,
            Blitbuffer.COLOR_WHITE, 4)
        Draw.paintCircleOutline(bb, x + cursor.x, y + cursor.y, cursor.radius,
            Blitbuffer.COLOR_BLACK, 2)
    end,
}

local StylusAnnotations = InputContainer:extend{
    name = "stylus_annotations",
    is_doc_only = true,

    store = nil,

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
    live_mode = LIVE_MODE_ACCURATE,
    live_snapshot = nil,
    live_dirty = nil,
    last_refresh_time = 0,
    pending_save = nil,
    tool_mode = TOOL_PEN,
    tool_palette = nil,
    toolbar_offset = nil,
    lasso_points = nil,
    lasso_last_refresh_time = 0,
    context_strokes = nil,
    toolbar_move_timer = nil,
    pending_toolbar_move = nil,
    undo_stack = {},
    redo_stack = {},
    selection_move = nil,
    pending_selection_touch = nil,
    eraser_cursor = nil,
    eraser_rendered_cursor = nil,
    eraser_cursor_widget = nil,
    eraser_last_refresh_time = 0,
    erase_transaction = nil,
}

function StylusAnnotations:init()
    self.stroke_id_counter = 0

    self.view = self.ui.view

    self.mapper = (self.ui.paging and Paged:new(self) or Reflow:new(self))
    self.store = StrokeStore:new(self.mapper, logger)

    self:loadSettings()

    self.view:registerViewModule("stylus_annotations", self)

    self.ui.menu:registerToMainMenu(self)

    Dispatcher:registerAction("stylus_annotations_toggle", {
        category = "none",
        event = "StylusAnnotationsToggle",
        title = _("Stylus annotations: toggle drawing"),
        reader = true,
    })

    self.pen_input = PenInput:new(self)
    self.pen_input:register()
    self:setupTouchZones()

    logger.info("StylusAnnotations: initialized, strokes =", #self.store.strokes,
        "eink =", Device:hasEinkScreen(), "live_mode =", self.live_mode)
end

function StylusAnnotations:onReaderReady()
    self:loadStrokes()
    self:resetUndoHistory()
    self.ui:handleEvent(Event:new("UpdatePos"))
end

function StylusAnnotations:onCloseDocument()
    if self.pending_save then
        UIManager:unschedule(self.pending_save)
        self.pending_save = nil
    end
    self:cancelHoldTimer()
    self.current_stroke = nil
    self:cancelLasso()
    self.selection_move = nil
    self.pending_selection_touch = nil
    self:endEraser()
    self:cancelLive()
    self:closeToolPalette()
    self.pen_input:unregister()
    self.pen_input.pen_active = false
    self.pen_input.active_mode = nil
    self.pen_input.eraser_active = false
    self:saveStrokes()
end

function StylusAnnotations:isEnabled()
    return G_reader_settings:readSetting("stylus_annotations_enabled") ~= false
end

function StylusAnnotations:setEnabled(enabled)
    G_reader_settings:saveSetting("stylus_annotations_enabled", enabled)
end

function StylusAnnotations:liveInkEnabled()
    return self.live_mode ~= LIVE_MODE_DEFERRED
end

function StylusAnnotations:updateLiveMode(enabled)
    if enabled then
        self.live_mode = Device:hasEinkScreen() and LIVE_MODE_FAST or LIVE_MODE_ACCURATE
    else
        self.live_mode = LIVE_MODE_DEFERRED
    end
end

function StylusAnnotations:loadSettings()
    local ds = self.ui.doc_settings
    local live_ink_enabled = ds:readSetting("stylus_annotations_live_ink") ~= false
    self:updateLiveMode(live_ink_enabled)
    self.width = ds:readSetting("stylus_annotations_width") or DEFAULT_WIDTH
    self.color = ds:readSetting("stylus_annotations_color") or DEFAULT_COLOR
    local tool_mode = ds:readSetting("stylus_annotations_tool_mode")
    if tool_mode == TOOL_ERASER or tool_mode == TOOL_LASSO then
        self.tool_mode = tool_mode
    else
        self.tool_mode = TOOL_PEN
    end
    if ds:readSetting("stylus_annotations_toolbar_offset_version") == 1 then
        self.toolbar_offset = ds:readSetting("stylus_annotations_toolbar_offset")
    else
        self.toolbar_offset = nil
    end
end

function StylusAnnotations:saveSettings()
    local ds = self.ui.doc_settings
    ds:saveSetting("stylus_annotations_live_ink", self:liveInkEnabled())
    ds:saveSetting("stylus_annotations_width", self.width)
    ds:saveSetting("stylus_annotations_color", self.color)
    ds:saveSetting("stylus_annotations_tool_mode", self.tool_mode)
    ds:saveSetting("stylus_annotations_toolbar_offset", self.toolbar_offset)
    if self.toolbar_offset then
        ds:saveSetting("stylus_annotations_toolbar_offset_version", 1)
    end
end

function StylusAnnotations:resetUndoHistory()
    self.undo_stack = {}
    self.redo_stack = {}
    self:updateUndoRedoButtons()
end

function StylusAnnotations:recordHistory(undo, redo)
    self.undo_stack[#self.undo_stack + 1] = { undo = undo, redo = redo }
    if #self.undo_stack > MAX_UNDO_ACTIONS then
        table.remove(self.undo_stack, 1)
    end
    self.redo_stack = {}
    self:updateUndoRedoButtons()
end

function StylusAnnotations:updateUndoRedoButtons()
    local dialog = self.tool_palette
    if not dialog then return end
    local undo = dialog:getButtonById("stylus_undo")
    local redo = dialog:getButtonById("stylus_redo")
    if not undo or not redo then return end
    undo:setText(T(_("Undo (%1)"), #self.undo_stack), undo.width)
    redo:setText(T(_("Redo (%1)"), #self.redo_stack), redo.width)
    if #self.undo_stack > 0 then undo:enable() else undo:disable() end
    if #self.redo_stack > 0 then redo:enable() else redo:disable() end
    local dimen = dialog.movable and dialog.movable.dimen or dialog.dimen
    if dimen then
        UIManager:setDirty(dialog, "ui", dimen)
    else
        UIManager:setDirty(dialog, "ui")
    end
end

function StylusAnnotations:finishHistoryChange(had_selection)
    self:scheduleSave()
    UIManager:setDirty(self.ui, "partial")
    if had_selection then
        self:refreshToolPalette()
    end
end

function StylusAnnotations:undoLastAction()
    local action = table.remove(self.undo_stack)
    if not action then
        UIManager:show(InfoMessage:new{ text = _("Nothing to undo."), timeout = 1 })
        return false
    end
    local had_selection = self.context_strokes ~= nil
    self:clearSelection()
    self.context_strokes = nil
    action.undo()
    self.redo_stack[#self.redo_stack + 1] = action
    self:updateUndoRedoButtons()
    self:finishHistoryChange(had_selection)
    return true
end

function StylusAnnotations:redoLastAction()
    local action = table.remove(self.redo_stack)
    if not action then
        UIManager:show(InfoMessage:new{ text = _("Nothing to redo."), timeout = 1 })
        return false
    end
    local had_selection = self.context_strokes ~= nil
    self:clearSelection()
    self.context_strokes = nil
    action.redo()
    self.undo_stack[#self.undo_stack + 1] = action
    self:updateUndoRedoButtons()
    self:finishHistoryChange(had_selection)
    return true
end

function StylusAnnotations:captureStrokeEntries(strokes)
    local wanted = {}
    for _, stroke in ipairs(strokes) do wanted[stroke] = true end
    local entries = {}
    for index, stroke in ipairs(self.store.strokes) do
        if wanted[stroke] then
            entries[#entries + 1] = { index = index, stroke = stroke }
        end
    end
    return entries
end

function StylusAnnotations:restoreStrokeEntries(entries)
    for _, entry in ipairs(entries) do
        table.insert(self.store.strokes, math.min(entry.index, #self.store.strokes + 1), entry.stroke)
    end
    self.store:rebuildPageIndex()
end

function StylusAnnotations:removeStrokesWithUndo(strokes)
    local entries = self:captureStrokeEntries(strokes)
    local removed = self.store:remove(strokes)
    if removed > 0 then
        self:recordHistory(function()
            self:restoreStrokeEntries(entries)
        end, function()
            self.store:remove(strokes)
        end)
    end
    return removed
end

function StylusAnnotations:isPenActive()
    return self.pen_input and self.pen_input:isPenActive() or false
end

function StylusAnnotations:isOverlayActive(x, y)
    local top = UIManager:getTopmostVisibleWidget()
    if not top then return false end
    local name = top.name or top.id
    local dimen = self.tool_palette and self.tool_palette.movable and self.tool_palette.movable.dimen
    if x and y and dimen
            and x >= dimen.x and x < dimen.x + dimen.w
            and y >= dimen.y and y < dimen.y + dimen.h then
        return true
    end
    if name == "stylus_annotations_toolbar"
        or name == "stylus_annotations_eraser_cursor" then
        return false
    end
    return name ~= "ReaderUI"
end

function StylusAnnotations:showToolPalette()
    if self.tool_palette then return end

    local width = math.max(1, Screen:getWidth() - 2 * Screen:scaleBySize(8))
    local anchor_y = Screen:scaleBySize(12)
    local mode_text = function(mode, label)
        return mode == self.tool_mode and label .. " ✓" or label
    end
    local buttons = {
        {
            {
                text = mode_text(TOOL_PEN, _("Pen")),
                callback = function() self:setToolMode(TOOL_PEN) end,
            },
            {
                text = mode_text(TOOL_ERASER, _("Eraser")),
                callback = function() self:setToolMode(TOOL_ERASER) end,
            },
            {
                text = mode_text(TOOL_LASSO, _("Lasso")),
                callback = function() self:setToolMode(TOOL_LASSO) end,
            },
        },
        {
            {
                id = "stylus_undo",
                text = _("Undo"),
                enabled = #self.undo_stack > 0,
                callback = function() self:undoLastAction() end,
            },
            {
                id = "stylus_redo",
                text = _("Redo"),
                enabled = #self.redo_stack > 0,
                callback = function() self:redoLastAction() end,
            },
        },
        {
            {
                text = _("Color"),
                callback = function() self:onToolColor() end,
            },
            {
                text = _("Width"),
                callback = function() self:onToolWidth() end,
            },
            {
                text = "×",
                callback = function() self:closeToolPalette() end,
            },
        },
    }
    if self.context_strokes then
        buttons[#buttons + 1] = {
            {
                text = T(_("Delete selected (%1)"), #self.context_strokes),
                callback = function() self:deleteToolSelection() end,
            },
        }
    end
    local dialog
    dialog = ButtonDialog:new{
        id = "stylus_annotations_toolbar",
        name = "stylus_annotations_toolbar",
        modal = false,
        title = self.context_strokes
            and T(_("Selected strokes: %1"), #self.context_strokes)
            or _("Stylus tools"),
        width = width,
        dismissable = false,
        anchor = function()
            return Geom:new{
                x = Screen:scaleBySize(8),
                y = anchor_y,
                w = width,
                h = 0,
            }
        end,
        buttons = buttons,
    }

    local offset = self.toolbar_offset
    if offset and offset.x and offset.y then
        dialog.movable:setMovedOffset(Geom:new{ x = offset.x, y = offset.y })
        dialog.movable._anchor_ensured = true
    end
    local movable = dialog.movable
    local move_by = movable._moveBy
    movable._moveBy = function(container, dx, dy, restrict_to_screen)
        if dx == nil or dy == nil then
            self:flushToolbarMove()
            return move_by(container, dx, dy, restrict_to_screen)
        end
        self:queueToolbarMove(container, move_by, dx, dy, restrict_to_screen)
    end
    local movable_touch = movable.onMovableTouch
    movable.onMovableTouch = function(container, arg, ges)
        local handled = movable_touch(container, arg, ges)
        if container._touch_pre_pan_was_inside and ges and ges.pos then
            container._toolbar_touch_start = { x = ges.pos.x, y = ges.pos.y }
            container._toolbar_last_pointer = { x = ges.pos.x, y = ges.pos.y }
        else
            container._toolbar_touch_start = nil
            container._toolbar_last_pointer = nil
        end
        return handled
    end
    local movable_hold = movable.onMovableHold
    movable.onMovableHold = function(container, arg, ges)
        local handled = movable_hold(container, arg, ges)
        if handled and ges and ges.pos then
            container._toolbar_touch_start = { x = ges.pos.x, y = ges.pos.y }
            container._toolbar_last_pointer = { x = ges.pos.x, y = ges.pos.y }
        end
        return handled
    end
    local movable_pan = movable.onMovablePan
    movable.onMovablePan = function(container, arg, ges)
        if self.selection_move then return false end
        if not container._toolbar_touch_start and not container._moving then return false end
        local handled = movable_pan(container, arg, ges)
        if handled then self:trackToolbarPointer(container, move_by, ges) end
        return handled
    end
    local movable_hold_pan = movable.onMovableHoldPan
    movable.onMovableHoldPan = function(container, arg, ges)
        if self.selection_move then return false end
        if not container._toolbar_touch_start and not container._moving then return false end
        local handled = movable_hold_pan(container, arg, ges)
        if handled then self:trackToolbarPointer(container, move_by, ges) end
        return handled
    end
    local movable_pan_release = movable.onMovablePanRelease
    movable.onMovablePanRelease = function(container, arg, ges)
        if self.selection_move then return false end
        if not container._moving then
            container._toolbar_last_pointer = nil
            container._toolbar_touch_start = nil
            return movable_pan_release(container, arg, ges)
        end
        self:trackToolbarPointer(container, move_by, ges)
        self:flushToolbarMove()
        container._moving = false
        container._touch_pre_pan_was_inside = false
        container._move_relative_x, container._move_relative_y = nil, nil
        container._toolbar_last_pointer = nil
        container._toolbar_touch_start = nil
        return true
    end
    local movable_hold_release = movable.onMovableHoldRelease
    movable.onMovableHoldRelease = function(container, arg, ges)
        if self.selection_move then return false end
        local start = container._toolbar_touch_start
        if container._moving and start and ges and ges.pos then
            local dx = ges.pos.x - start.x
            local dy = ges.pos.y - start.y
            if math.abs(dx) >= container.move_threshold or math.abs(dy) >= container.move_threshold then
                self:trackToolbarPointer(container, move_by, ges)
                self:flushToolbarMove()
                container._moving = false
                container._touch_pre_pan_was_inside = false
                container._move_relative_x, container._move_relative_y = nil, nil
                container._toolbar_last_pointer = nil
                container._toolbar_touch_start = nil
                return true
            end
        end
        local handled = movable_hold_release(container, arg, ges)
        container._toolbar_last_pointer = nil
        container._toolbar_touch_start = nil
        return handled
    end
    self.tool_palette = dialog
    UIManager:show(dialog, "[ui]")
end

function StylusAnnotations:queueToolbarMove(movable, move_by, dx, dy, restrict_to_screen)
    if dx == 0 and dy == 0 then return end
    local pending = self.pending_toolbar_move
    if pending and pending.movable == movable then
        pending.dx = pending.dx + dx
        pending.dy = pending.dy + dy
        pending.restrict_to_screen = restrict_to_screen or pending.restrict_to_screen
    else
        self.pending_toolbar_move = {
            movable = movable,
            move_by = move_by,
            dx = dx,
            dy = dy,
            restrict_to_screen = restrict_to_screen,
        }
    end
    if self.toolbar_move_timer then return end
    local timer
    timer = function()
        if self.toolbar_move_timer ~= timer then return end
        self.toolbar_move_timer = nil
        self:flushToolbarMove()
    end
    self.toolbar_move_timer = timer
    UIManager:scheduleIn(TOOLBAR_MOVE_DELAY_S, timer)
end

function StylusAnnotations:trackToolbarPointer(movable, move_by, ges)
    if not ges or not ges.pos then return end
    local previous = movable._toolbar_last_pointer
    local x, y = ges.pos.x, ges.pos.y
    if previous then
        self:queueToolbarMove(movable, move_by, x - previous.x, y - previous.y)
    else
        movable._toolbar_touch_start = { x = x, y = y }
    end
    movable._toolbar_last_pointer = { x = x, y = y }
end

function StylusAnnotations:flushToolbarMove()
    local timer = self.toolbar_move_timer
    local pending = self.pending_toolbar_move
    if timer then UIManager:unschedule(timer) end
    self.toolbar_move_timer = nil
    self.pending_toolbar_move = nil
    if pending then
        pending.move_by(pending.movable, pending.dx, pending.dy, pending.restrict_to_screen)
        local moved = pending.movable:getMovedOffset()
        self.toolbar_offset = { x = moved.x, y = moved.y }
        if self.tool_palette and self.tool_palette.movable == pending.movable then
            self:saveSettings()
        end
    end
end

function StylusAnnotations:closeToolPalette()
    local dialog = self.tool_palette
    if not dialog then return end
    self:flushToolbarMove()
    self:clearSelection()
    self.context_strokes = nil
    local offset = dialog.movable:getMovedOffset()
    self.toolbar_offset = { x = offset.x, y = offset.y }
    self.tool_palette = nil
    self:saveSettings()
    UIManager:close(dialog)
end

function StylusAnnotations:refreshToolPalette()
    local dialog = self.tool_palette
    if not dialog then
        self:showToolPalette()
        return
    end
    self:flushToolbarMove()
    local moved = dialog.movable:getMovedOffset()
    self.toolbar_offset = { x = moved.x, y = moved.y }
    self.tool_palette = nil
    UIManager:close(dialog)
    self:showToolPalette()
end

function StylusAnnotations:setToolMode(mode)
    if mode ~= TOOL_PEN and mode ~= TOOL_ERASER and mode ~= TOOL_LASSO then return end
    if self.tool_mode == mode then return end
    self.tool_mode = mode
    self:refreshToolPalette()
    self:saveSettings()
end

function StylusAnnotations:onToolColor()
    local strokes = self.context_strokes
    if not strokes then
        self:choosePenColor()
        return
    end
    self:clearSelection()
    self.context_strokes = nil
    self:refreshToolPalette()
    self:chooseStrokeColor(strokes)
end

function StylusAnnotations:onToolWidth()
    local strokes = self.context_strokes
    if not strokes then
        self:choosePenWidth()
        return
    end
    self:clearSelection()
    self.context_strokes = nil
    self:refreshToolPalette()
    self:chooseStrokeWidth(strokes)
end

function StylusAnnotations:deleteToolSelection()
    local strokes = self.context_strokes
    if not strokes then return end
    self:clearSelection()
    self.context_strokes = nil
    self:refreshToolPalette()
    self:deleteStrokes(strokes, #strokes > 1)
end

function StylusAnnotations:startLasso(x, y)
    self:showToolPalette()
    self.lasso_points = { { x = x, y = y } }
    self.lasso_last_refresh_time = time.now()
    UIManager:setDirty(self.ui, "partial")
end

function StylusAnnotations:addLassoPoint(x, y)
    local points = self.lasso_points
    if not points then
        self:startLasso(x, y)
        return
    end
    local last = points[#points]
    local dx, dy = x - last.x, y - last.y
    if dx * dx + dy * dy < LASSO_POINT_SPACING_PX * LASSO_POINT_SPACING_PX then return end
    points[#points + 1] = { x = x, y = y }
    local now = time.now()
    if time.to_ms(now - self.lasso_last_refresh_time) >= LASSO_REFRESH_INTERVAL_MS then
        self.lasso_last_refresh_time = now
        UIManager:setDirty(self.ui, "partial")
    end
end

function StylusAnnotations:finishLasso()
    local points = self.lasso_points
    self.lasso_points = nil
    self.lasso_last_refresh_time = 0
    UIManager:setDirty(self.ui, "partial")
    if not points or #points < 3 then return end
    local strokes = self.store:findStrokesInPolygon(points)
    if #strokes > 0 then
        self:showStrokeMenu(strokes)
    end
end

function StylusAnnotations:cancelLasso()
    if not self.lasso_points then return end
    self.lasso_points = nil
    self.lasso_last_refresh_time = 0
    UIManager:setDirty(self.ui, "partial")
end

function StylusAnnotations:setupTouchZones()
    if self.touch_zones_registered then return end
    self.ui:registerTouchZones({
        {
            id = "stylus_annotations_tap",
            ges = "tap",
            screen_zone = FULL_SCREEN_ZONE,
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
            screen_zone = FULL_SCREEN_ZONE,
            overrides = {
                "readerhighlight_hold",
                "readerfooter_hold",
            },
            handler = function(ges)
                return self:onStrokeHold(ges)
            end,
        },
        {
            id = "stylus_annotations_touch",
            ges = "touch",
            screen_zone = FULL_SCREEN_ZONE,
            handler = function(ges)
                return self:onSelectionTouch(ges)
            end,
        },
        {
            id = "stylus_annotations_pan",
            ges = "pan",
            screen_zone = FULL_SCREEN_ZONE,
            overrides = { "paging_pan", "rolling_pan" },
            handler = function(ges)
                return self:onSelectionPan(ges)
            end,
        },
        {
            id = "stylus_annotations_pan_release",
            ges = "pan_release",
            screen_zone = FULL_SCREEN_ZONE,
            overrides = { "paging_pan_release", "rolling_pan_release" },
            handler = function(ges)
                return self:onSelectionPanRelease(ges)
            end,
        },
        {
            id = "stylus_annotations_hold_pan",
            ges = "hold_pan",
            screen_zone = FULL_SCREEN_ZONE,
            overrides = { "readerhighlight_hold_pan" },
            handler = function(ges)
                return self:onSelectionPan(ges)
            end,
        },
        {
            id = "stylus_annotations_hold_release",
            ges = "hold_release",
            screen_zone = FULL_SCREEN_ZONE,
            overrides = { "readerhighlight_hold_release" },
            handler = function(ges)
                return self:onSelectionPanRelease(ges)
            end,
        },
    })
    self.touch_zones_registered = true
end

function StylusAnnotations:selectStrokeAt(ges, chain)
    if self.current_stroke then return true end
    if self:isPenActive() then return true end
    if not chain then self.pending_selection_touch = nil end
    if self:isOverlayActive(
        ges and ges.pos and ges.pos.x,
        ges and ges.pos and ges.pos.y
    ) then
        return false
    end
    local stroke = self:findStrokeAt(ges)
    if self.context_strokes then
        local already_selected = false
        for _, selected in ipairs(self.context_strokes) do
            if selected == stroke then
                already_selected = true
                break
            end
        end
        if already_selected then return true end
        self:deselectContextSelection()
    end
    if not stroke then return false end
    if chain then
        self:showStrokeMenu(self.store:selectStrokesChain(stroke))
    else
        self:showStrokeMenu({ stroke })
    end
    return true
end

function StylusAnnotations:deselectContextSelection()
    if not self.context_strokes then return false end
    self:clearSelection()
    self.context_strokes = nil
    self:refreshToolPalette()
    return true
end

function StylusAnnotations:isStrokeInSelection(stroke)
    if not stroke or not self.context_strokes then return false end
    for _, selected in ipairs(self.context_strokes) do
        if selected == stroke then return true end
    end
    return false
end

function StylusAnnotations:onSelectionTouch(ges)
    self.pending_selection_touch = nil
    if self.selection_move or not self.context_strokes or not ges or not ges.pos then return false end
    if self:isOverlayActive(ges.pos.x, ges.pos.y) then return false end
    local stroke = self.store:findStrokeAt(ges.pos.x, ges.pos.y)
    if self:isStrokeInSelection(stroke) then
        self.pending_selection_touch = { x = ges.pos.x, y = ges.pos.y }
    else
        self:deselectContextSelection()
    end
    return false
end

function StylusAnnotations:startSelectionMove(x, y)
    if self.selection_move or not self.context_strokes then return false end
    local hit = self.store:findStrokeAt(x, y)
    if not self:isStrokeInSelection(hit) then return false end
    local strokes = self.context_strokes
    local before = {}
    for i, stroke in ipairs(strokes) do
        before[i] = { stroke = stroke, points = util.tableDeepCopy(stroke.points) }
    end
    self:clearSelection()
    self.selection_move = {
        strokes = strokes,
        before = before,
        last_x = x,
        last_y = y,
        moved = false,
        last_refresh = 0,
    }
    return true
end

function StylusAnnotations:moveSelectionTo(x, y)
    local move = self.selection_move
    if not move then return false end
    local dx, dy = x - move.last_x, y - move.last_y
    move.last_x, move.last_y = x, y
    if dx == 0 and dy == 0 then return true end
    local changed = false
    for _, stroke in ipairs(move.strokes) do
        if self.mapper:moveStrokeByScreen(stroke, dx, dy) then changed = true end
    end
    if changed then
        move.moved = true
        local now = time.now()
        if move.last_refresh == 0
            or time.to_ms(now - move.last_refresh) >= SELECTION_MOVE_REFRESH_INTERVAL_MS then
            move.last_refresh = now
            UIManager:setDirty(self.ui, "partial")
        end
    end
    return true
end

function StylusAnnotations:finishSelectionMove(x, y)
    local move = self.selection_move
    if not move then return false end
    if x and y then self:moveSelectionTo(x, y) end
    self.selection_move = nil
    self.pending_selection_touch = nil
    if move.moved then
        local after = {}
        for i, stroke in ipairs(move.strokes) do
            after[i] = { stroke = stroke, points = util.tableDeepCopy(stroke.points) }
        end
        self:recordHistory(function()
            for _, entry in ipairs(move.before) do entry.stroke.points = entry.points end
        end, function()
            for _, entry in ipairs(after) do entry.stroke.points = entry.points end
        end)
        self:scheduleSave()
    end
    UIManager:setDirty(self.ui, "partial")
    self:setSelection(move.strokes)
    return true
end

function StylusAnnotations:onSelectionPan(ges)
    if not self.selection_move then
        local start = self.pending_selection_touch
        if not start or not ges or not ges.pos then return false end
        if self:isOverlayActive(start.x, start.y) then
            self.pending_selection_touch = nil
            return false
        end
        if not self:startSelectionMove(start.x, start.y) then
            self.pending_selection_touch = nil
            return false
        end
    end
    if ges and ges.pos then self:moveSelectionTo(ges.pos.x, ges.pos.y) end
    return true
end

function StylusAnnotations:onSelectionPanRelease(ges)
    self.pending_selection_touch = nil
    if not self.selection_move then return false end
    self:finishSelectionMove(ges and ges.pos and ges.pos.x, ges and ges.pos and ges.pos.y)
    return true
end

function StylusAnnotations:onStrokeTap(ges)
    self.pending_selection_touch = nil
    return self:selectStrokeAt(ges)
end

function StylusAnnotations:onStrokeHold(ges)
    local selected = self:selectStrokeAt(ges, true)
    if selected and ges and ges.pos
        and self:isStrokeInSelection(self:findStrokeAt(ges)) then
        self.pending_selection_touch = { x = ges.pos.x, y = ges.pos.y }
    end
    return selected
end

function StylusAnnotations:findStrokeAt(ges)
    if not ges or not ges.pos then return nil end
    return self.store:findStrokeAt(ges.pos.x, ges.pos.y)
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
    if not self.mapper:initStroke(stroke, x, y) then
        self.stroke_id_counter = self.stroke_id_counter - 1
        return
    end
    self.current_stroke = stroke
    self.pen_x, self.pen_y = x, y
    self.last_flush_x, self.last_flush_y = x, y
    self.dirty_region = nil
    self.live_dirty = nil
    self.last_refresh_time = 0
    self.stroke_timing = {
        start = time.now(),
        snapshot_ms = 0,
        paint_ms = 0,
        flush_count = 0,
        finalize_ms = 0,
    }

    if self.live_mode ~= LIVE_MODE_DEFERRED then
        self:takeLiveSnapshot()
        if self.live_mode == LIVE_MODE_FAST then
            local sw = self:getStrokeScreenWidth(stroke)
            Draw.stampDisc(Screen.bb, x, y, sw / 2, Blitbuffer.COLOR_BLACK)
        end
    end

    self.hold_start_x, self.hold_start_y = x, y
    self:scheduleHoldTimer()
    self:showToolPalette()
end

function StylusAnnotations:addStrokePoint(x, y)
    local stroke = self.current_stroke
    if not stroke then return end
    if not self.mapper:addPoint(stroke, x, y) then return end

    local sw = self:getStrokeScreenWidth(stroke)
    local pad = math.floor(sw / 2) + 1
    local seg_x = math.min(self.pen_x, x) - pad
    local seg_y = math.min(self.pen_y, y) - pad
    local seg_w = math.abs(x - self.pen_x) + 2 * pad
    local seg_h = math.abs(y - self.pen_y) + 2 * pad
    if self.live_mode == LIVE_MODE_FAST then
        self:stampLiveSegment(stroke, x, y, sw)
    end
    self:accumulateSegment(seg_x, seg_y, seg_w, seg_h)

    self.pen_x, self.pen_y = x, y

    if self.hold_timer
        and (math.abs(x - self.hold_start_x) > HOLD_MOVE_THRESHOLD_PX
            or math.abs(y - self.hold_start_y) > HOLD_MOVE_THRESHOLD_PX) then
        self:cancelHoldTimer()
    end
end

function StylusAnnotations:stampLiveSegment(stroke, x, y, sw)
    local t0 = time.now()
    Draw.stampPath(Screen.bb, {
        { x = self.pen_x, y = self.pen_y },
        { x = x, y = y },
    }, 0, 0, sw / 2, Blitbuffer.COLOR_BLACK)
    if self.stroke_timing then
        self.stroke_timing.paint_ms = self.stroke_timing.paint_ms
            + time.to_ms(time.now() - t0)
    end
end

function StylusAnnotations:takeLiveSnapshot()
    local t0 = time.now()
    if self.live_snapshot then
        self.live_snapshot:free()
        self.live_snapshot = nil
    end
    self.live_snapshot = Screen.bb:copy()
    if self.stroke_timing then
        self.stroke_timing.snapshot_ms = time.to_ms(time.now() - t0)
    end
end

function StylusAnnotations:accumulateSegment(x, y, w, h)
    self.dirty_region = Geometry.mergeRect(self.dirty_region, x, y, w, h)
    if self.live_mode ~= LIVE_MODE_DEFERRED then
        self.live_dirty = Geometry.mergeRect(self.live_dirty, x, y, w, h)
        self:flushLiveThrottled()
    end
end

function StylusAnnotations:scheduleHoldTimer()
    self:cancelHoldTimer()
    self.hold_timer = function()
        self.hold_timer = nil
        self:onStrokeHoldTimer()
    end
    UIManager:scheduleIn(holdIntervalSeconds(), self.hold_timer)
end

function StylusAnnotations:cancelHoldTimer()
    if self.hold_timer then
        UIManager:unschedule(self.hold_timer)
        self.hold_timer = nil
    end
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
    self.stroke_timing = nil
    self:cancelLive()
    UIManager:setDirty(self.ui, "partial")
end

function StylusAnnotations:endStroke()
    self:cancelHoldTimer()
    local stroke = self.current_stroke
    local region = self.dirty_region
    self.current_stroke = nil
    self.dirty_region = nil
    if not stroke or #stroke.points == 0 then
        self.stroke_timing = nil
        return
    end

    stroke.points = self.store:decimatePoints(stroke)

    self.store:add(stroke)
    self:recordHistory(function()
        self.store:remove({ stroke })
    end, function()
        self.store:add(stroke)
    end)

    self:scheduleSave()

    if self.live_mode == LIVE_MODE_DEFERRED then
        self:renderStrokeToScreen(stroke)
        self:refreshRegion(region)
    elseif self.live_mode == LIVE_MODE_FAST then
        self:finalizeLiveStroke(stroke, region or self.live_dirty)
    else
        local ld = self.live_dirty
        if ld and (ld.w > 0 or ld.h > 0) then
            self:flushLive(region or ld, stroke)
        end
    end
    self:cancelLive()
    self:logStrokeTiming(stroke)
end

function StylusAnnotations:finalizeLiveStroke(stroke, region)
    if not self.live_snapshot then return end
    local t0 = time.now()
    region = region or self:getSelectionRect(stroke, Screen:getWidth(), Screen:getHeight())
    if not region then return end
    local rx, ry, rw, rh = clampToScreen(region.x, region.y, region.w, region.h)
    if not rx then return end
    Screen.bb:blitFrom(self.live_snapshot, rx, ry, rx, ry, rw, rh)
    self:renderStrokeToScreen(stroke)
    UIManager:setDirty(nil, "ui", Geom:new{x = rx, y = ry, w = rw, h = rh})
    if self.stroke_timing then
        self.stroke_timing.finalize_ms = time.to_ms(time.now() - t0)
    end
end

function StylusAnnotations:logStrokeTiming(stroke)
    local t = self.stroke_timing
    self.stroke_timing = nil
    if not t then return end
    local total_ms = time.to_ms(time.now() - t.start)
    logger.info("StylusAnnotations: stroke points=", #stroke.points,
        "total_ms=", total_ms,
        "snapshot_ms=", t.snapshot_ms,
        "paint_ms=", t.paint_ms,
        "flush_count=", t.flush_count,
        "finalize_ms=", t.finalize_ms)
end

function StylusAnnotations:liveRefreshInterval()
    if self.live_mode == LIVE_MODE_FAST then
        return FAST_LIVE_REFRESH_INTERVAL_MS
    end
    return LIVE_REFRESH_INTERVAL_MS
end

function StylusAnnotations:flushLiveThrottled()
    if self.live_mode == LIVE_MODE_DEFERRED or not self.live_snapshot then return end
    local ld = self.live_dirty
    if not ld or ld.w <= 0 or ld.h <= 0 then return end
    local now = time.now()
    if time.to_ms(now - self.last_refresh_time) < self:liveRefreshInterval() then return end
    local dx = self.pen_x - self.last_flush_x
    local dy = self.pen_y - self.last_flush_y
    if dx * dx + dy * dy < LIVE_MOVE_THRESHOLD_PX2 then return end
    self.last_refresh_time = now
    self.last_flush_x, self.last_flush_y = self.pen_x, self.pen_y
    self.live_dirty = nil
    self:flushLive(ld, self.current_stroke)
end

function StylusAnnotations:flushLive(ld, stroke)
    if not self.live_snapshot then return end
    if self.live_mode == LIVE_MODE_FAST then
        local dx, dy, dw, dh = clampToScreen(ld.x, ld.y, ld.w, ld.h)
        if dx then
            UIManager:setDirty(nil, "fast", Geom:new{x = dx, y = dy, w = dw, h = dh})
        end
        if self.stroke_timing then
            self.stroke_timing.flush_count = self.stroke_timing.flush_count + 1
        end
        return
    end
    local bb = Screen.bb
    local restore = self.dirty_region or ld
    local rx, ry, rw, rh = clampToScreen(restore.x, restore.y, restore.w, restore.h)
    if not rx then return end
    bb:blitFrom(self.live_snapshot, rx, ry, rx, ry, rw, rh)
    if stroke then
        self:renderStrokeToScreen(stroke)
    end
    local dx, dy, dw, dh = clampToScreen(ld.x, ld.y, ld.w, ld.h)
    if dx then
        UIManager:setDirty(nil, "ui", Geom:new{x = dx, y = dy, w = dw, h = dh})
    end
end

function StylusAnnotations:cancelLive()
    if self.live_snapshot then
        self.live_snapshot:free()
        self.live_snapshot = nil
    end
    self.live_dirty = nil
end

function StylusAnnotations:renderStrokeToScreen(stroke)
    self.mapper:renderStrokeToScreen(stroke)
end

function StylusAnnotations:refreshRegion(region)
    if region then
        local rx, ry, rw, rh = clampToScreen(region.x, region.y, region.w, region.h)
        if rx then
            UIManager:setDirty(self.ui, function()
                return "partial", Geom:new{x = rx, y = ry, w = rw, h = rh}
            end)
            return
        end
    end
    UIManager:setDirty(self.ui, "partial")
end

function StylusAnnotations:paintTo(bb, x, y)
    self.mapper:paintTo(bb, x, y)
    local points = self.lasso_points
    if points and #points > 1 then
        local path = {}
        for i, point in ipairs(points) do
            path[i] = { x = x + point.x, y = y + point.y }
        end
        path[#path + 1] = { x = x + points[1].x, y = y + points[1].y }
        Draw.paintDashedPath(bb, path, 2, Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE, 7, 4)
    end
end

function StylusAnnotations:getStrokeScreenWidth(stroke)
    return self.mapper:getStrokeScreenWidth(stroke)
end

function StylusAnnotations:getVisiblePages()
    return self.mapper:getVisiblePages()
end

function StylusAnnotations:getPageZoom(page)
    return self.mapper:getZoom(page)
end

function StylusAnnotations:getSelectionRect(stroke, width, height)
    return self.store:getSelectionRect(stroke, width, height)
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
    self.mapper:paintSelection(Screen.bb, 0, 0)
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
    self.context_strokes = strokes
    self:refreshToolPalette()
end

function StylusAnnotations:showStrokeMenuAt(x, y)
    local stroke = self.store:findStrokeAt(x, y)
    if not stroke then return end
    self:showStrokeMenu({ stroke })
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

function StylusAnnotations:setStrokeAttribute(strokes, attribute, value)
    local changes = {}
    for _, stroke in ipairs(strokes) do
        if stroke[attribute] ~= value then
            changes[#changes + 1] = { stroke = stroke, before = stroke[attribute] }
        end
    end
    if #changes == 0 then return end
    self.store:setAttribute(strokes, attribute, value)
    self:recordHistory(function()
        for _, change in ipairs(changes) do
            change.stroke[attribute] = change.before
        end
    end, function()
        for _, change in ipairs(changes) do
            change.stroke[attribute] = value
        end
    end)
    self:scheduleSave()
    UIManager:setDirty(self.ui, "partial")
end

function StylusAnnotations:setStrokeColor(strokes, color)
    self:setStrokeAttribute(strokes, "color", color)
end

function StylusAnnotations:chooseStrokeWidth(strokes)
    self:showWidthPicker{
        start = strokes[1].width,
        on_apply = function(value)
            self:setStrokeWidth(strokes, value)
        end,
    }
end

function StylusAnnotations:setStrokeWidth(strokes, width)
    self:setStrokeAttribute(strokes, "width", width)
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
        value_min = MIN_STROKE_WIDTH,
        value_max = MAX_STROKE_WIDTH,
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
                input_hint = T(_("%1 - %2 (current: %3)"), MIN_STROKE_WIDTH, MAX_STROKE_WIDTH, start),
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
                                if v and v >= MIN_STROKE_WIDTH and v <= MAX_STROKE_WIDTH then
                                    v = math.floor(v + 0.5)
                                    UIManager:close(input_dialog)
                                    self:showWidthPicker{
                                        start = v,
                                        on_apply = on_apply,
                                    }
                                else
                                    UIManager:show(InfoMessage:new{
                                        text = T(_("Invalid width (%1 - %2)"), MIN_STROKE_WIDTH, MAX_STROKE_WIDTH),
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
                    self:onStylusAnnotationsToggle()
                end,
            },
            {
                text = _("Live refresh"),
                checked_func = function()
                    return self:liveInkEnabled()
                end,
                callback = function()
                    self:updateLiveMode(self.live_mode == LIVE_MODE_DEFERRED)
                    self:saveSettings()
                    local state = self.live_mode == LIVE_MODE_DEFERRED and _("off") or _("on")
                    UIManager:show(InfoMessage:new{
                        text = T(_("Live refresh: %1"), state),
                        timeout = 1,
                    })
                end,
            },
            {
                text = _("Show stylus toolbar"),
                callback = function()
                    self:showToolPalette()
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

function StylusAnnotations:onStylusAnnotationsToggle()
    self:setEnabled(not self:isEnabled())
    local state = self:isEnabled() and _("on") or _("off")
    UIManager:show(InfoMessage:new{
        text = T(_("Stylus annotations drawing: %1"), state),
        timeout = 1,
    })
    return true
end

function StylusAnnotations:deleteStrokes(strokes, notify)
    local removed = self:removeStrokesWithUndo(strokes)
    self:scheduleSave()
    UIManager:setDirty(self.ui, "partial")
    if notify ~= false then
        self:notifyStrokeDeleted(removed)
    end
end

function StylusAnnotations:beginEraser()
    if self.erase_transaction then return end
    if self.context_strokes then
        self:deselectContextSelection()
    end
    local base_index = {}
    for i, stroke in ipairs(self.store.strokes) do
        base_index[stroke] = i
    end
    self.erase_transaction = {
        base_index = base_index,
        changes = {},
        changes_by_root = {},
    }
end

function StylusAnnotations:mergeEraseChanges(changes)
    local transaction = self.erase_transaction
    if not transaction then return end
    for _, change in ipairs(changes) do
        local record = transaction.changes_by_root[change.root]
        if not record then
            record = {
                index = transaction.base_index[change.root] or change.index,
                before = change.before,
                after = change.after,
            }
            transaction.changes_by_root[change.root] = record
            transaction.changes[#transaction.changes + 1] = record
        else
            for _, source in ipairs(change.sources) do
                for i, current in ipairs(record.after) do
                    if current == source then
                        table.remove(record.after, i)
                        for j = #change.after, 1, -1 do
                            table.insert(record.after, i, change.after[j])
                        end
                        break
                    end
                end
            end
        end
    end
end

function StylusAnnotations:eraserCursorRect(cursor)
    if not cursor then return end
    local pad = cursor.radius + 4
    return { x = cursor.x - pad, y = cursor.y - pad, w = 2 * pad, h = 2 * pad }
end

function StylusAnnotations:updateEraserCursor(x, y)
    self.eraser_cursor = { x = x, y = y, radius = ERASER_RADIUS_PX }
    local widget = self.eraser_cursor_widget
    local created = false
    if not widget then
        widget = EraserCursor:new{
            dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
        }
        self.eraser_cursor_widget = widget
        created = true
    end
    widget.cursor = self.eraser_cursor
    if created then UIManager:show(widget, "[ui]") end

    local now = time.now()
    if self.eraser_last_refresh_time ~= 0
        and time.to_ms(now - self.eraser_last_refresh_time) < self:liveRefreshInterval() then
        return
    end
    self.eraser_last_refresh_time = now
    local old_rect = self:eraserCursorRect(self.eraser_rendered_cursor)
    local new_rect = self:eraserCursorRect(self.eraser_cursor)
    local region
    if old_rect then
        region = Geometry.mergeRect(nil, old_rect.x, old_rect.y, old_rect.w, old_rect.h)
    end
    if new_rect then
        region = Geometry.mergeRect(region, new_rect.x, new_rect.y, new_rect.w, new_rect.h)
    end
    self.eraser_rendered_cursor = {
        x = x, y = y, radius = ERASER_RADIUS_PX,
    }
    if region then
        local rx, ry, rw, rh = clampToScreen(region.x, region.y, region.w, region.h)
        if rx then UIManager:setDirty("all", "ui", Geom:new{ x = rx, y = ry, w = rw, h = rh }) end
    end
end

function StylusAnnotations:hideEraserCursor()
    local old_rect = self:eraserCursorRect(self.eraser_rendered_cursor)
    local widget = self.eraser_cursor_widget
    self.eraser_cursor = nil
    self.eraser_rendered_cursor = nil
    self.eraser_cursor_widget = nil
    self.eraser_last_refresh_time = 0
    if widget then
        if old_rect then
            local rx, ry, rw, rh = clampToScreen(old_rect.x, old_rect.y, old_rect.w, old_rect.h)
            if rx then
                UIManager:close(widget, "ui", Geom:new{ x = rx, y = ry, w = rw, h = rh })
            else
                UIManager:close(widget, "ui")
            end
        else
            UIManager:close(widget, "ui")
        end
    end
end

function StylusAnnotations:endEraser()
    local transaction = self.erase_transaction
    self.erase_transaction = nil
    if transaction and #transaction.changes > 0 then
        table.sort(transaction.changes, function(a, b) return a.index < b.index end)
        local history_changes = {}
        for _, change in ipairs(transaction.changes) do
            local after = {}
            for _, stroke in ipairs(change.after) do
                stroke._erase_root = nil
                after[#after + 1] = {
                    stroke = stroke,
                    points = util.tableDeepCopy(stroke.points),
                }
            end
            for _, entry in ipairs(change.before) do
                entry.stroke._erase_root = nil
            end
            history_changes[#history_changes + 1] = {
                index = change.index,
                before = change.before,
                after = after,
            }
        end
        self:recordHistory(function()
            self.store:applyChanges(history_changes, true)
        end, function()
            self.store:applyChanges(history_changes, false)
        end)
    end
    self:hideEraserCursor()
end

function StylusAnnotations:eraseStrokeAt(x, y)
    self:showToolPalette()
    local owns_transaction = self.erase_transaction == nil
    if owns_transaction then self:beginEraser() end
    self:updateEraserCursor(x, y)
    local changed, changes = self.store:erasePartialAt(x, y, ERASER_RADIUS_PX)
    if changed > 0 then
        self:mergeEraseChanges(changes)
        self:scheduleSave()
        UIManager:setDirty(self.ui, "partial")
    end
    if owns_transaction then self:endEraser() end
    return changed
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

function StylusAnnotations:confirmDeleteStrokes(text, count, remove)
    if count == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No strokes to delete."),
            timeout = 2,
        })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Delete"),
        ok_callback = function()
            local removed = remove()
            self:scheduleSave()
            UIManager:setDirty(self.ui, "partial")
            self:notifyStrokeDeleted(removed)
        end,
    })
end

function StylusAnnotations:deleteAllStrokesOnPage()
    local pages = self:getVisiblePages()
    if not pages then return end
    local count = 0
    local strokes = {}
    for _, page in ipairs(pages) do
        for _, index in ipairs(self.store.strokes_by_page[page] or {}) do
            count = count + 1
            strokes[#strokes + 1] = self.store.strokes[index]
        end
    end
    self:confirmDeleteStrokes(
        T(_("Delete all %1 strokes on this page?"), count), count,
        function()
            return self:removeStrokesWithUndo(strokes)
        end)
end

function StylusAnnotations:deleteAllStrokes()
    local total = #self.store.strokes
    local strokes = {}
    for i, stroke in ipairs(self.store.strokes) do
        strokes[i] = stroke
    end
    self:confirmDeleteStrokes(
        T(_("Delete all %1 strokes for this document?"), total), total,
        function()
            return self:removeStrokesWithUndo(strokes)
        end)
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

return StylusAnnotations

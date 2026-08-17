local Device = require("device")
local logger = require("logger")

local TOOL_TYPE_PEN = Device.input.TOOL_TYPE_PEN
local TOOL_TYPE_ERASER = Device.input.TOOL_TYPE_ERASER
local TOOL_TYPE_HIGHLIGHTER = Device.input.TOOL_TYPE_HIGHLIGHTER

-- Linux input ABI codes, not KOReader-specific.
local EV_KEY = 1
local EV_ABS = 3
local ABS_MT_TRACKING_ID = 57
local BTN_TOOL_PEN = 320
local BTN_TOOL_RUBBER = 321
local BTN_STYLUS = 331
local BTN_STYLUS2 = 332

local event_adjust_hooked = false

local PenFallback = {}

function PenFallback:new(pen_input)
    local o = {
        pen_input = pen_input,
        feed_hooked = false,
        original_feed_event = nil,
        feed_event_wrapper = nil,
        current_tracking_id = nil,
        pending_stylus_tool = nil,
        subtool_by_id = {},
        active_pen_slot = nil,
    }
    return setmetatable(o, { __index = PenFallback })
end

function PenFallback:install()
    local Input = Device.input
    local gd = Input.gesture_detector
    if self.feed_hooked or not gd or not gd.feedEvent then return end

    local fallback = self
    local pen_input = self.pen_input
    local original = gd.feedEvent
    local wrapper = function(s, events)
        if pen_input.fallback == fallback then
            fallback:onFeedEvents(events)
        end
        return original(s, events)
    end
    self.feed_hooked = true
    self.original_feed_event = original
    self.feed_event_wrapper = wrapper
    gd.feedEvent = wrapper

    if not event_adjust_hooked and Input.registerEventAdjustHook then
        event_adjust_hooked = true
        Input:registerEventAdjustHook(function(input, ev)
            local active = pen_input.fallback
            if active then
                active:eventAdjustHook(ev)
            end
        end)
    end

    logger.dbg("PenFallback: input hook installed")
end

function PenFallback:cleanup()
    local Input = Device.input
    if self.feed_hooked and Input then
        local gd = Input.gesture_detector
        if gd and gd.feedEvent == self.feed_event_wrapper then
            gd.feedEvent = self.original_feed_event
        end
    end
    self.feed_hooked = false
    self.original_feed_event = nil
    self.feed_event_wrapper = nil
    self.current_tracking_id = nil
    self.pending_stylus_tool = nil
    self.subtool_by_id = {}
    self.active_pen_slot = nil
end

-- Tag a contact as stylus from generic stylus button events, keyed by the
-- contact's ABS_MT_TRACKING_ID so the feedEvent fallback can recognize it.
function PenFallback:eventAdjustHook(ev)
    if ev.type == EV_ABS and ev.code == ABS_MT_TRACKING_ID then
        local prev = self.current_tracking_id
        self.current_tracking_id = ev.value
        if ev.value == -1 then
            self.pending_stylus_tool = nil
            if prev then self.subtool_by_id[prev] = nil end
        elseif self.pending_stylus_tool then
            self.subtool_by_id[ev.value] = self.pending_stylus_tool
            self.pending_stylus_tool = nil
        end
    elseif ev.type == EV_KEY then
        local tool
        if ev.code == BTN_TOOL_PEN then
            tool = TOOL_TYPE_PEN
        elseif ev.code == BTN_TOOL_RUBBER then
            tool = TOOL_TYPE_ERASER
        elseif ev.code == BTN_STYLUS then
            tool = TOOL_TYPE_ERASER
        elseif ev.code == BTN_STYLUS2 then
            tool = TOOL_TYPE_HIGHLIGHTER
        end
        if tool then
            if ev.value ~= 0 then
                self.pending_stylus_tool = tool
                if self.current_tracking_id and self.current_tracking_id >= 0 then
                    self.subtool_by_id[self.current_tracking_id] = tool
                end
            else
                self.pending_stylus_tool = nil
            end
        end
    end
end

function PenFallback:subtoolFor(slot)
    if slot.id and slot.id >= 0 then
        return self.subtool_by_id[slot.id]
    end
end

function PenFallback:isStylusSlot(slot)
    if slot.tool == TOOL_TYPE_PEN
        or slot.tool == TOOL_TYPE_ERASER
        or slot.tool == TOOL_TYPE_HIGHLIGHTER then
        return true
    end
    local input = Device.input
    if input.pen_slot and slot.slot == input.pen_slot then
        return true
    end
    if self:subtoolFor(slot) then
        return true
    end
    if slot.id == -1 and self.active_pen_slot and slot.slot == self.active_pen_slot then
        return true
    end
    return false
end

function PenFallback:slotCopy(slot)
    local tool = self:subtoolFor(slot) or slot.tool
    return {
        slot = slot.slot,
        id = slot.id,
        x = slot.x,
        y = slot.y,
        tool = tool,
    }
end

function PenFallback:onFeedEvents(events)
    if not events or not self.pen_input.plugin:isEnabled() then return end
    local input = Device.input
    local dominated = {}
    for i, slot in ipairs(events) do
        if self:isStylusSlot(slot) then
            local copy = self:slotCopy(slot)
            if self.pen_input:onStylusEvent(input, copy) then
                table.insert(dominated, i)
                if copy.id and copy.id >= 0 then
                    self.active_pen_slot = copy.slot
                else
                    self.active_pen_slot = nil
                end
            end
        end
    end
    for i = #dominated, 1, -1 do
        table.remove(events, dominated[i])
    end
end

return PenFallback
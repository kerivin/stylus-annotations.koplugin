local Device = require("device")
local logger = require("logger")

local TOOL_TYPE_PEN = Device.input.TOOL_TYPE_PEN

local PenFallback = {}

function PenFallback:new(pen_input)
    local o = {
        pen_input = pen_input,
        feed_hooked = false,
        original_feed_event = nil,
        feed_event_wrapper = nil,
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
    self.active_pen_slot = nil
end

function PenFallback:isStylusSlot(slot)
    if slot.tool == TOOL_TYPE_PEN then
        return true
    end
    local input = Device.input
    if input.pen_slot and slot.slot == input.pen_slot then
        return true
    end
    if slot.id == -1 and self.active_pen_slot and slot.slot == self.active_pen_slot then
        return true
    end
    return false
end

function PenFallback:slotCopy(slot)
    return {
        slot = slot.slot,
        id = slot.id,
        x = slot.x,
        y = slot.y,
        tool = slot.tool,
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
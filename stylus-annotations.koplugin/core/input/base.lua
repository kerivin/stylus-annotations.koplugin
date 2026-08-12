local Device = require("device")
local logger = require("logger")
local time = require("ui/time")

local PenInput = {}

PenInput.current = nil
local gesture_hook_added = false

local TOOL_TYPE_PEN = Device.input.TOOL_TYPE_PEN

local FULL_SCREEN_ZONE = {
    ratio_x = 0, ratio_y = 0,
    ratio_w = 1, ratio_h = 1,
}

function PenInput:new(plugin)
    local o = {
        plugin = plugin,
        stylus_registered = false,
        pen_active = false,
        pen_grace_until = 0,
        pen_grace_time = 0,
    }
    return setmetatable(o, { __index = PenInput })
end

function PenInput:isPenActive()
    return self.pen_active or (self.pen_grace_until > 0 and time.now() < self.pen_grace_until)
end

function PenInput:isPenInputAllowed()
    return self:isPenActive() and not self.plugin:isOverlayActive() and self.plugin:isEnabled()
end

function PenInput:installGestureHook()
    local Input = Device.input
    if gesture_hook_added or not Input or not Input.registerGestureAdjustHook then return end
    gesture_hook_added = true
    Input:registerGestureAdjustHook(function(_, ges)
        if PenInput.current
            and PenInput.current:isPenActive()
            and not PenInput.current.plugin:isOverlayActive() then
            ges.ges = "none"
        end
    end)
end

function PenInput:register()
    self:installGestureHook()
    PenInput.current = self
    self:registerPanZones()
    self:registerPlatformInput()
end

function PenInput:unregister()
    self:unregisterPlatformInput()
    if PenInput.current == self then
        PenInput.current = nil
    end
end

function PenInput:registerPanZones()
    self.plugin.ui:registerTouchZones({
        {
            id = "stylus_annotations_pen_pan",
            ges = "pan",
            screen_zone = FULL_SCREEN_ZONE,
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
            screen_zone = FULL_SCREEN_ZONE,
            overrides = {
                "rolling_pan_release",
                "paging_pan_release",
            },
            handler = function(ges)
                return self:onPenPanRelease(ges)
            end,
        },
    })
end

function PenInput:onStylusEvent(input, slot)
    local plugin = self.plugin
    local x, y = slot.x or 0, slot.y or 0
    if (slot.tool or TOOL_TYPE_PEN) ~= TOOL_TYPE_PEN then return false end

    if slot.id and slot.id >= 0 then
        if plugin:isOverlayActive() then return false end
        if not plugin:isEnabled() then return false end
        if not self.pen_active then
            self.pen_active = true
            logger.info("StylusAnnotations: pen down at", x, y)
        end

        if plugin.current_stroke then
            plugin:addStrokePoint(x, y)
        else
            plugin:startStroke(x, y)
        end
        return true
    end

    local was_active = self.pen_active
    self.pen_active = false
    if self.pen_grace_time and self.pen_grace_time > 0 then
        self.pen_grace_until = time.now() + time.s(self.pen_grace_time)
    end
    if plugin.current_stroke then
        plugin:endStroke()
    end

    if not plugin:isOverlayActive() and plugin:isEnabled() and was_active then
        return true
    end
    return false
end

function PenInput:registerPlatformInput() end

function PenInput:unregisterPlatformInput() end

function PenInput:onPenPan(ges)
    local plugin = self.plugin
    if plugin.current_stroke then
        if not self.stylus_registered then
            plugin:addStrokePoint(ges.pos.x, ges.pos.y)
        end
        return true
    end

    if not self:isPenInputAllowed() then return false end
    if self.stylus_registered then return true end
    local start = ges.start_pos or ges.pos
    plugin:startStroke(start.x, start.y)
    if plugin.current_stroke then
        plugin:addStrokePoint(ges.pos.x, ges.pos.y)
    end
    return true
end

function PenInput:onPenPanRelease(ges)
    local plugin = self.plugin
    if plugin.current_stroke then
        if not self.stylus_registered then
            plugin:endStroke()
        end
        return true
    end

    if not self:isPenInputAllowed() then return false end
    return true
end

return PenInput
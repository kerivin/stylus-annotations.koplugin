local Device = require("device")
local Geometry = require("core/geometry")
local logger = require("logger")
local PenFallback = require("core/pen_fallback")

local TOOL_TYPE_PEN = Device.input.TOOL_TYPE_PEN
local TOOL_TYPE_ERASER = Device.input.TOOL_TYPE_ERASER
local TOOL_TYPE_HIGHLIGHTER = Device.input.TOOL_TYPE_HIGHLIGHTER
local TOOL_TYPE_FINGER = Device.input.TOOL_TYPE_FINGER

local FULL_SCREEN_ZONE = {
    ratio_x = 0, ratio_y = 0,
    ratio_w = 1, ratio_h = 1,
}

local PenInput = {}

PenInput.current = nil
local gesture_hook_added = false

function PenInput:new(plugin)
    local o = {
        plugin = plugin,
        stylus_registered = false,
        pen_active = false,
        pen_lift_pending = false,
        pen_lift_x = 0,
        pen_lift_y = 0,
        lift_match_radius = 20,
        pen_mirrored = false,
        eraser_active = false,
        fallback = nil,
    }
    return setmetatable(o, { __index = PenInput })
end

function PenInput:isPenTool(slot)
    local tool = slot.tool or TOOL_TYPE_PEN
    return tool == TOOL_TYPE_PEN
        or tool == TOOL_TYPE_ERASER
        or tool == TOOL_TYPE_HIGHLIGHTER
end

function PenInput:transformCoordinates(x, y)
    local Screen = Device.screen
    return Geometry.transformForRotation(
        x, y, Screen:getTouchRotation(), Screen:getWidth(), Screen:getHeight())
end

function PenInput:isPenActive()
    return self.pen_active
end

function PenInput:isPenInputAllowed()
    return self:isPenActive() and not self.plugin:isOverlayActive() and self.plugin:isEnabled()
end

function PenInput:installGestureHook()
    local Input = Device.input
    if gesture_hook_added or not Input or not Input.registerGestureAdjustHook then return end
    gesture_hook_added = true
    Input:registerGestureAdjustHook(function(input, ges)
        local pen_input = PenInput.current
        if pen_input
            and not pen_input.plugin:isOverlayActive()
            and pen_input:isPenActive() then
            ges.ges = "none"
        elseif pen_input
            and not pen_input.plugin:isOverlayActive()
            and pen_input.pen_lift_pending then
            local dx = math.abs((ges.pos and ges.pos.x or 0) - pen_input.pen_lift_x)
            local dy = math.abs((ges.pos and ges.pos.y or 0) - pen_input.pen_lift_y)
            if dx <= pen_input.lift_match_radius and dy <= pen_input.lift_match_radius then
                ges.ges = "none"
            end
            pen_input.pen_lift_pending = false
        end
    end)
end

function PenInput:register()
    self:installGestureHook()
    PenInput.current = self
    self:registerPanZones()
    self:installFallbackHook()
    self:registerPlatformInput()
end

function PenInput:unregister()
    self:unregisterPlatformInput()
    self:cleanupFallbackHook()
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

function PenInput:registerPlatformInput()
    local Input = Device.input
    if Input and Input.registerStylusCallback then
        Input:registerStylusCallback(function(input, slot)
            return self:onStylusEvent(input, slot)
        end)
        self.stylus_registered = true
    else
        logger.warn("PenInput: stylus callback API not available")
    end
end

function PenInput:unregisterPlatformInput()
    local Input = Device.input
    if Input and Input.unregisterStylusCallback then
        Input:unregisterStylusCallback()
    end
    self.stylus_registered = false
end

function PenInput:installFallbackHook()
    if self.fallback then return end
    local Input = Device.input
    if not Input or not Input.gesture_detector then return end
    self.fallback = PenFallback:new(self)
    self.fallback:install()
end

function PenInput:cleanupFallbackHook()
    if self.fallback then
        self.fallback:cleanup()
        self.fallback = nil
    end
end

function PenInput:detectPenMirror(input, x, y)
    if self.pen_mirrored then return end
    local gd = input.gesture_detector
    if not gd or not gd.active_contacts or next(gd.active_contacts) == nil then
        return
    end
    for slot_no, contact in pairs(gd.active_contacts) do
        if slot_no ~= input.pen_slot then
            local tev = contact.current_tev
            if tev and tev.x and tev.y
                and math.abs(tev.x - x) <= self.lift_match_radius
                and math.abs(tev.y - y) <= self.lift_match_radius then
                self.pen_mirrored = true
                return
            end
        end
    end
end

function PenInput:onStylusEvent(input, slot)
    local plugin = self.plugin
    local x, y = self:transformCoordinates(slot.x or 0, slot.y or 0)
    local ret = false

    logger.dbg("PenInput:onStylusEvent",
        "slot=", slot.slot, "tool=", slot.tool, "id=", slot.id,
        "raw=", slot.x, slot.y, "pos=", x, y,
        "eraser=", self.eraser_active)

    if slot.tool == TOOL_TYPE_FINGER
        and input.pen_slot and slot.slot == input.pen_slot then
        return true
    end

    if not self:isPenTool(slot) then
        return false
    end

    if slot.tool == TOOL_TYPE_ERASER then
        return self:onEraserEvent(x, y, slot.id or -1)
    end

    if not self.pen_mirrored then
        self:detectPenMirror(input, slot.x or x, slot.y or y)
    end

    if slot.id and slot.id >= 0 then
        if self.pen_mirrored and plugin:isOverlayActive() then
            return true
        end
        if not self.pen_active and plugin:isOverlayActive() then return false end
        if not plugin:isEnabled() then return false end
        self.pen_lift_pending = false
        if not self.pen_active then
            self.pen_active = true
        end

        if plugin.current_stroke then
            plugin:addStrokePoint(x, y)
        elseif not plugin:isOverlayActive() then
            self.pen_lift_x = x
            self.pen_lift_y = y
            plugin:startStroke(x, y)
        end
        ret = true
    else
        local was_active = self.pen_active
        self.pen_active = false
        if plugin.current_stroke then
            plugin:endStroke()
            if was_active then
                self.pen_lift_pending = true
            end
        end

        if self.pen_mirrored and plugin:isOverlayActive() then
            return true
        end

        if not plugin:isOverlayActive() and plugin:isEnabled() and was_active then
            ret = true
        end
    end
    return ret
end

function PenInput:onEraserEvent(x, y, id)
    local plugin = self.plugin
    if plugin:isOverlayActive() then return false end
    if id >= 0 then
        self.eraser_active = true
        plugin:eraseStrokeAt(x, y)
        return true
    else
        self.eraser_active = false
        return true
    end
end

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
local PenInput = require("core/input/base")
local Device = require("device")
local logger = require("logger")

local PEN_GRACE_TIME_S = 1.0

local LinuxPenInput = {}

function LinuxPenInput:new(plugin)
    local o = PenInput:new(plugin)
    o.pen_grace_time = PEN_GRACE_TIME_S
    return setmetatable(o, { __index = LinuxPenInput })
end

function LinuxPenInput:registerPlatformInput()
    local Input = Device.input
    if Input and Input.registerStylusCallback then
        Input:registerStylusCallback(function(input, slot)
            return self:onStylusEvent(input, slot)
        end)
        self.stylus_registered = true
    else
        logger.warn("LinuxPenInput: stylus callback API not available")
    end
end

function LinuxPenInput:unregisterPlatformInput()
    local Input = Device.input
    if Input and Input.unregisterStylusCallback then
        Input:unregisterStylusCallback()
    end
    self.stylus_registered = false
end

setmetatable(LinuxPenInput, { __index = PenInput })

return LinuxPenInput
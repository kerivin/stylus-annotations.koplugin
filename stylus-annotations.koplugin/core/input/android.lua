local PenInput = require("core/input/base")
local Device = require("device")
local logger = require("logger")

local AndroidPenInput = {}

function AndroidPenInput:new(plugin)
    local o = PenInput:new(plugin)
    return setmetatable(o, { __index = AndroidPenInput })
end

function AndroidPenInput:registerPlatformInput()
    local Input = Device.input
    if Input and Input.registerStylusCallback then
        Input:registerStylusCallback(function(input, slot)
            return self:onStylusEvent(input, slot)
        end)
        self.stylus_registered = true
    else
        logger.warn("AndroidPenInput: stylus callback API not available")
    end
end

function AndroidPenInput:unregisterPlatformInput()
    local Input = Device.input
    if Input and Input.unregisterStylusCallback then
        Input:unregisterStylusCallback()
    end
    self.stylus_registered = false
end

setmetatable(AndroidPenInput, { __index = PenInput })

return AndroidPenInput
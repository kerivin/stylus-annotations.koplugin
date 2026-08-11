local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Draw = require("lib/draw")

local Screen = Device.screen

local SELECTION_WHITE = Blitbuffer.ColorRGB32(0xFF, 0xFF, 0xFF, 0xFF)

local Base = {}

function Base:new(plugin)
    local o = {
        plugin = plugin,
        ui = plugin.ui,
        view = plugin.view,
    }
    return setmetatable(o, { __index = Base })
end

function Base:getStrokeScreenWidth(stroke)
    return math.max(1, math.floor(stroke.width * (stroke.zoom or 1) + 0.5))
end

function Base:getPageZoom(page)
    return self:getZoom(page)
end

function Base:paintStroke(bb, x, y, stroke)
    local color = Draw.getRenderColor(stroke, self.ui.highlight)
    local sw = self:getStrokeScreenWidth(stroke)
    local spts = self:strokeToScreenPts(stroke)
    if not spts or #spts == 0 then return end
    local sph = {}
    for i = 1, #spts, 2 do
        sph[#sph + 1] = { x = x + spts[i], y = y + spts[i + 1] }
    end
    Draw.paintStrokePath(bb, sph, sw, color)
end

function Base:paintStrokeSolid(bb, x, y, stroke, color)
    local sw = self:getStrokeScreenWidth(stroke)
    local spts = self:strokeToScreenPts(stroke)
    if not spts or #spts == 0 then return end
    local sph = {}
    for i = 1, #spts, 2 do
        sph[#sph + 1] = { x = x + spts[i], y = y + spts[i + 1] }
    end
    Draw.paintStrokeSolid(bb, sph, sw, color)
end

function Base:renderStrokeToScreen(stroke)
    self:paintStroke(Screen.bb, 0, 0, stroke)
end

function Base:paintTo(bb, x, y)
    self:forEachVisibleStroke(function(stroke)
        self:paintStroke(bb, x, y, stroke)
    end)
    local current = self.plugin.current_stroke
    if current then
        self:paintStroke(bb, x, y, current)
    end

    local selected = self.plugin.selected_strokes
    for _, stroke in ipairs(selected) do
        local rx, ry, rw, rh = self.plugin.store:getSelectionRect(stroke, bb:getWidth(), bb:getHeight())
        if rx then
            bb:paintRect(rx, ry, rw, rh, Blitbuffer.COLOR_BLACK)
        end
    end
    for _, stroke in ipairs(selected) do
        self:paintStrokeSolid(bb, x, y, stroke, SELECTION_WHITE)
    end
end

return Base
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geometry = require("core/geometry")
local Draw = require("core/draw")

local Screen = Device.screen

local SELECTION_WHITE = Blitbuffer.ColorRGB32(0xFF, 0xFF, 0xFF, 0xFF)

local Mapping = {}

function Mapping:new(plugin)
    local o = {
        plugin = plugin,
        ui = plugin.ui,
        view = plugin.view,
    }
    return setmetatable(o, { __index = Mapping })
end

function Mapping:getStrokeScreenWidth(stroke)
    return math.max(1, math.floor(stroke.width * (stroke.zoom or 1) + 0.5))
end

function Mapping:packPoints(points)
    local coords = {}
    for i = 1, #points do
        coords[#coords + 1] = tostring(Geometry.pack(points[i]))
    end
    return "points={" .. table.concat(coords, ",") .. "}"
end

function Mapping:unpackPoints(pts)
    if not pts or type(pts[1]) == "table" then return nil end
    local points = {}
    for i = 1, #pts do
        local v = pts[i]
        if type(v) == "table" then
            points[i] = Geometry.unpack(v[1])
        else
            points[i] = Geometry.unpack(v)
        end
    end
    return points
end

function Mapping:toScreenPoints(spts, x, y)
    local sph = {}
    for i = 1, #spts, 2 do
        sph[#sph + 1] = { x = x + spts[i], y = y + spts[i + 1] }
    end
    return sph
end

function Mapping:paintStroke(bb, x, y, stroke)
    local color = Draw.getRenderColor(stroke, self.ui.highlight)
    local sw = self:getStrokeScreenWidth(stroke)
    local spts = self:strokeToScreenPts(stroke)
    if not spts or #spts == 0 then return end
    Draw.paintStrokePath(bb, self:toScreenPoints(spts, x, y), sw, color)
end

function Mapping:paintStrokeSolid(bb, x, y, stroke, color)
    local sw = self:getStrokeScreenWidth(stroke)
    local spts = self:strokeToScreenPts(stroke)
    if not spts or #spts == 0 then return end
    Draw.paintStrokeSolid(bb, self:toScreenPoints(spts, x, y), sw, color)
end

function Mapping:renderStrokeToScreen(stroke)
    self:paintStroke(Screen.bb, 0, 0, stroke)
end

function Mapping:paintSelection(bb, x, y)
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

function Mapping:paintTo(bb, x, y)
    self:forEachVisibleStroke(function(stroke)
        self:paintStroke(bb, x, y, stroke)
    end)
    local current = self.plugin.current_stroke
    if current then
        self:paintStroke(bb, x, y, current)
    end
    self:paintSelection(bb, x, y)
end

return Mapping
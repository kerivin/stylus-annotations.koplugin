local Device = require("device")
local Geometry = require("lib/geometry")
local Base = require("lib/adapters/base")

local Screen = Device.screen

local Reflow = {}

function Reflow:new(plugin, ui)
    local o = Base:new(plugin, ui)
    return setmetatable(o, { __index = Reflow })
end

function Reflow:getDoc()
    return self.ui.document
end

function Reflow:probeWord(x, y)
    local doc = self:getDoc()
    local wordbox = doc:getWordFromPosition({ x = x, y = y }, true)
    if not wordbox then
        wordbox = doc:getNearestWordAndBoxFromPosition({ x = x, y = y }, -1)
            or doc:getNearestWordAndBoxFromPosition({ x = x, y = y }, 1)
    end
    if wordbox and wordbox.pos0 and wordbox.pos1 and wordbox.sbox then
        return wordbox
    end
    return nil
end

function Reflow:initStroke(stroke, x, y)
    local wordbox = self:probeWord(x, y)
    if not wordbox then return false end
    local sbox = wordbox.sbox
    stroke.page = wordbox.page
    stroke.zoom = self:getZoom(wordbox.page)
    stroke.anchor = { pos0 = wordbox.pos0, pos1 = wordbox.pos1 }
    stroke.anchor_screen = { x = sbox.x, y = sbox.y }
    stroke.points = { x - sbox.x, y - sbox.y }
    return true
end

function Reflow:addPoint(stroke, x, y)
    local as = stroke.anchor_screen
    if not as then return end
    local pts = stroke.points
    local m = #pts
    local dx, dy = x - as.x, y - as.y
    if m >= 2 and pts[m - 1] == dx and pts[m] == dy then return end
    pts[m + 1], pts[m + 2] = dx, dy
    return true
end

function Reflow:strokeToScreenPts(stroke)
    local doc = self:getDoc()
    local boxes = doc:getScreenBoxesFromPositions(stroke.anchor.pos0, stroke.anchor.pos1, true)
    if not boxes or #boxes == 0 then return nil end
    local b = boxes[1]
    local pts = stroke.points
    local spts = {}
    for i = 1, #pts, 2 do
        spts[i] = b.x + pts[i]
        spts[i + 1] = b.y + pts[i + 1]
    end
    return spts
end

function Reflow:strokeCulled(stroke)
    local doc = self:getDoc()
    local cur = doc:getCurrentPos()
    local vh = self.view.visible_area and self.view.visible_area.h or Screen:getHeight()
    local dy = doc:getPosFromXPointer(stroke.anchor.pos0)
    if not dy then return true end
    return dy < cur - vh or dy > cur + 2 * vh
end

function Reflow:strokeSameContext(a, b)
    return a.page == b.page
end

function Reflow:forEachVisibleStroke(fn)
    for _, stroke in ipairs(self.plugin.strokes) do
        if not self:strokeCulled(stroke) then
            fn(stroke)
        end
    end
end

function Reflow:getVisiblePages()
    return { self:getDoc():getCurrentPage() }
end

function Reflow:getZoom(page)
    return Screen:scaleBySize(1)
end

function Reflow:isPaged()
    return false
end

function Reflow:serializeStroke(stroke)
    local pts = stroke.points
    local coords = {}
    for i = 1, #pts do
        coords[#coords + 1] = tostring(Geometry.pack(pts[i]))
    end
    return "anchor0=" .. string.format("%q", stroke.anchor.pos0)
        .. ",anchor1=" .. string.format("%q", stroke.anchor.pos1)
        .. ",points={" .. table.concat(coords, ",") .. "}"
end

function Reflow:deserializeStroke(data)
    if not data.anchor0 then return nil end
    local stroke = {
        id = data.id,
        width = data.width,
        color = data.color,
        zoom = data.zoom or 1,
        alpha = data.alpha or 1.0,
        datetime = data.datetime or 0,
        anchor = { pos0 = data.anchor0, pos1 = data.anchor1 },
    }
    local pts = data.points
    if not pts or type(pts[1]) == "table" then return nil end
    stroke.points = {}
    for i = 1, #pts do
        local v = pts[i]
        if type(v) == "table" then
            stroke.points[i] = Geometry.unpack(v[1])
        else
            stroke.points[i] = Geometry.unpack(v)
        end
    end
    stroke.page = self:getDoc():getPageFromXPointer(stroke.anchor.pos0)
    return stroke
end

setmetatable(Reflow, { __index = Base })

return Reflow
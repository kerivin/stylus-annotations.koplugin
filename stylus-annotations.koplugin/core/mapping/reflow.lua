local Device = require("device")
local Mapping = require("core/mapping/base")
local Geometry = require("core/geometry")
local logger = require("logger")

local Screen = Device.screen

local MAPPING_LOG_STATES_PER_STROKE = 3

local PROBE_MAX_DIST_PX = 900

local Reflow = {}

function Reflow:new(plugin)
    local o = Mapping:new(plugin)
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
        local cx = wordbox.sbox.x + wordbox.sbox.w / 2
        local cy = wordbox.sbox.y + wordbox.sbox.h / 2
        local dx, dy = cx - x, cy - y
        if dx * dx + dy * dy <= PROBE_MAX_DIST_PX * PROBE_MAX_DIST_PX then
            return wordbox
        end
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
    stroke.anchor_screen = { x = sbox.x, y = sbox.y, w = sbox.w, h = sbox.h }
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

function Reflow:anchorScale(stroke, b)
    local as = stroke.anchor_screen
    if not as or not as.w or not as.h or as.w <= 0 or as.h <= 0 then return 1, 1 end
    local sx, sy = 1, 1
    if b.w and b.w > 0 then
        sx = b.w / as.w
    end
    if b.h and b.h > 0 then
        sy = b.h / as.h
    end
    if sx < 0.05 then sx = 0.05 end
    if sx > 20 then sx = 20 end
    if sy < 0.05 then sy = 0.05 end
    if sy > 20 then sy = 20 end
    return sx, sy
end

function Reflow:strokeToScreenPts(stroke)
    local doc = self:getDoc()
    local boxes = doc:getScreenBoxesFromPositions(stroke.anchor.pos0, stroke.anchor.pos1, true)
    if not boxes or #boxes == 0 then return nil end
    local b = boxes[1]
    local sx, sy = self:anchorScale(stroke, b)
    local pts = stroke.points
    local spts = {}
    for i = 1, #pts, 2 do
        spts[i] = b.x + pts[i] * sx
        spts[i + 1] = b.y + pts[i + 1] * sy
    end
    self:maybeLogStrayMapping(stroke, spts, b)
    return spts
end

function Reflow:maybeLogStrayMapping(stroke, spts, b)
    local x0, y0, x1, y1 = Geometry.screenBounds(spts)
    if not x0 then return end
    local w, h = Screen:getWidth(), Screen:getHeight()
    local margin = Screen.scaleBySize and Screen:scaleBySize(8) or 8
    if x0 < -margin or y0 < -margin or x1 > w + margin or y1 > h + margin or x1 < 0 or y1 < 0 then
        local logged = stroke.mapping_debug_states or 0
        if logged < MAPPING_LOG_STATES_PER_STROKE then
            stroke.mapping_debug_states = logged + 1
            logger.info(
                "StylusAnnotations: stray mapping stroke", stroke.id,
                "anchor", string.format("%q", stroke.anchor.pos0),
                "bbox", table.concat{tostring(x0), ",", tostring(y0), ",", tostring(x1), ",", tostring(y1)},
                "screen", w, "x", h,
                "anchor_box", tostring(b.x), ",", tostring(b.y), ",", tostring(b.w), ",", tostring(b.h))
        end
    end
end

function Reflow:strokeCulled(stroke)
    local doc = self:getDoc()
    local cur = doc:getCurrentPos()
    local vh = self.view.visible_area and self.view.visible_area.h or Screen:getHeight()
    local dy = doc:getPosFromXPointer(stroke.anchor.pos0)
    if not dy then return true end
    return dy < cur - vh or dy > cur + 2 * vh
end

function Reflow:forEachVisibleStroke(fn)
    for _, stroke in ipairs(self.plugin.store.strokes) do
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

function Reflow:serializeStroke(stroke)
    local as = stroke.anchor_screen
    local extra = ""
    if as and as.w and as.h then
        extra = ",asw=" .. tostring(as.w) .. ",ash=" .. tostring(as.h)
    end
    return "anchor0=" .. string.format("%q", stroke.anchor.pos0)
        .. ",anchor1=" .. string.format("%q", stroke.anchor.pos1)
        .. extra
        .. "," .. self:packPoints(stroke.points)
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
    stroke.points = self:unpackPoints(data.points)
    if not stroke.points then return nil end
    if data.asw and data.ash then
        stroke.anchor_screen = { w = data.asw, h = data.ash }
    end
    stroke.page = self:getDoc():getPageFromXPointer(stroke.anchor.pos0)
    return stroke
end

setmetatable(Reflow, { __index = Mapping })

return Reflow
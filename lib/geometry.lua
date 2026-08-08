--[[--
Geometry helpers for the Stylus annotations plugin.
Pure functions for stroke hit-testing.

@module stylus_annotations.lib.geometry
--]]--

local Geometry = {}

--- Squared distance from a point to a line segment.
local function pointSegmentDistanceSq(px, py, x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    local len_sq = dx * dx + dy * dy
    local t = 0
    if len_sq > 0 then
        t = ((px - x1) * dx + (py - y1) * dy) / len_sq
    end
    t = math.max(0, math.min(1, t))
    local cx, cy = x1 + t * dx, y1 + t * dy
    local ex, ey = px - cx, py - cy
    return ex * ex + ey * ey
end

--- Squared distance from a point to a stroke's polyline.
-- @param px, py point coordinates (native page space)
-- @param stroke table with a points array of { x =, y = } entries
-- @return number squared distance, math.huge if the stroke has no points
function Geometry.strokeDistanceSq(px, py, stroke)
    if not stroke or not stroke.points or #stroke.points == 0 then
        return math.huge
    end
    local min_sq = math.huge
    local n = #stroke.points
    for i = 1, n - 1 do
        local a, b = stroke.points[i], stroke.points[i + 1]
        local d = pointSegmentDistanceSq(px, py, a.x, a.y, b.x, b.y)
        if d < min_sq then min_sq = d end
    end
    if n == 1 then
        local p = stroke.points[1]
        local dx, dy = px - p.x, py - p.y
        if dx * dx + dy * dy < min_sq then
            min_sq = dx * dx + dy * dy
        end
    end
    return min_sq
end

--- True if the point is within threshold of the stroke.
function Geometry.isPointNearStroke(px, py, stroke, threshold)
    return Geometry.strokeDistanceSq(px, py, stroke) <= threshold * threshold
end

--- Axis-aligned bounding box of a stroke's points (native page space).
-- @param stroke table with a points array of { x =, y = } entries
-- @return x0, y0, x1, y1 (inclusive bounds) or nil if the stroke has no points
function Geometry.strokeBBox(stroke)
    local pts = stroke and stroke.points
    if not pts or #pts == 0 then
        return nil
    end
    local x0, y0 = pts[1].x, pts[1].y
    local x1, y1 = x0, y0
    for i = 2, #pts do
        local p = pts[i]
        if p.x < x0 then x0 = p.x end
        if p.x > x1 then x1 = p.x end
        if p.y < y0 then y0 = p.y end
        if p.y > y1 then y1 = p.y end
    end
    return x0, y0, x1, y1
end

--- True if two strokes' bounding boxes intersect (positive overlap area,
-- touching edges/corners don't count).
function Geometry.strokesIntersect(a, b)
    local ax0, ay0, ax1, ay1 = Geometry.strokeBBox(a)
    local bx0, by0, bx1, by1 = Geometry.strokeBBox(b)
    if not ax0 or not bx0 then return false end
    return ax0 < bx1 and bx0 < ax1 and ay0 < by1 and by0 < ay1
end

return Geometry

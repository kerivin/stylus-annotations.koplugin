local Geometry = {}

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

function Geometry.strokeDistanceSq(px, py, stroke)
    local pts = stroke and stroke.points
    if not pts or #pts == 0 then
        return math.huge
    end
    local m = #pts
    if m == 2 then
        local dx, dy = px - pts[1], py - pts[2]
        return dx * dx + dy * dy
    end
    local min_sq = math.huge
    for i = 1, m - 3, 2 do
        local d = pointSegmentDistanceSq(px, py, pts[i], pts[i + 1], pts[i + 2], pts[i + 3])
        if d < min_sq then min_sq = d end
    end
    return min_sq
end

function Geometry.strokeBBox(stroke)
    local pts = stroke and stroke.points
    if not pts or #pts == 0 then
        return nil
    end
    local m = #pts
    local x0, y0 = pts[1], pts[2]
    local x1, y1 = x0, y0
    for i = 3, m, 2 do
        local px, py = pts[i], pts[i + 1]
        if px < x0 then x0 = px end
        if px > x1 then x1 = px end
        if py < y0 then y0 = py end
        if py > y1 then y1 = py end
    end
    return x0, y0, x1, y1
end

function Geometry.strokesIntersect(a, b)
    local ax0, ay0, ax1, ay1 = Geometry.strokeBBox(a)
    local bx0, by0, bx1, by1 = Geometry.strokeBBox(b)
    if not ax0 or not bx0 then return false end
    return ax0 < bx1 and bx0 < ax1 and ay0 < by1 and by0 < ay1
end

function Geometry.screenBounds(spts)
    local n = math.floor(#spts / 2)
    if n == 0 then return end
    local x0, y0 = spts[1], spts[2]
    local x1, y1 = x0, y0
    for i = 1, n do
        local px, py = spts[2 * i - 1], spts[2 * i]
        if px < x0 then x0 = px end
        if px > x1 then x1 = px end
        if py < y0 then y0 = py end
        if py > y1 then y1 = py end
    end
    return x0, y0, x1, y1
end

function Geometry.pointsBounds(points)
    local n = #points
    if n == 0 then return end
    local x0, y0 = points[1].x, points[1].y
    local x1, y1 = x0, y0
    for i = 2, n do
        local px, py = points[i].x, points[i].y
        if px < x0 then x0 = px end
        if px > x1 then x1 = px end
        if py < y0 then y0 = py end
        if py > y1 then y1 = py end
    end
    return x0, y0, x1, y1
end

function Geometry.mergeRect(region, x, y, w, h)
    if not region then return { x = x, y = y, w = w, h = h } end
    local x0 = math.min(region.x, x)
    local y0 = math.min(region.y, y)
    local x1 = math.max(region.x + region.w, x + w)
    local y1 = math.max(region.y + region.h, y + h)
    return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

function Geometry.clampRect(x, y, w, h, width, height)
    local rx = math.max(0, math.floor(x))
    local ry = math.max(0, math.floor(y))
    local rw = math.min(width - rx, math.ceil(w))
    local rh = math.min(height - ry, math.ceil(h))
    if rw <= 0 or rh <= 0 then return end
    return rx, ry, rw, rh
end

function Geometry.rdpSimplifyIndices(spts, tol)
    local n = math.floor(#spts / 2)
    local keep = {}
    for i = 1, n do keep[i] = false end
    local stack = { { 1, n } }
    while #stack > 0 do
        local seg = table.remove(stack)
        local a, b = seg[1], seg[2]
        if b > a + 1 then
            local x1, y1 = spts[2 * a - 1], spts[2 * a]
            local x2, y2 = spts[2 * b - 1], spts[2 * b]
            local vx, vy = x2 - x1, y2 - y1
            local inv_len = (vx * vx + vy * vy) > 0 and (1 / math.sqrt(vx * vx + vy * vy)) or 0
            local split, max_d = -1, 0
            for j = a + 1, b - 1 do
                local pjx, pjy = spts[2 * j - 1], spts[2 * j]
                local d = math.abs((pjy - y1) * vx - (pjx - x1) * vy) * inv_len
                if d > max_d then
                    max_d, split = d, j
                end
            end
            if max_d > tol then
                stack[#stack + 1] = { a, split }
                stack[#stack + 1] = { split, b }
            end
        end
        keep[a], keep[b] = true, true
    end
    local idx = {}
    for i = 1, n do
        if keep[i] then
            idx[#idx + 1] = i
        end
    end
    return idx
end

return Geometry
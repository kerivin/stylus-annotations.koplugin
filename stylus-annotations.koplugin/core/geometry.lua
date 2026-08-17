local Geometry = {}

local COORD_SCALE = 4

Geometry.ROTATION_UPRIGHT = 0
Geometry.ROTATION_CLOCKWISE = 1
Geometry.ROTATION_UPSIDE_DOWN = 2
Geometry.ROTATION_COUNTER_CLOCKWISE = 3

function Geometry.transformForRotation(x, y, rotation, screen_width, screen_height)
    if rotation == Geometry.ROTATION_UPRIGHT then
        return x, y
    elseif rotation == Geometry.ROTATION_CLOCKWISE then
        return screen_width - y, x
    elseif rotation == Geometry.ROTATION_UPSIDE_DOWN then
        return screen_width - x, screen_height - y
    elseif rotation == Geometry.ROTATION_COUNTER_CLOCKWISE then
        return y, screen_height - x
    end
    return x, y
end

function Geometry.pack(v)
    return math.floor(v * COORD_SCALE + 0.5)
end

function Geometry.unpack(v)
    return v / COORD_SCALE
end

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

function Geometry.mergeBounds(x0, y0, x1, y1, u0, v0, u1, v1)
    if not x0 then return u0, v0, u1, v1 end
    return math.min(x0, u0), math.min(y0, v0), math.max(x1, u1), math.max(y1, v1)
end

function Geometry.boundsOverlap(x0, y0, x1, y1, u0, v0, u1, v1, pad_a, pad_b)
    local pa = pad_a or 0
    local pb = pad_b or pa
    return x0 - pa < u1 + pb and u0 - pb < x1 + pa
        and y0 - pa < v1 + pb and v0 - pb < y1 + pa
end

function Geometry.paddedRect(x0, y0, x1, y1, pad)
    local x = math.min(x0, x1) - pad
    local y = math.min(y0, y1) - pad
    return { x = x, y = y, w = math.abs(x1 - x0) + 2 * pad, h = math.abs(y1 - y0) + 2 * pad }
end

function Geometry.strokePad(width, zoom)
    return math.max(4, math.floor(width * (zoom or 1)) + 2)
end

function Geometry.simplifyPoints(pts, spts, min_spacing, tol)
    local num = math.floor(#pts / 2)
    local kept = { pts[1], pts[2] }
    local kept_s = { spts[1], spts[2] }
    local lx, ly = kept_s[1], kept_s[2]
    for i = 2, num - 1 do
        local xi, yi = pts[2 * i - 1], pts[2 * i]
        local sx, sy = spts[2 * i - 1], spts[2 * i]
        local dx, dy = sx - lx, sy - ly
        if dx * dx + dy * dy >= min_spacing * min_spacing then
            kept[#kept + 1], kept[#kept + 2] = xi, yi
            kept_s[#kept_s + 1], kept_s[#kept_s + 2] = sx, sy
            lx, ly = sx, sy
        end
    end
    kept[#kept + 1], kept[#kept + 2] = pts[#pts - 1], pts[#pts]
    kept_s[#kept_s + 1], kept_s[#kept_s + 2] = spts[#spts - 1], spts[#spts]

    local num_kept = math.floor(#kept / 2)
    if num_kept <= 3 then return kept end
    local idx = Geometry.rdpSimplifyIndices(kept_s, tol)
    if #idx == num_kept then return kept end
    local out = {}
    for p = 1, #idx do
        local k = idx[p]
        out[#out + 1] = kept[2 * k - 1]
        out[#out + 1] = kept[2 * k]
    end
    return out
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
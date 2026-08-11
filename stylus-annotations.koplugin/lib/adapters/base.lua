local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geometry = require("lib/geometry")
local Draw = require("lib/draw")

local Screen = Device.screen

local SELECTION_WHITE = Blitbuffer.ColorRGB32(0xFF, 0xFF, 0xFF, 0xFF)
local HIT_TEST_THRESHOLD_PX = 25
local MIN_SPACING = 2.0

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

function Base:getStrokeScreenBox(stroke)
    local spts = self:strokeToScreenPts(stroke)
    if not spts then return end
    return Geometry.screenBounds(spts)
end

function Base:getSelectionRect(stroke, width, height)
    local x0, y0, x1, y1 = self:getStrokeScreenBox(stroke)
    if not x0 then return end
    local pad = math.max(4, math.floor(stroke.width * (stroke.zoom or 1)) + 2)
    return Geometry.clampRect(x0 - pad, y0 - pad, (x1 - x0) + 2 * pad, (y1 - y0) + 2 * pad, width, height)
end

function Base:getSelectionUnionBox(strokes)
    local x0, y0, x1, y1
    for _, stroke in ipairs(strokes) do
        local sx0, sy0, sx1, sy1 = self:getStrokeScreenBox(stroke)
        if sx0 then
            if not x0 or sx0 < x0 then x0 = sx0 end
            if not y0 or sy0 < y0 then y0 = sy0 end
            if not x1 or sx1 > x1 then x1 = sx1 end
            if not y1 or sy1 > y1 then y1 = sy1 end
        end
    end
    return x0, y0, x1, y1
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
        local rx, ry, rw, rh = self:getSelectionRect(stroke, bb:getWidth(), bb:getHeight())
        if rx then
            bb:paintRect(rx, ry, rw, rh, Blitbuffer.COLOR_BLACK)
        end
    end
    for _, stroke in ipairs(selected) do
        self:paintStrokeSolid(bb, x, y, stroke, SELECTION_WHITE)
    end
end

function Base:decimatePoints(stroke)
    local pts = stroke.points
    local spts = self:strokeToScreenPts(stroke)
    local num = math.floor(#pts / 2)
    if not spts or num <= 2 then return pts end
    local kept = { pts[1], pts[2] }
    local kept_s = { spts[1], spts[2] }
    local lx, ly = kept_s[1], kept_s[2]
    for i = 2, num - 1 do
        local xi, yi = pts[2 * i - 1], pts[2 * i]
        local sx, sy = spts[2 * i - 1], spts[2 * i]
        local dx, dy = sx - lx, sy - ly
        if dx * dx + dy * dy >= MIN_SPACING * MIN_SPACING then
            kept[#kept + 1], kept[#kept + 2] = xi, yi
            kept_s[#kept_s + 1], kept_s[#kept_s + 2] = sx, sy
            lx, ly = sx, sy
        end
    end
    kept[#kept + 1], kept[#kept + 2] = pts[#pts - 1], pts[#pts]
    kept_s[#kept_s + 1], kept_s[#kept_s + 2] = spts[#spts - 1], spts[#spts]

    local num_kept = math.floor(#kept / 2)
    if num_kept <= 3 then return kept end
    local tol = math.min(3.0, math.max(0.75, self:getStrokeScreenWidth(stroke) / 4))
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

function Base:findStrokeAt(x, y)
    local strokes = self.plugin.strokes
    if #strokes == 0 then return nil end
    local threshold = HIT_TEST_THRESHOLD_PX
    local best, best_sq
    for _, stroke in ipairs(strokes) do
        if not self:strokeCulled(stroke) then
            local spts = self:strokeToScreenPts(stroke)
            if spts and #spts > 0 then
                local d = Geometry.strokeDistanceSq(x, y, { points = spts })
                if d <= threshold * threshold and (not best_sq or d < best_sq) then
                    best, best_sq = stroke, d
                end
            end
        end
    end
    return best
end

function Base:strokesIntersectMid(a, b)
    return self:strokeSameContext(a, b)
        and Geometry.strokesIntersect({ points = self:strokeToScreenPts(a) or {} },
                                      { points = self:strokeToScreenPts(b) or {} })
end

function Base:selectStrokesChain(stroke)
    local selection = { stroke }
    local seen = { [stroke] = true }
    local queue = { stroke }
    local i = 1
    while i <= #queue do
        local cur = queue[i]
        i = i + 1
        for _, s in ipairs(self.plugin.strokes) do
            if not seen[s] and self:strokesIntersectMid(cur, s) then
                seen[s] = true
                selection[#selection + 1] = s
                queue[#queue + 1] = s
            end
        end
    end
    return selection
end

function Base:rebuildPageIndex()
    local plugin = self.plugin
    plugin.strokes_by_page = {}
    for i, stroke in ipairs(plugin.strokes) do
        if stroke.page then
            plugin.strokes_by_page[stroke.page] = plugin.strokes_by_page[stroke.page] or {}
            table.insert(plugin.strokes_by_page[stroke.page], i)
        end
    end
end

return Base
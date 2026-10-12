local Geometry = require("core/geometry")
local lfs = require("libs/libkoreader-lfs")

local StrokeStore = {}

local HIT_TEST_THRESHOLD_PX = 25
local MIN_SPACING = 2.0

StrokeStore.STORAGE_VERSION = 1

local NOOP_LOGGER = {
    info = function() end,
    warn = function() end,
    err = function() end,
}

function StrokeStore:new(mapper, logger)
    local o = {
        mapper = mapper,
        logger = logger or NOOP_LOGGER,
        strokes = {},
        strokes_by_page = {},
        split_counter = os.time(),
    }
    return setmetatable(o, { __index = StrokeStore })
end

function StrokeStore:add(stroke)
    table.insert(self.strokes, stroke)
    if stroke.page then
        self.strokes_by_page[stroke.page] = self.strokes_by_page[stroke.page] or {}
        table.insert(self.strokes_by_page[stroke.page], #self.strokes)
    end
end

function StrokeStore:rebuildPageIndex()
    self.strokes_by_page = {}
    local strokes_by_page = self.strokes_by_page
    for i, stroke in ipairs(self.strokes) do
        if stroke.page then
            strokes_by_page[stroke.page] = strokes_by_page[stroke.page] or {}
            table.insert(strokes_by_page[stroke.page], i)
        end
    end
end

local function filterStrokes(self, keep)
    local kept = {}
    local removed = 0
    for _, stroke in ipairs(self.strokes) do
        if keep(stroke) then
            kept[#kept + 1] = stroke
        else
            removed = removed + 1
        end
    end
    self.strokes = kept
    self:rebuildPageIndex()
    return removed
end

function StrokeStore:remove(strokes)
    local to_delete = {}
    for _, stroke in ipairs(strokes) do
        to_delete[stroke] = true
    end
    return filterStrokes(self, function(stroke)
        return not to_delete[stroke]
    end)
end

function StrokeStore:removeByPage(pages)
    local page_set = {}
    for _, page in ipairs(pages) do
        page_set[page] = true
    end
    return filterStrokes(self, function(stroke)
        return not page_set[stroke.page]
    end)
end

function StrokeStore:removeAll()
    return filterStrokes(self, function()
        return false
    end)
end

function StrokeStore:setAttribute(strokes, attribute, value)
    for _, stroke in ipairs(strokes) do
        stroke[attribute] = value
    end
end

function StrokeStore:findStrokeAt(x, y)
    local strokes = self.strokes
    if #strokes == 0 then return nil end
    local mapper = self.mapper
    local threshold = HIT_TEST_THRESHOLD_PX
    local best, best_sq
    for _, stroke in ipairs(strokes) do
        if not mapper:strokeCulled(stroke) then
            local spts = mapper:strokeToScreenPts(stroke)
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

function StrokeStore:findStrokesInPolygon(polygon)
    local selected = {}
    if not polygon or #polygon < 3 then return selected end
    local mapper = self.mapper
    for _, stroke in ipairs(self.strokes) do
        if not mapper:strokeCulled(stroke) then
            local points = mapper:strokeToScreenPts(stroke)
            if Geometry.polylineIntersectsPolygon(points, polygon) then
                selected[#selected + 1] = stroke
            end
        end
    end
    return selected
end

function StrokeStore:eraseAt(x, y)
    local stroke = self:findStrokeAt(x, y)
    if not stroke then return 0 end
    return self:remove({ stroke })
end

local function cloneStroke(stroke, points, id)
    local copy = {}
    for key, value in pairs(stroke) do
        if key ~= "points" then
            if type(value) == "table" then
                local nested = {}
                for nested_key, nested_value in pairs(value) do
                    nested[nested_key] = nested_value
                end
                copy[key] = nested
            else
                copy[key] = value
            end
        end
    end
    copy.points = points
    if id then copy.id = id end
    return copy
end

local function pointAt(points, index, t)
    local ax, ay = points[index * 2 - 1], points[index * 2]
    local bx, by = points[index * 2 + 1], points[index * 2 + 2]
    return ax + (bx - ax) * t, ay + (by - ay) * t
end

local function appendPoint(points, x, y)
    local count = #points
    if count >= 2 then
        local dx, dy = x - points[count - 1], y - points[count]
        if dx * dx + dy * dy < 0.0001 then return end
    end
    points[#points + 1], points[#points + 2] = x, y
end

local function outsideCircleIntervals(ax, ay, bx, by, cx, cy, radius_sq)
    local dx, dy = bx - ax, by - ay
    local a = dx * dx + dy * dy
    if a == 0 then
        local ex, ey = ax - cx, ay - cy
        if ex * ex + ey * ey < radius_sq then return {}, true end
        return { { 0, 1 } }, false
    end

    local fx, fy = ax - cx, ay - cy
    local closest_t = math.max(0, math.min(1, -(fx * dx + fy * dy) / a))
    local qx, qy = fx + closest_t * dx, fy + closest_t * dy
    if qx * qx + qy * qy >= radius_sq then return { { 0, 1 } }, false end

    local bterm = 2 * (fx * dx + fy * dy)
    local cterm = fx * fx + fy * fy - radius_sq
    local discriminant = bterm * bterm - 4 * a * cterm
    if discriminant <= 0 then return { { 0, 1 } }, false end
    local root = math.sqrt(discriminant)
    local enter = math.max(0, (-bterm - root) / (2 * a))
    local leave = math.min(1, (-bterm + root) / (2 * a))
    if leave <= enter then return { { 0, 1 } }, false end

    local intervals = {}
    if enter > 0.00001 then intervals[#intervals + 1] = { 0, enter } end
    if leave < 0.99999 then intervals[#intervals + 1] = { leave, 1 } end
    return intervals, true
end

local function eraserPieces(stroke, screen_points, x, y, radius)
    local source = stroke.points
    local count = math.floor(#screen_points / 2)
    local pieces, current = {}, {}
    local changed = false
    local radius_sq = radius * radius

    local function finishPiece()
        if #current >= 2 then
            pieces[#pieces + 1] = current
        end
        current = {}
    end

    if count == 1 then
        local dx, dy = screen_points[1] - x, screen_points[2] - y
        if dx * dx + dy * dy < radius_sq then return {}, true end
        return { source }, false
    end

    for i = 1, count - 1 do
        local ax, ay = screen_points[2 * i - 1], screen_points[2 * i]
        local bx, by = screen_points[2 * i + 1], screen_points[2 * i + 2]
        local intervals, hit = outsideCircleIntervals(ax, ay, bx, by, x, y, radius_sq)
        if hit then changed = true end
        if #intervals == 0 then
            finishPiece()
        else
            for _, interval in ipairs(intervals) do
                local t0, t1 = interval[1], interval[2]
                if t0 > 0.00001 then finishPiece() end
                appendPoint(current, pointAt(source, i, t0))
                local ex, ey = pointAt(source, i, t1)
                appendPoint(current, ex, ey)
                if t1 < 0.99999 then finishPiece() end
            end
        end
    end
    finishPiece()
    if not changed then return { source }, false end
    return pieces, true
end

function StrokeStore:erasePartialAt(x, y, radius)
    local changes = {}
    local mapper = self.mapper
    for index, stroke in ipairs(self.strokes) do
        if not mapper:strokeCulled(stroke) then
            local screen_points = mapper:strokeToScreenPts(stroke)
            if screen_points and #screen_points > 0 then
                local erase_radius = radius + mapper:getStrokeScreenWidth(stroke) / 2
                local x0, y0, x1, y1 = Geometry.screenBounds(screen_points)
                if x0 and x >= x0 - erase_radius and x <= x1 + erase_radius
                    and y >= y0 - erase_radius and y <= y1 + erase_radius then
                    local pieces, changed = eraserPieces(stroke, screen_points, x, y, erase_radius)
                    if changed then
                        local root = stroke._erase_root or stroke
                        local before_points = {}
                        for i, point in ipairs(stroke.points) do
                            before_points[i] = point
                        end
                        local before = { stroke = stroke, points = before_points }
                        local replacements = {}
                        if #pieces > 0 then
                            stroke.points = pieces[1]
                            stroke._erase_root = root
                            replacements[1] = stroke
                            for i = 2, #pieces do
                                self.split_counter = self.split_counter + 1
                                local split = cloneStroke(stroke, pieces[i],
                                    tostring(stroke.id) .. "_erase" .. tostring(self.split_counter))
                                split._erase_root = root
                                replacements[#replacements + 1] = split
                            end
                        end
                        changes[#changes + 1] = {
                            index = index,
                            root = root,
                            sources = { stroke },
                            before = { before },
                            after = replacements,
                        }
                    end
                end
            end
        end
    end

    for i = #changes, 1, -1 do
        local change = changes[i]
        table.remove(self.strokes, change.index)
        for j = #change.after, 1, -1 do
            table.insert(self.strokes, change.index, change.after[j])
        end
    end
    if #changes > 0 then self:rebuildPageIndex() end
    return #changes, changes
end

function StrokeStore:applyChanges(changes, use_before)
    local function applyChange(change, index)
        local remove_count = use_before and #change.after or #change.before
        for _ = 1, remove_count do
            table.remove(self.strokes, index)
        end
        if use_before then
            for j = #change.before, 1, -1 do
                local entry = change.before[j]
                entry.stroke.points = entry.points
                table.insert(self.strokes, index, entry.stroke)
            end
        else
            for j = #change.after, 1, -1 do
                local entry = change.after[j]
                entry.stroke.points = entry.points
                table.insert(self.strokes, index, entry.stroke)
            end
        end
    end

    if use_before then
        for i = #changes, 1, -1 do
            local offset = 0
            for j = 1, i - 1 do
                offset = offset + #changes[j].after - #changes[j].before
            end
            applyChange(changes[i], changes[i].index + offset)
        end
    else
        local offset = 0
        for i = 1, #changes do
            local change = changes[i]
            applyChange(change, change.index + offset)
            offset = offset + #change.after - #change.before
        end
    end
    self:rebuildPageIndex()
end

function StrokeStore:strokesIntersectMid(a, b)
    local mapper = self.mapper
    local as = mapper:strokeToScreenPts(a)
    local bs = mapper:strokeToScreenPts(b)
    if not as or not bs then return false end
    local ax0, ay0, ax1, ay1 = Geometry.screenBounds(as)
    local bx0, by0, bx1, by1 = Geometry.screenBounds(bs)
    if not ax0 or not bx0 then return false end
    return Geometry.boundsOverlap(ax0, ay0, ax1, ay1, bx0, by0, bx1, by1,
        Geometry.strokePad(a.width, a.zoom), Geometry.strokePad(b.width, b.zoom))
end

function StrokeStore:selectStrokesChain(stroke)
    local page = stroke.page
    local selection = { stroke }
    local seen = { [stroke] = true }
    local queue = { stroke }
    local i = 1
    while i <= #queue do
        local cur = queue[i]
        i = i + 1
        for _, idx in ipairs(self.strokes_by_page[page] or {}) do
            local s = self.strokes[idx]
            if not seen[s] and self:strokesIntersectMid(cur, s) then
                seen[s] = true
                selection[#selection + 1] = s
                queue[#queue + 1] = s
            end
        end
    end
    return selection
end

function StrokeStore:decimatePoints(stroke)
    local pts = stroke.points
    local spts = self.mapper:strokeToScreenPts(stroke)
    local num = math.floor(#pts / 2)
    if not spts or num <= 2 then return pts end
    local tol = math.min(3.0, math.max(0.75, self.mapper:getStrokeScreenWidth(stroke) / 4))
    return Geometry.simplifyPoints(pts, spts, MIN_SPACING, tol)
end

function StrokeStore:getStrokeScreenBox(stroke)
    local spts = self.mapper:strokeToScreenPts(stroke)
    if not spts then return end
    return Geometry.screenBounds(spts)
end

function StrokeStore:getSelectionRect(stroke, width, height)
    local x0, y0, x1, y1 = self:getStrokeScreenBox(stroke)
    if not x0 then return end
    local rect = Geometry.paddedRect(x0, y0, x1, y1, Geometry.strokePad(stroke.width, stroke.zoom))
    return Geometry.clampRect(rect.x, rect.y, rect.w, rect.h, width, height)
end

function StrokeStore:getSelectionUnionBox(strokes)
    local x0, y0, x1, y1
    for _, stroke in ipairs(strokes) do
        local sx0, sy0, sx1, sy1 = self:getStrokeScreenBox(stroke)
        if sx0 then
            x0, y0, x1, y1 = Geometry.mergeBounds(x0, y0, x1, y1, sx0, sy0, sx1, sy1)
        end
    end
    return x0, y0, x1, y1
end

function StrokeStore:save(filepath)
    if not filepath then
        self.logger.warn("StrokeStore: no filepath given, skipping save")
        return
    end
    local strokes = self.strokes
    if #strokes == 0 then
        if lfs.attributes(filepath, "mode") == "file" then
            os.remove(filepath)
            self.logger.info("StrokeStore: no strokes, removed", filepath)
        end
        return
    end
    local mapper = self.mapper
    local out = { "return {", tostring(StrokeStore.STORAGE_VERSION), ",strokes={" }
    for i = 1, #strokes do
        local stroke = strokes[i]
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = "{id=" .. string.format("%q", tostring(stroke.id))
        out[#out + 1] = "," .. mapper:serializeStroke(stroke)
        out[#out + 1] = ",width=" .. tostring(stroke.width)
        out[#out + 1] = ",color=" .. string.format("%q", stroke.color)
        if (stroke.zoom or 1) ~= 1 then
            out[#out + 1] = ",zoom=" .. tostring(stroke.zoom or 1)
        end
        if (stroke.alpha or 1) ~= 1 then
            out[#out + 1] = ",alpha=" .. tostring(stroke.alpha or 1)
        end
        out[#out + 1] = ",datetime=" .. tostring(stroke.datetime or 0)
        out[#out + 1] = "}"
    end
    out[#out + 1] = "}}\n"

    local f, werr = io.open(filepath, "w")
    if f then
        f:write(table.concat(out))
        f:close()
        self.logger.info("StrokeStore: saved", #strokes, "strokes")
    else
        self.logger.err("StrokeStore: failed to write strokes:", werr)
    end
end

function StrokeStore:load(filepath)
    self.strokes = {}
    self:rebuildPageIndex()
    if not filepath then return false end
    local f = io.open(filepath, "r")
    if not f then return false end
    f:close()
    local ok, data = pcall(dofile, filepath)
    if ok and data and data.strokes then
        local saved_version = self:migrateStrokes(data)
        local loaded = {}
        for _, stroke_data in ipairs(data.strokes) do
            local stroke = self.mapper:deserializeStroke(stroke_data)
            if stroke then
                loaded[#loaded + 1] = stroke
            end
        end
        self.strokes = loaded
        self:rebuildPageIndex()
        self.logger.info("StrokeStore: loaded", #self.strokes, "strokes from", filepath)
        return saved_version ~= StrokeStore.STORAGE_VERSION
    end
    return false
end

function StrokeStore:migrateStrokes(data)
    local version = data.version or StrokeStore.STORAGE_VERSION
    if version > StrokeStore.STORAGE_VERSION then
        self.logger.warn("StrokeStore: sidecar version", version,
            "newer than supported", StrokeStore.STORAGE_VERSION, "; attempting to load anyway")
    end
    data.version = StrokeStore.STORAGE_VERSION
    return version
end

return StrokeStore

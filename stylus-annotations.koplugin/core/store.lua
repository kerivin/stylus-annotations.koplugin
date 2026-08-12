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

function StrokeStore:remove(strokes)
    local to_delete = {}
    for _, stroke in ipairs(strokes) do
        to_delete[stroke] = true
    end
    local keep = {}
    local removed = 0
    for _, stroke in ipairs(self.strokes) do
        if to_delete[stroke] then
            removed = removed + 1
        else
            keep[#keep + 1] = stroke
        end
    end
    self.strokes = keep
    self:rebuildPageIndex()
    return removed
end

function StrokeStore:removeByPage(pages)
    local page_set = {}
    for _, page in ipairs(pages) do
        page_set[page] = true
    end
    local keep = {}
    local removed = 0
    for _, stroke in ipairs(self.strokes) do
        if page_set[stroke.page] then
            removed = removed + 1
        else
            keep[#keep + 1] = stroke
        end
    end
    self.strokes = keep
    self:rebuildPageIndex()
    return removed
end

function StrokeStore:removeAll()
    local removed = #self.strokes
    self.strokes = {}
    self:rebuildPageIndex()
    return removed
end

function StrokeStore:setField(strokes, field, value)
    for _, stroke in ipairs(strokes) do
        stroke[field] = value
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

function StrokeStore:strokesIntersectMid(a, b)
    local mapper = self.mapper
    return Geometry.strokesIntersect({ points = mapper:strokeToScreenPts(a) or {} },
                                      { points = mapper:strokeToScreenPts(b) or {} })
end

function StrokeStore:selectStrokesChain(stroke)
    local selection = { stroke }
    local seen = { [stroke] = true }
    local queue = { stroke }
    local i = 1
    while i <= #queue do
        local cur = queue[i]
        i = i + 1
        for _, s in ipairs(self.strokes) do
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
    local tol = math.min(3.0, math.max(0.75, self.mapper:getStrokeScreenWidth(stroke) / 4))
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

function StrokeStore:getStrokeScreenBox(stroke)
    local spts = self.mapper:strokeToScreenPts(stroke)
    if not spts then return end
    return Geometry.screenBounds(spts)
end

function StrokeStore:getSelectionRect(stroke, width, height)
    local x0, y0, x1, y1 = self:getStrokeScreenBox(stroke)
    if not x0 then return end
    local pad = math.max(4, math.floor(stroke.width * (stroke.zoom or 1)) + 2)
    return Geometry.clampRect(x0 - pad, y0 - pad, (x1 - x0) + 2 * pad, (y1 - y0) + 2 * pad, width, height)
end

function StrokeStore:getSelectionUnionBox(strokes)
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
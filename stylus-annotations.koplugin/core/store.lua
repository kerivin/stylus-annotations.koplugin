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

function StrokeStore:eraseAt(x, y)
    local stroke = self:findStrokeAt(x, y)
    if not stroke then return 0 end
    return self:remove({ stroke })
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
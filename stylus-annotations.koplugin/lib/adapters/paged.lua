local Geometry = require("lib/geometry")
local Base = require("lib/adapters/base")

local Paged = {}

function Paged:new(plugin, ui)
    local o = Base:new(plugin, ui)
    return setmetatable(o, { __index = Paged })
end

function Paged:initStroke(stroke, x, y)
    local pos = self.view:screenToPageTransform({ x = x, y = y })
    stroke.page = pos.page
    stroke.zoom = pos.zoom or 1
    stroke.points = { pos.x, pos.y }
    return true
end

function Paged:addPoint(stroke, x, y)
    local pos = self.view:screenToPageTransform({ x = x, y = y })
    if pos.page ~= stroke.page then return end
    local pts = stroke.points
    local m = #pts
    if m >= 2 and pts[m - 1] == pos.x and pts[m] == pos.y then return end
    pts[m + 1], pts[m + 2] = pos.x, pos.y
    return true
end

function Paged:pageToScreenPoint(page, x_p, y_p)
    local view = self.view
    if view.page_scroll then
        local acc_y = 0
        for _, state in ipairs(view.page_states) do
            if state.page == page then
                local sx = state.offset.x + x_p * state.zoom - state.visible_area.x
                local sy = acc_y + state.offset.y + y_p * state.zoom - state.visible_area.y
                return sx, sy
            end
            acc_y = acc_y + state.visible_area.h + view.page_gap.height
        end
        return nil
    else
        local st = view.state
        if not st or st.page ~= page then return nil end
        local sx = st.offset.x + x_p * st.zoom - view.visible_area.x
        local sy = st.offset.y + y_p * st.zoom - view.visible_area.y
        return sx, sy
    end
end

function Paged:strokeToScreenPts(stroke)
    local pts = stroke.points
    local m = #pts
    if m == 0 then return nil end
    local spts = {}
    for i = 1, m, 2 do
        local sx, sy = self:pageToScreenPoint(stroke.page, pts[i], pts[i + 1])
        if not sx then return nil end
        spts[i], spts[i + 1] = sx, sy
    end
    return spts
end

function Paged:getVisiblePages()
    local view = self.view
    if view.page_scroll then
        local pages = {}
        for _, state in ipairs(view.page_states) do
            pages[#pages + 1] = state.page
        end
        return pages
    else
        if not view.state or not view.state.page then return nil end
        return { view.state.page }
    end
end

function Paged:getZoom(page)
    local view = self.view
    if view.page_scroll then
        for _, state in ipairs(view.page_states) do
            if state.page == page then
                return state.zoom or 1
            end
        end
        return 1
    else
        return view.state and view.state.zoom or 1
    end
end

function Paged:strokeCulled(stroke)
    local pages = self:getVisiblePages()
    if not pages then return true end
    for _, page in ipairs(pages) do
        if page == stroke.page then return false end
    end
    return true
end

function Paged:strokeSameContext(a, b)
    return a.page == b.page
end

function Paged:forEachVisibleStroke(fn)
    local pages = self:getVisiblePages()
    if not pages then return end
    local plugin = self.plugin
    for _, page in ipairs(pages) do
        for _, idx in ipairs(plugin.strokes_by_page[page] or {}) do
            fn(plugin.strokes[idx])
        end
    end
end

function Paged:serializeStroke(stroke)
    local pts = stroke.points
    local coords = {}
    for i = 1, #pts do
        coords[#coords + 1] = tostring(Geometry.pack(pts[i]))
    end
    return "page=" .. tostring(stroke.page) .. ",points={" .. table.concat(coords, ",") .. "}"
end

function Paged:deserializeStroke(data)
    if type(data.page) ~= "number" then return nil end
    local stroke = {
        id = data.id,
        width = data.width,
        color = data.color,
        zoom = data.zoom or 1,
        alpha = data.alpha or 1.0,
        datetime = data.datetime or 0,
        page = data.page,
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
    return stroke
end

function Paged:isPaged()
    return true
end

setmetatable(Paged, { __index = Base })

return Paged
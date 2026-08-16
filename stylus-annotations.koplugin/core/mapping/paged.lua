local Mapping = require("core/mapping/base")

local Paged = {}

function Paged:new(plugin)
    local o = Mapping:new(plugin)
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

function Paged:pageState(page)
    local view = self.view
    if not view.page_scroll then
        local st = view.state
        if st and st.page == page then
            return st, view.visible_area
        end
        return nil
    end
    local acc_y = 0
    for _, state in ipairs(view.page_states) do
        if state.page == page then
            return state, state.visible_area, acc_y
        end
        acc_y = acc_y + state.visible_area.h + view.page_gap.height
    end
    return nil
end

function Paged:pageToScreenPoint(page, x_p, y_p)
    local state, visible_area, acc_y = self:pageState(page)
    if not state then return nil end
    local sx = state.offset.x + x_p * state.zoom - visible_area.x
    local sy = (acc_y or 0) + state.offset.y + y_p * state.zoom - visible_area.y
    return sx, sy
end

function Paged:stateSignature(stroke)
    local view = self.view
    local state, visible_area, acc_y = self:pageState(stroke.page)
    if not state then return nil end
    local signature = table.concat{
        "rot=", tostring(state.rotation),
        "|zoom=", tostring(state.zoom),
        "|off=", tostring(state.offset.x), ",", tostring(state.offset.y),
        "|vis=", tostring(visible_area.x), ",", tostring(visible_area.y),
        ",", tostring(visible_area.w), ",", tostring(visible_area.h),
    }
    if view.page_scroll then
        return signature .. "|acc=" .. tostring(acc_y)
    end
    return signature
end

function Paged:strokeToScreenPts(stroke)
    local pts = stroke.points
    local m = #pts
    if m == 0 then return nil end
    local sig = self:stateSignature(stroke)
    if not sig then return nil end
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
    local state = self:pageState(page)
    return state and state.zoom or 1
end

function Paged:strokeCulled(stroke)
    local pages = self:getVisiblePages()
    if not pages then return true end
    for _, page in ipairs(pages) do
        if page == stroke.page then return false end
    end
    return true
end

function Paged:forEachVisibleStroke(fn)
    local pages = self:getVisiblePages()
    if not pages then return end
    local store = self.plugin.store
    for _, page in ipairs(pages) do
        for _, idx in ipairs(store.strokes_by_page[page] or {}) do
            fn(store.strokes[idx])
        end
    end
end

function Paged:serializeStroke(stroke)
    return "page=" .. tostring(stroke.page) .. "," .. self:packPoints(stroke.points)
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
    stroke.points = self:unpackPoints(data.points)
    if not stroke.points then return nil end
    return stroke
end

setmetatable(Paged, { __index = Mapping })

return Paged
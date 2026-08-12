local Base = require("core/adapters/base")
local Geometry = require("core/geometry")
local Device = require("device")
local logger = require("logger")

local Screen = Device.screen

local Paged = {}

local MAPPING_LOG_STATES_PER_STROKE = 3

function Paged:new(plugin)
    local o = Base:new(plugin)
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

function Paged:pointToScreen(stroke, x_p, y_p)
    return self:pageToScreenPoint(stroke.page, x_p, y_p)
end

function Paged:stateSignature(stroke)
    local view = self.view
    local page = stroke.page
    if view.page_scroll then
        local acc_y = 0
        for _, state in ipairs(view.page_states) do
            if state.page == page then
                return table.concat{
                    "rot=", tostring(state.rotation),
                    "|zoom=", tostring(state.zoom),
                    "|off=", tostring(state.offset.x), ",", tostring(state.offset.y),
                    "|vis=", tostring(state.visible_area.x), ",", tostring(state.visible_area.y),
                    ",", tostring(state.visible_area.w), ",", tostring(state.visible_area.h),
                    "|acc=", tostring(acc_y),
                }
            end
            acc_y = acc_y + state.visible_area.h + view.page_gap.height
        end
        return nil
    else
        local st = view.state
        if not st or st.page ~= page then return nil end
        return table.concat{
            "rot=", tostring(st.rotation),
            "|zoom=", tostring(st.zoom),
            "|off=", tostring(st.offset.x), ",", tostring(st.offset.y),
            "|vis=", tostring(view.visible_area.x), ",", tostring(view.visible_area.y),
            ",", tostring(view.visible_area.w), ",", tostring(view.visible_area.h),
        }
    end
end

function Paged:maybeLogStrayMapping(stroke, spts, seen_key)
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
                "page", stroke.page, "zoom", stroke.zoom,
                "bbox", table.concat{tostring(x0), ",", tostring(y0), ",", tostring(x1), ",", tostring(y1)},
                "screen", w, "x", h,
                "sig", seen_key)
        end
    end
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
    self:maybeLogStrayMapping(stroke, spts, sig)
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

setmetatable(Paged, { __index = Base })

return Paged
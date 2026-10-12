local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geometry = require("core/geometry")
local ReaderHighlight = require("apps/reader/modules/readerhighlight")
local _ = require("gettext")

local Screen = Device.screen

local Draw = {}

function Draw.stampDisc(bb, cx, cy, r, color)
    local r2 = r * r
    local cyi = math.floor(cy)
    for dy = -math.floor(r), math.floor(r) do
        local span = math.floor(math.sqrt(r2 - dy * dy) + 0.5)
        if span > 0 then
            bb:paintRectRGB32(math.floor(cx) - span, cyi + dy, 2 * span + 1, 1, color)
        end
    end
end

function Draw.stampPath(bb, pts, ox, oy, r, color)
    local n = #pts
    if n == 0 then return end
    local px, py = pts[1].x, pts[1].y
    Draw.stampDisc(bb, ox + px, oy + py, r, color)
    for i = 2, n do
        local nx, ny = pts[i].x, pts[i].y
        local dx, dy = nx - px, ny - py
        local dist_sq = dx * dx + dy * dy
        if dist_sq >= 1 then
            local steps = math.ceil(math.sqrt(dist_sq))
            for s = 1, steps do
                Draw.stampDisc(bb, ox + px + dx * (s / steps), oy + py + dy * (s / steps), r, color)
            end
        else
            Draw.stampDisc(bb, ox + nx, oy + ny, r, color)
        end
        px, py = nx, ny
    end
end

function Draw.paintDashedPath(bb, pts, width, color_a, color_b, dash_length, gap_length)
    if #pts < 2 then return end
    dash_length = dash_length or 7
    gap_length = gap_length or 4
    local pattern = dash_length + gap_length
    local distance_along = 0
    for i = 2, #pts do
        local from, to = pts[i - 1], pts[i]
        local dx, dy = to.x - from.x, to.y - from.y
        local length = math.sqrt(dx * dx + dy * dy)
        local segment_offset = 0
        while segment_offset < length do
            local pattern_offset = distance_along % pattern
            local in_dash = pattern_offset < dash_length
            local step = in_dash and (dash_length - pattern_offset) or (pattern - pattern_offset)
            step = math.min(step, length - segment_offset)
            if step < 0.001 then
                step = math.min(0.001, length - segment_offset)
            end
            if in_dash and step > 0 then
                local t0 = segment_offset / length
                local t1 = (segment_offset + step) / length
                Draw.stampPath(bb, {
                    { x = from.x + dx * t0, y = from.y + dy * t0 },
                    { x = from.x + dx * t1, y = from.y + dy * t1 },
                }, 0, 0, width / 2,
                    math.floor(distance_along / pattern) % 2 == 0 and color_a or color_b)
            end
            segment_offset = segment_offset + step
            distance_along = distance_along + step
        end
    end
end

function Draw.paintCircleOutline(bb, cx, cy, radius, color, width)
    local points = {}
    local segments = 40
    for i = 0, segments do
        local angle = 2 * math.pi * i / segments
        points[#points + 1] = {
            x = cx + math.cos(angle) * radius,
            y = cy + math.sin(angle) * radius,
        }
    end
    Draw.stampPath(bb, points, 0, 0, (width or 2) / 2, color)
end

local EXTRA_COLORS = {
    {_("Black"), "black", "#000000"},
    {_("White"), "white", "#FFFFFF"},
}

local EXTRA_COLOR_NAMES = {}
for _, c in ipairs(EXTRA_COLORS) do
    EXTRA_COLOR_NAMES[c[2]] = true
end

local COLOR_PALETTE = {}
for _, c in ipairs(ReaderHighlight.highlight_colors) do
    COLOR_PALETTE[#COLOR_PALETTE + 1] = { c[1], c[2] }
end
for _, c in ipairs(EXTRA_COLORS) do
    COLOR_PALETTE[#COLOR_PALETTE + 1] = { c[1], c[2] }
end

local COLOR_HEX = {}
for name, hex in pairs(Blitbuffer.HIGHLIGHT_COLORS) do
    COLOR_HEX[name] = hex
end
COLOR_HEX.gray = "#808080"
for _, c in ipairs(EXTRA_COLORS) do
    COLOR_HEX[c[2]] = c[3]
end

local COLOR_DISPLAY_NAMES = {}
for _, c in ipairs(COLOR_PALETTE) do
    COLOR_DISPLAY_NAMES[c[2]] = c[1]
end

function Draw.getColorPalette()
    return COLOR_PALETTE
end

function Draw.colorDisplayName(name)
    return COLOR_DISPLAY_NAMES[name] or name
end

function Draw.getPaletteColor(name, highlight)
    if highlight and not EXTRA_COLOR_NAMES[name] then
        return highlight:getHighlightColor(name, nil, Screen.night_mode)
    end
    local hex = COLOR_HEX[name]
    return hex and Blitbuffer.colorFromString(hex) or Blitbuffer.COLOR_BLACK
end

function Draw.getRenderColor(stroke, highlight)
    local color = Draw.getPaletteColor(stroke.color, highlight)
    local rgb = color:getColorRGB32()
    local alpha = math.floor((stroke.alpha or 1.0) * 255)
    return Blitbuffer.ColorRGB32(rgb.r, rgb.g, rgb.b, alpha)
end

function Draw.paintStrokePath(bb, sph, sw, color)
    local n = #sph
    if n == 0 then return end
    local half = math.floor(sw / 2)
    local min_x, min_y, max_x, max_y = Geometry.pointsBounds(sph)
    local box_x = math.max(0, math.floor(min_x - half))
    local box_y = math.max(0, math.floor(min_y - half))
    local box_w = math.ceil(max_x + half) - box_x
    local box_h = math.ceil(max_y + half) - box_y
    if box_w <= 0 or box_h <= 0 then return end
    box_w = math.min(bb:getWidth() - box_x, box_w)
    box_h = math.min(bb:getHeight() - box_y, box_h)
    if box_w <= 0 or box_h <= 0 then return end

    if bb:getInverse() == 1 then
        -- An inverse buffer needs alpha-mask composition: filling the whole
        -- stroke bounds produces visible rectangles in night mode.
        local alpha = Blitbuffer.new(box_w, box_h, Blitbuffer.TYPE_BB8)
        if not alpha then return end
        alpha:paintRect(0, 0, box_w, box_h, Blitbuffer.COLOR_BLACK)
        Draw.stampPath(alpha, sph, -box_x, -box_y, sw / 2, Blitbuffer.COLOR_WHITE)
        bb:colorblitFromRGB32(alpha, box_x, box_y, 0, 0, box_w, box_h, color)
        alpha:free()
        return
    end

    local mask = Blitbuffer.new(box_w, box_h, bb:getType())
    if not mask then return end
    mask:paintRect(0, 0, box_w, box_h, Blitbuffer.COLOR_WHITE)
    Draw.stampPath(mask, sph, -box_x, -box_y, sw / 2, color)
    bb:blitFrom(mask, box_x, box_y, 0, 0, box_w, box_h, bb.setPixelMultiply)
    mask:free()
end

function Draw.paintStrokeSolid(bb, sph, sw, color)
    Draw.stampPath(bb, sph, 0, 0, sw / 2, color)
end

return Draw

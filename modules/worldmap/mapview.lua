-- ---- map view rect from the interface panels (unchanged from v1) ----
-- map LEFT = right edge of the tall left panel, map TOP = bottom edge of the
-- full-width top panel, map RIGHT/BOTTOM = the window corner.

-- loaded by the worldmap internal loader: mreq loads sibling modules
local mreq = ...
local state = mreq("state")
local tile = state.tile
local MAP_MIN_SCR, MAP_BR_FRAC = state.MAP_MIN_SCR, state.MAP_BR_FRAC
local MAP_PANEL_LEFT_FRAC = state.MAP_PANEL_LEFT_FRAC
local MAP_PANEL_MAXW_FRAC = state.MAP_PANEL_MAXW_FRAC
local MAP_PANEL_MINH_FRAC = state.MAP_PANEL_MINH_FRAC
local MAP_TOP_MINW_FRAC   = state.MAP_TOP_MINW_FRAC
local MAP_TOP_MAXY_FRAC   = state.MAP_TOP_MAXY_FRAC
local MAP_TOP_MAXH_FRAC   = state.MAP_TOP_MAXH_FRAC

local function resolveMapView()
    local rawW, rawH, s = tile.rawW, tile.rawH, tile.scale or 1
    if not rawW or rawW == 0 then return nil end
    local big = tile.big
    local panel
    for i = 1, #big do
        local q = big[i]
        if q.x <= rawW * MAP_PANEL_LEFT_FRAC
                and (q.y + q.h) >= rawH * MAP_BR_FRAC
                and q.w <= rawW * MAP_PANEL_MAXW_FRAC
                and q.h >= rawH * MAP_PANEL_MINH_FRAC
                and (not panel or (q.x + q.w) > (panel.x + panel.w)) then
            panel = q
        end
    end
    if not panel then return nil end
    local topBottom
    for i = 1, #big do
        local q = big[i]
        if q.w >= rawW * MAP_TOP_MINW_FRAC
                and q.y <= rawH * MAP_TOP_MAXY_FRAC
                and q.h <= rawH * MAP_TOP_MAXH_FRAC
                and (not topBottom or (q.y + q.h) > topBottom) then
            topBottom = q.y + q.h
        end
    end
    local ty = topBottom or panel.y
    local lx = panel.x + panel.w
    local w, h = (rawW - lx) * s, (rawH - ty) * s
    if w < MAP_MIN_SCR or h < MAP_MIN_SCR then return nil end
    return { x = lx * s, y = ty * s, w = w, h = h }
end

return { resolveMapView = resolveMapView }

-- ---- region painting on the world map ----
-- Paints whole regions (chunks), addressed by their IN-GAME (bolt) region
-- coords; the bolt->picker remap from points.lua translates them to the
-- world-map cell. Consumers register named entries with
-- M.set(name, rx, rz, spec); the driver draws them each frame.
--
-- spec is either:
--   * a colour { r, g, b, a } (0-255 each, a optional, default opaque): the
--     region cell is FILLED with it, drawn UNDER the grid lines/labels so a
--     translucent tint reads like part of the map; or
--   * a draw callback function(x, y, cw, clip): called with the cell's
--     top-left in window px, the cell size (px per chunk, scale whatever
--     you draw by this so it follows the zoom) and the map-view clip rect
--     {x,y,w,h}. Drawn OVER the grid lines. The callback runs only while the
--     map is open, anchored, and the cell intersects the clip rect; keep your
--     drawing inside `clip` or it will paint over the framing interface.
--     M.strokeRect is a ready-made clipped border painter for callbacks.
--
-- For a LARGE set of regions (e.g. a whole grey-out list), registering each as
-- its own entry is wasteful: drawUnder/drawOver would touch every entry every
-- frame though only a handful are on screen. Instead register a VISITOR with
-- M.onVisible(name, fn): the driver enumerates only the cells actually visible
-- on the map (a bounded few hundred) and calls fn(rx, rz, x, y, cw, clip) for
-- each, with (rx, rz) the IN-GAME (bolt) region coords. Keep your set in your
-- own table and paint/skip each visited cell as you see fit; work is bounded
-- by the viewport, not by your list size. Visitors paint on the LOWEST layer:
-- under the grid AND under the explicit colour fills above, so a fill for a
-- specific region always takes priority over the mass paint. M.fillRect /
-- M.strokeRect are clipped painters for visitor callbacks; M.forEachVisible(fn)
-- is the same enumeration exposed directly.

-- loaded by the worldmap internal loader: mreq loads sibling modules
local mreq = ...
local bolt = mreq("bolt")
local state = mreq("state")
local points = mreq("points")

local S, anc, log = state.S, state.anc, state.log
local GRID_COLS, GRID_ROWS = state.GRID_COLS, state.GRID_ROWS
local REGION_X0, REGION_Z0 = state.REGION_X0, state.REGION_Z0

local M = {}

-- named entries; re-set a name to move/recolour it
M.regions = {}

function M.set(name, rx, rz, spec)
    local e = { rx = rx, rz = rz }
    if type(spec) == "function" then
        e.draw = spec
    else
        local r, g, b = spec[1], spec[2], spec[3]
        local a = spec[4] or 255
        local key = r .. "," .. g .. "," .. b .. "," .. a
        local prev = M.regions[name]
        if prev and prev.key == key then
            e.surf, e.key = prev.surf, key   -- same colour: reuse the surface
        else
            local ok, s = pcall(bolt.createsurfacefromrgba, 1, 1, string.char(r, g, b, a))
            if ok then
                e.surf, e.key = s, key
            else
                log("region '" .. tostring(name) .. "' fill surface FAILED: " .. tostring(s))
            end
        end
    end
    M.regions[name] = e
end

function M.remove(name) M.regions[name] = nil end

-- the window-px rect of an in-game region on the map: top-left x, y and the
-- cell size. nil while the anchor is not established or off the map grid.
function M.regionRect(rx, rz)
    local mp = anc.draw
    if not mp then return nil end
    local prx, prz = points.boltToPicker(rx, rz)
    local col = prx - REGION_X0
    local row = REGION_Z0 - prz
    if col < 0 or col >= GRID_COLS or row < 0 or row >= GRID_ROWS then return nil end
    return mp.x0 + col * mp.cw, mp.y0 + row * mp.cw, mp.cw
end

-- fill rect (x, y, w, h) with a 1x1 surface, clamped to the clip rect (helper
-- for fills / visitor callbacks that must not spill over the framing interface)
function M.fillRect(surf, x, y, w, h, clip)
    local x0 = math.max(x, clip.x)
    local y0 = math.max(y, clip.y)
    local x1 = math.min(x + w, clip.x + clip.w)
    local y1 = math.min(y + h, clip.y + clip.h)
    if x1 > x0 and y1 > y0 then
        surf:drawtoscreen(0, 0, 1, 1, x0, y0, x1 - x0, y1 - y0)
    end
end

-- draw a t-px border of rect (x, y, w, h) with a 1x1 surface, each edge
-- clamped to the clip rect (helper for custom draw callbacks)
function M.strokeRect(surf, x, y, w, h, t, clip)
    local cx0, cy0 = clip.x, clip.y
    local cx1, cy1 = clip.x + clip.w, clip.y + clip.h
    local function bar(bx, by, bw, bh)
        local x0, y0 = math.max(bx, cx0), math.max(by, cy0)
        local x1, y1 = math.min(bx + bw, cx1), math.min(by + bh, cy1)
        if x1 > x0 and y1 > y0 then
            surf:drawtoscreen(0, 0, 1, 1, x0, y0, x1 - x0, y1 - y0)
        end
    end
    bar(x, y, w, t)                       -- top
    bar(x, y + h - t, w, t)               -- bottom
    bar(x, y + t, t, h - 2 * t)           -- left
    bar(x + w - t, y + t, t, h - 2 * t)   -- right
end

local function clipBounds()
    local mp = anc.draw
    if not mp then return nil end
    local clip = S.mapView or anc.bbox
    if not clip then return nil end
    return clip, clip.x, clip.y, clip.x + clip.w, clip.y + clip.h
end

-- Enumerate the region cells currently visible on the map, calling
-- fn(rx, rz, x, y, cw, clip) for each: (rx, rz) are IN-GAME (bolt) region
-- coords, (x, y) the cell's top-left window px, cw the cell size. The clamped
-- range mirrors the grid overlay exactly, so "visible" means "actually drawn".
-- Does nothing (returns 0) unless the map is open, anchored and has a view.
-- Returns the number of cells visited.
function M.forEachVisible(fn)
    if S.ttl <= 0 then return 0 end            -- map not open this frame
    local clip, cx0, cy0, cx1, cy1 = clipBounds()
    if not clip then return 0 end
    local mp = anc.draw
    local x0, y0, cw = mp.x0, mp.y0, mp.cw
    if cw < 1 then return 0 end
    -- clamp to the world edges: nothing outside chunk (0,0)..(cols-1,rows-1)
    if x0 > cx0 then cx0 = x0 end
    if y0 > cy0 then cy0 = y0 end
    if x0 + GRID_COLS * cw < cx1 then cx1 = x0 + GRID_COLS * cw end
    if y0 + GRID_ROWS * cw < cy1 then cy1 = y0 + GRID_ROWS * cw end
    if cx1 - cx0 < 1 or cy1 - cy0 < 1 then return 0 end
    local c0 = math.max(0, math.floor((cx0 - x0) / cw))
    local c1 = math.min(GRID_COLS - 1, math.floor((cx1 - x0) / cw))
    local r0 = math.max(0, math.floor((cy0 - y0) / cw))
    local r1 = math.min(GRID_ROWS - 1, math.floor((cy1 - y0) / cw))
    local n = 0
    for col = c0, c1 do
        local px = x0 + col * cw
        for row = r0, r1 do
            local rx, rz = points.pickerToBolt(REGION_X0 + col, REGION_Z0 - row)
            fn(rx, rz, px, y0 + row * cw, cw, clip)
            n = n + 1
        end
    end
    return n
end

-- visitors: per-visible-cell callbacks the driver runs each frame (under the
-- grid). One enumeration feeds every registered visitor.
M.visitors = {}
function M.onVisible(name, fn) M.visitors[name] = fn end
function M.removeVisitor(name) M.visitors[name] = nil end

local visErrN = 0
function M.drawVisitors(open)
    if not open or next(M.visitors) == nil then return end
    M.forEachVisible(function(rx, rz, x, y, cw, clip)
        for name, fn in pairs(M.visitors) do
            local ok, err = pcall(fn, rx, rz, x, y, cw, clip)
            if not ok and visErrN < 10 then
                visErrN = visErrN + 1
                log("region visitor '" .. tostring(name) .. "' ERROR: " .. tostring(err))
            end
        end
    end)
end

-- colour fills, drawn under the grid lines but OVER the visitor layer, so an
-- explicit region fill takes priority over the mass grey-out
function M.drawUnder(open)
    if not open then return end
    local clip = clipBounds()
    if not clip then return end
    for _, e in pairs(M.regions) do
        if e.surf then
            local x, y, cw = M.regionRect(e.rx, e.rz)
            if x then M.fillRect(e.surf, x, y, cw, cw, clip) end
        end
    end
end

-- custom draw callbacks, drawn over the grid lines
local cbErrN = 0
function M.drawOver(open)
    if not open then return end
    local clip, cx0, cy0, cx1, cy1 = clipBounds()
    if not clip then return end
    for name, e in pairs(M.regions) do
        if e.draw then
            local x, y, cw = M.regionRect(e.rx, e.rz)
            if x and x < cx1 and x + cw > cx0 and y < cy1 and y + cw > cy0 then
                local ok, err = pcall(e.draw, x, y, cw, clip)
                if not ok and cbErrN < 10 then
                    cbErrN = cbErrN + 1
                    log("region '" .. tostring(name) .. "' draw callback ERROR: "
                        .. tostring(err))
                end
            end
        end
    end
end

return M

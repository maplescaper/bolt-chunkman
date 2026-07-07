-- ---- world-coordinate markers on the world map ----
-- Turns in-game world positions (bolt world units, e.g. from
-- onminimapterrain) into world-map window pixels and draws a marker there.
-- Consumers register named points with M.set(name, wx, wz[, draw]); the
-- driver calls M.draw() each frame after the grid overlay.
--
-- By default a point is drawn as a black dot. Pass a draw callback to render
-- anything else: it is called as draw(sx, sy, cw, clip) with the point's
-- window px position, the current px-per-chunk pitch (scale whatever you draw
-- by this so it follows the zoom) and the map-view clip rect {x,y,w,h}
-- (keep your drawing inside it or it will paint over the framing interface).
-- The callback runs only while the map is open, anchored, and the point's
-- position is inside the clip rect.
--
-- The in-game (bolt) region IDs and the world-map / Chunk Picker region IDs
-- disagree for a few areas (Arc Islands, Anachronia, Havenhythe, Lost Grove).
-- REGION_REMAP (vendored from the Chunk Man plugin, which maps the other
-- direction) lists each such box in PICKER IDs plus the offset that turns a
-- picker ID into a bolt ID; boltToPicker inverts it by subtracting the offset
-- and accepting the candidate that lands inside its picker box.

local mreq = ...
local bolt = mreq("bolt")
local state = mreq("state")

local S, anc, log = state.S, state.anc, state.log
local GRID_COLS, GRID_ROWS = state.GRID_COLS, state.GRID_ROWS
local REGION_X0, REGION_Z0 = state.REGION_X0, state.REGION_Z0

local UNITS_PER_TILE   = 512   -- world units per tile
local TILES_PER_REGION = 64    -- tiles per region (chunk) side

local M = {}

-- { pickerSW, pickerNE, pickerToBoltOffset }; chunk ID = regionX*256 + regionZ
local REGION_REMAP = {
    { 14870, 18212, -7785 },   -- Arc Islands
    { 14655, 16967,  5857 },   -- Anachronia
    { 16176, 17720, -2844 },   -- Havenhythe
    {  7471,  7986, -2265 },   -- Lost Grove
}

-- is region (rx, rz) inside the box whose opposite corners are chunk IDs lo/hi?
local function regionInBox(rx, rz, lo, hi)
    local rxA, rzA = math.floor(lo / 256), lo % 256
    local rxB, rzB = math.floor(hi / 256), hi % 256
    if rxA > rxB then rxA, rxB = rxB, rxA end
    if rzA > rzB then rzA, rzB = rzB, rzA end
    return rx >= rxA and rx <= rxB and rz >= rzA and rz <= rzB
end

-- in-game (bolt) region -> world-map (picker) region
function M.boltToPicker(rx, rz)
    local id = rx * 256 + rz
    for _, r in ipairs(REGION_REMAP) do
        local p = id - r[3]
        if p >= 0 and regionInBox(math.floor(p / 256), p % 256, r[1], r[2]) then
            return math.floor(p / 256), p % 256
        end
    end
    return rx, rz
end

-- world-map (picker) region -> in-game (bolt) region (the inverse of the
-- above): if the picker region sits in a remap box, add that box's offset
function M.pickerToBolt(prx, prz)
    for _, r in ipairs(REGION_REMAP) do
        if regionInBox(prx, prz, r[1], r[2]) then
            local id = prx * 256 + prz + r[3]
            return math.floor(id / 256), id % 256
        end
    end
    return prx, prz
end

-- world units -> window px on the world map. nil while the anchor is not
-- established or when the point falls off the 43x50 map grid.
function M.worldToMap(wx, wz)
    local mp = anc.draw
    if not mp then return nil end
    local tx = wx / UNITS_PER_TILE
    local tz = wz / UNITS_PER_TILE
    local rx = math.floor(tx / TILES_PER_REGION)
    local rz = math.floor(tz / TILES_PER_REGION)
    local fx = tx / TILES_PER_REGION - rx
    local fz = tz / TILES_PER_REGION - rz
    local prx, prz = M.boltToPicker(rx, rz)
    local col = prx - REGION_X0
    local row = REGION_Z0 - prz
    if col < 0 or col >= GRID_COLS or row < 0 or row >= GRID_ROWS then return nil end
    -- north (higher z) is the top of the cell, so the intra-region z fraction flips
    return mp.x0 + (col + fx) * mp.cw,
           mp.y0 + (row + 1 - fz) * mp.cw
end

-- window px on the world map -> world units (the exact inverse of worldToMap,
-- for click handling). nil while the anchor is not established or when the
-- pixel falls off the 43x50 map grid. The returned position is fractional
-- (sub-tile); floor(wx / 512) for the tile, floor(wx / (512 * 64)) for the
-- IN-GAME (bolt) region, as the remap boxes are already applied.
function M.mapToWorld(sx, sy)
    local mp = anc.draw
    if not mp then return nil end
    local gx = (sx - mp.x0) / mp.cw    -- map-grid coords in cells
    local gy = (sy - mp.y0) / mp.cw
    local col, row = math.floor(gx), math.floor(gy)
    if col < 0 or col >= GRID_COLS or row < 0 or row >= GRID_ROWS then return nil end
    local fx = gx - col                -- intra-region fractions; z flips back
    local fz = 1 - (gy - row)
    local brx, brz = M.pickerToBolt(REGION_X0 + col, REGION_Z0 - row)
    return (brx + fx) * TILES_PER_REGION * UNITS_PER_TILE,
           (brz + fz) * TILES_PER_REGION * UNITS_PER_TILE
end

-- named markers; re-set a name to move it (draw: optional callback, see top)
M.points = {}
function M.set(name, wx, wz, draw) M.points[name] = { x = wx, z = wz, draw = draw } end
function M.remove(name) M.points[name] = nil end

-- dot sprites: a filled disc with a thin white rim so it reads on dark map
-- areas. makeDot builds one in any colour for custom draw callbacks; drawDot
-- paints it centred at a screen position at the standard zoom-scaled size.
local DOT_D = 24

function M.makeDot(red, green, blue)
    local FILL = string.char(red, green, blue, 255)
    local RIM  = string.char(255, 255, 255, 220)
    local NONE = string.char(0, 0, 0, 0)
    local px = {}
    local c = (DOT_D - 1) / 2
    for y = 0, DOT_D - 1 do
        for x = 0, DOT_D - 1 do
            local d = math.sqrt((x - c) ^ 2 + (y - c) ^ 2)
            px[#px + 1] = (d <= 8.5) and FILL or (d <= 11 and RIM or NONE)
        end
    end
    local ok, s = pcall(bolt.createsurfacefromrgba, DOT_D, DOT_D, table.concat(px))
    if ok then return s end
    log("point dot surface FAILED: " .. tostring(s))
    return nil
end

-- standard dot diameter at the current px-per-chunk pitch
local function dotSize(cw)
    local dd = cw * 0.15
    if dd < 8 then dd = 8 elseif dd > 22 then dd = 22 end
    return dd
end

function M.drawDot(surf, sx, sy, cw)
    if not surf then return end
    local dd = dotSize(cw)
    surf:drawtoscreen(0, 0, DOT_D, DOT_D, sx - dd / 2, sy - dd / 2, dd, dd)
end

local dotSurf = M.makeDot(0, 0, 0)   -- the default black marker

local cbErrN = 0

function M.draw(open)
    if not open then return end
    local mp = anc.draw
    if not mp then return end
    local clip = S.mapView or anc.bbox
    if not clip then return end
    local cx0, cy0 = clip.x, clip.y
    local cx1, cy1 = clip.x + clip.w, clip.y + clip.h
    local dd = dotSize(mp.cw)                 -- dot diameter follows the zoom
    local r = dd / 2
    for name, p in pairs(M.points) do
        local sx, sy = M.worldToMap(p.x, p.z)
        if sx then
            if p.draw then
                -- custom marker: gate on the position being in view, then let
                -- the callback do its own extent clipping against `clip`
                if sx >= cx0 and sx <= cx1 and sy >= cy0 and sy <= cy1 then
                    local ok, err = pcall(p.draw, sx, sy, mp.cw, clip)
                    if not ok and cbErrN < 10 then
                        cbErrN = cbErrN + 1
                        log("point '" .. tostring(name) .. "' draw callback ERROR: "
                            .. tostring(err))
                    end
                end
            elseif dotSurf and sx - r >= cx0 and sx + r <= cx1
                    and sy - r >= cy0 and sy + r <= cy1 then
                dotSurf:drawtoscreen(0, 0, DOT_D, DOT_D, sx - r, sy - r, dd, dd)
            end
        end
    end
end

return M

-- ---- per-group lattice geometry ----
-- Tiles at the view edges are CLIPPED, and at 100/200% zoom only a handful of
-- tiles are visible often with NO tile full-size in both dimensions (e.g.
-- 3x2 x 921px tiles at 200%: only the middle column is horizontally full and
-- every row is vertically clipped). So nothing may require full tiles.
-- Instead each group gets a lattice fit:
--   * pitch m = the largest width/height supported by >=2 tiles, over widths
--     AND heights jointly (interior tiles are unclipped in at least one
--     dimension, and tiles are square);
--   * phase = cluster vote over every tile's left/right (top/bottom) edge
--     mod m: shared edges between adjacent tiles are always true lattice
--     lines, so the correct cluster dominates even when the outer edges are
--     all clipped;
--   * a tile's UNCLIPPED top-left = flooring its centre into that lattice
--     (the drawn rect always lies inside the true tile cell, so the centre
--     cannot leave it, no matter how the tile is clipped).

-- loaded by the worldmap internal loader: mreq loads sibling modules
local mreq = ...
local state = mreq("state")
local tile = state.tile

local M = {}

local function latticePhase(g, m, csel, ssel)
    local ed, n = {}, #g
    local step = n > 24 and math.ceil(n / 24) or 1
    for i = 1, n, step do
        local t = g[i]
        local a = t[csel] - t[ssel] / 2
        ed[#ed + 1] = a % m
        ed[#ed + 1] = (a + t[ssel]) % m
    end
    local tol = math.max(2, m * 0.015)
    local bestC, bestV = -1, 0
    for i = 1, #ed do
        local c, sum = 0, 0
        for j = 1, #ed do
            local d = (ed[j] - ed[i] + m / 2) % m - m / 2
            if d >= -tol and d <= tol then c = c + 1; sum = sum + d end
        end
        if c > bestC then bestC, bestV = c, (ed[i] + sum / c) % m end
    end
    return bestV
end

function M.groupGeom(aw, g)
    local v = {}
    for i = 1, #g do v[#v + 1] = g[i].w; v[#v + 1] = g[i].h end
    table.sort(v, function(a, b) return a > b end)
    local m
    for i = 1, #v - 1 do
        if v[i] - v[i + 1] <= v[i] * 0.02 then m = v[i]; break end
    end
    if not m or m < 8 then return nil end
    return { aw = aw, tiles = g, n = #g, m = m,
             px = latticePhase(g, m, "cx", "w"),
             py = latticePhase(g, m, "cy", "h") }
end

-- unclipped top-left corner (raw px) of a tile within its group's lattice
function M.tileTL(gj, t)
    local gx = math.floor((t.cx - gj.px) / gj.m)
    local gy = math.floor((t.cy - gj.py) / gj.m)
    return gj.px + gx * gj.m, gj.py + gy * gj.m
end

-- one group's texel samples, rebased onto unclipped tile rects so the
-- matcher's template geometry is exact even for clipped tiles. The samples
-- are atlas-relative, so they cover the FULL tile content no matter how
-- little of it is drawn.
function M.groupSamples(gj)
    local bkt = tile.samples[gj.aw]
    if not bkt then return nil end
    local sm = {}
    for i = 1, #bkt do
        local q = bkt[i]
        local gx = math.floor((q.left + q.w / 2 - gj.px) / gj.m)
        local gy = math.floor((q.top + q.h / 2 - gj.py) / gj.m)
        sm[#sm + 1] = { left = gj.px + gx * gj.m, top = gj.py + gy * gj.m,
            w = gj.m, h = gj.m, u = q.u, v = q.v, lum = q.lum }
    end
    return sm
end

return M

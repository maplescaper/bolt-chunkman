-- chunkfind: identify WHICH world-map chunks the drawn map tiles show, by
-- matching sampled tile luminance against downsampled references of
-- resources/runescape_world_map.png (mapref2 = 2 cells/chunk 86x100,
-- mapref4 = 4 cells/chunk 172x200).
--
-- All of one frame's samples form a single rigid template: their relative
-- chunk coordinates are known exactly from the tile lattice (tiles are
-- axis-aligned, uniformly sized, and each spans 2^e2 chunks). The only
-- unknowns are WHERE that template sits on the reference map (an integer
-- cell offset) and, on cold starts, the LOD scale e2. Both are searched
-- exhaustively: the reference is only 86x100 cells, so a global search is
-- cheap, and it removes any dependence on a predicted position. Scoring is
-- normalised cross-correlation, so brightness/contrast differences between
-- the live map and the reference don't matter.
--
-- Orientation note: every healthy match in the legacy plugin's logged
-- sessions was flip=false at every LOD (the only flip=true winners were
-- degenerate-strip artifacts), so the vertical flip is not searched.

local mreq = ...   -- worldmap internal loader (loads the mapref data modules)

local M = { ref2 = nil, ref4 = nil }

local floor, sqrt, abs = math.floor, math.sqrt, math.abs
local LOG2 = math.log(2)

local function loadRef(name)
    local ref = { ok = false }
    local okr, r = pcall(mreq, name)
    if okr and type(r) == "table" and r.hex and #r.hex >= 2 * r.w * r.h then
        local t = {}
        for k = 1, r.w * r.h do t[k] = tonumber(r.hex:sub(2 * k - 1, 2 * k), 16) end
        ref.w, ref.h, ref.map, ref.ok = r.w, r.h, t, true
    end
    return ref
end

function M.load()
    M.ref2 = loadRef("mapref2")
    M.ref4 = loadRef("mapref4")
    return M.ref2.ok
end

-- Match one frame's tile samples against the reference map.
--   samples: array of { left, top, w, h (tile rect, raw render-target px),
--                       u, v (0..1 position within the tile), lum }
--   m:       dominant full tile size (raw px), only samples from tiles of
--            this size (+-2%) are used; clipped edge tiles are skipped.
--   opts.scale:  window px per raw px (HiDPI)
--   opts.winW:   game window width (window px), picks ref2 vs ref4
--   opts.e2:     known LOD exponent (tile spans 2^e2 chunks); nil = search
--
-- The offset search is always GLOBAL (the whole reference), so a stale
-- anchor can never hide a content jump from the caller's verification.
--
-- Returns a result table or nil + reason string. Result fields:
--   cx, cy   chunk coords (map top-left = 0,0) of the origin tile's TL corner
--   ol, ot   the origin tile's TL corner (raw px), pairs with cx/cy
--   e2, cells, ncc, margin, n, spanX, spanY (chunks), weak (small span)
function M.match(samples, m, opts)
    if not (M.ref2 and M.ref2.ok) then return nil, "noref" end
    if not samples or #samples < 24 then return nil, "few" end
    local scale = opts.scale or 1
    -- opts.e2: nil = search all scales; a number = that scale only; a table =
    -- an explicit shortlist. The caller narrows to a +-1 window around the
    -- pitch-implied LOD during a zoom re-acquire, so the full 7-scale sweep is
    -- only paid on cold starts / the periodic safety sweep.
    local e2list
    if type(opts.e2) == "table" then
        e2list = opts.e2
    elseif opts.e2 then
        e2list = { opts.e2 }
    else
        e2list = { 0, -1, 1, -2, 2, 3, -3 }
    end
    local best, second = nil, -2
    local reason = "nofit"
    for ei = 1, #e2list do
        local e2 = e2list[ei]
        local cw = m * scale / 2 ^ e2          -- window px per chunk
        -- a chunk under 8 window px cannot carry enough texture to match
        if cw >= 8 then
            local rf, cells = M.ref2, 2
            if M.ref4 and M.ref4.ok and (opts.winW or 0) > 0 and cw * 6 > opts.winW then
                rf, cells = M.ref4, 4
            end
            local ct = 2 ^ e2 * cells          -- reference cells per tile
            -- integer-cell point list, origin = first full-size tile's TL
            local ix, iy, ls = {}, {}, {}
            local n, ol, ot = 0, nil, nil
            local sa, saa = 0, 0
            for i = 1, #samples do
                local q = samples[i]
                if abs(q.w - m) <= m * 0.02 and abs(q.h - m) <= m * 0.02 then
                    if not ol then ol, ot = q.left, q.top end
                    local gx = floor((q.left - ol) / m + 0.5)
                    local gy = floor((q.top - ot) / m + 0.5)
                    n = n + 1
                    ix[n] = floor((gx + q.u) * ct)
                    iy[n] = floor((gy + q.v) * ct)
                    ls[n] = q.lum
                    sa = sa + q.lum; saa = saa + q.lum * q.lum
                end
            end
            if n < 24 then
                reason = "few-full"
            elseif (saa / n - (sa / n) ^ 2) < 36 then
                -- variance guard: featureless ocean cannot be matched
                reason = "flat"
            else
                local x0, x1, y0, y1 = ix[1], ix[1], iy[1], iy[1]
                for i = 2, n do
                    local v = ix[i]
                    if v < x0 then x0 = v elseif v > x1 then x1 = v end
                    v = iy[i]
                    if v < y0 then y0 = v elseif v > y1 then y1 = v end
                end
                -- span counted INCLUSIVELY in cells: at 200% zoom the samples
                -- cover exactly 12x8 fine cells (3x2 tiles) and must pass
                local spanX, spanY = (x1 - x0 + 1) / cells, (y1 - y0 + 1) / cells
                -- narrow-strip evidence poisoned the legacy tracker (a 5x23-
                -- cell strip matched 0.95 at a wrong offset); mark it weak so
                -- the caller can refuse to (re)anchor on it. Thresholds match
                -- the legacy matcher: 4x3 chunks coarse, 3x2 chunks fine.
                local weak = (x1 - x0 + 1) < (cells == 4 and 12 or 8)
                    or (y1 - y0 + 1) < (cells == 4 and 8 or 6)
                -- NOTE: weak hypotheses are still scanned. A weak-but-true
                -- peak can never be accepted, but it OCCUPIES `best` and
                -- margin-blocks wrong-scale impostors. Pruning it here let
                -- a fine-pitch spurious fit win at 200% on small windows.
                local alo, ahi = -x1, rf.w - 1 - x0
                local blo, bhi = -y1, rf.h - 1 - y0
                local map, W, H = rf.map, rf.w, rf.h
                local function score(ox, oy, st)
                    local n2, a, b, ab, aa, bb = 0, 0, 0, 0, 0, 0
                    for i = 1, n, st do
                        local gx, gy = ix[i] + ox, iy[i] + oy
                        if gx >= 0 and gx < W and gy >= 0 and gy < H then
                            local rv = map[gy * W + gx + 1]
                            local l = ls[i]
                            n2 = n2 + 1
                            a = a + l; b = b + rv; ab = ab + l * rv
                            aa = aa + l * l; bb = bb + rv * rv
                        end
                    end
                    -- most of the template must land on the reference, or an
                    -- edge sliver can fake a high score
                    if n2 < 12 or n2 * st < n * 0.5 then return nil end
                    local cov = ab - a * b / n2
                    local den = (aa - a * a / n2) * (bb - b * b / n2)
                    if den <= 1e-9 then return nil end
                    return cov / sqrt(den)
                end
                -- coarse scan: EVERY offset, with a subsampled point set. The
                -- offsets must not be strided. At the fine reference the
                -- true peak is only 1-2 cells wide, and a stride-2 grid can
                -- miss it entirely when its shoulders don't reach the global
                -- top-10 (seen at 200%: the peak at an even offset was never
                -- scored and a spurious e2=1 fit won instead).
                local pstep = floor(n / 20)
                if pstep < 1 then pstep = 1 end
                -- top-10 kept by replacing the current minimum (NO table.sort
                -- in this loop: it broke the JIT trace of the whole scan and
                -- cost ~4x on the full sweep)
                local top, topN = {}, 0
                local topMin, topMinI = math.huge, 0
                for oy = blo, bhi do
                    for ox = alo, ahi do
                        local v = score(ox, oy, pstep)
                        if v then
                            if topN < 10 then
                                topN = topN + 1
                                top[topN] = { v, ox, oy }
                                if v < topMin then topMin, topMinI = v, topN end
                            elseif v > topMin then
                                top[topMinI] = { v, ox, oy }
                                topMin = math.huge
                                for k = 1, 10 do
                                    if top[k][1] < topMin then topMin, topMinI = top[k][1], k end
                                end
                            end
                        end
                    end
                end
                -- refine each peak with ALL points over +-2 cells; track the
                -- global best and the runner-up. The runner-up must be a
                -- genuinely DIFFERENT place, over ~0.75 chunks away, or
                -- another e2 because adjacent-offset autocorrelation is
                -- high on this map (box-downsampled reference): with a small
                -- visible window (200% zoom) the true peak's shoulder 2 cells
                -- away scores within a few percent and would zero the margin.
                local sep = cells == 4 and 3 or 2
                local seen = {}
                for t = 1, topN do
                    local cox, coy = top[t][2], top[t][3]
                    for oy = coy - 2, coy + 2 do
                        for ox = cox - 2, cox + 2 do
                            local sk = ox .. "," .. oy
                            if not seen[sk] then
                                seen[sk] = true
                                local v = score(ox, oy, 1)
                                if v then
                                    local far = not best or best.e2 ~= e2
                                        or best.cells ~= cells
                                        or abs(best.ox - ox) > sep or abs(best.oy - oy) > sep
                                    if not best or v > best.ncc then
                                        if best and far and best.ncc > second then
                                            second = best.ncc
                                        end
                                        best = { ncc = v, ox = ox, oy = oy, e2 = e2,
                                            cells = cells, n = n, spanX = spanX,
                                            spanY = spanY, weak = weak, ol = ol, ot = ot,
                                            cx = ox / cells, cy = oy / cells }
                                    elseif far and v > second then
                                        second = v
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if not best then return nil, reason end
    best.margin = best.ncc - second
    return best
end

return M

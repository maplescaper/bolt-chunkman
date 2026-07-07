-- ---- diagnostics writers ----
-- No console under the launcher, so diagnostics go through bolt.saveconfig:
-- config/plugins/<registry-id>/debug.log (+ tiles.txt on sample frames while
-- unanchored). Both are SYNCHRONOUS disk writes. The caller gates cadence,
-- and the state.DEBUG config flag (init{ debug = true }) gates them entirely.

local mreq = ...
local bolt = mreq("bolt")
local state = mreq("state")
local find = mreq("chunkfind")

local S, tile, anc, perf = state.S, state.tile, state.anc, state.perf
local logBuf = state.logBuf
local DEBUG = state.DEBUG
local LOG_NAME = "debug.log"

local M = {}

function M.flush()
    if not DEBUG then return end
    local p = {}
    local function add(t) p[#p + 1] = t end
    add("=== world-map chunk overlay (v2 content-first) ===")
    add("frame=" .. S.frame .. "  swaps=" .. S.swaps .. "  batches=" .. S.batches)
    add("map_open=" .. tostring(S.ttl > 0) .. "  title='" .. S.lastLine .. "'")
    add("images_last_frame=" .. S.shownImages .. "  glyphs_last_frame=" .. S.shownGlyphs)
    add("window=" .. tile.winW .. "x" .. tile.winH .. "  raw=" .. tile.rawW .. "x" .. tile.rawH
        .. "  scale=" .. string.format("%.3f", tile.scale or 1))
    add("refs: ref2=" .. tostring(find.ref2 and find.ref2.ok)
        .. " ref4=" .. tostring(find.ref4 and find.ref4.ok)
        .. "  errors=" .. S.err)
    add("")
    add("--- anchor ---")
    add(string.format("anchored=%s  elect_atlas=%s  slots=%d  votes=%d(kept %d)  badN=%d  pending=%s",
        tostring(anc.ok), tostring(anc.elect), anc.slotN, anc.votesN, anc.keptN, anc.badN,
        anc.pend and string.format("cw=%.1f@f%d", anc.pend.cw, anc.pend.f) or "no"))
    add(string.format("zoom_readout=%s%%  cw_per_pct=%s  (expected cw=%s)",
        tostring(S.zoom), anc.cwpp and string.format("%.3f", anc.cwpp) or "-",
        (S.zoom and anc.cwpp) and string.format("%.0f", S.zoom * anc.cwpp) or "-"))
    if anc.draw then
        add(string.format("mapping: x0=%.1f y0=%.1f cw=%.2fpx/chunk e2=%s (frame %d)",
            anc.draw.x0, anc.draw.y0, anc.draw.cw, tostring(anc.e2), anc.frame))
    else
        add("mapping: (none this frame)")
    end
    add("groups (last frame, election order):")
    local gd = anc.gdump or {}
    if #gd == 0 then add("  (none)") end
    for i = 1, #gd do add("  " .. gd[i]) end
    add("map_view=" .. (S.mapView and string.format("x%d y%d w%d h%d",
        S.mapView.x, S.mapView.y, S.mapView.w, S.mapView.h) or "nil")
        .. "  bbox=" .. (anc.bbox and string.format("x%d y%d w%d h%d",
        anc.bbox.x, anc.bbox.y, anc.bbox.w, anc.bbox.h) or "nil"))
    add("")
    add("--- perf (plugin time per frame) ---")
    add(string.format("avg=%.2fms  max=%.1fms@f%d  mem=%.0fKB  alloc~%.1fKB/frame",
        perf.n > 0 and perf.sum / perf.n / 1000 or 0, perf.max / 1000, perf.maxF,
        perf.memPrev or 0,
        (perf.allocN or 0) > 0 and perf.allocSum / perf.allocN or 0))
    add("slow frames (>=3ms, map open):")
    if #perf.ring == 0 then add("  (none)") end
    for i = 1, #perf.ring do add("  " .. perf.ring[i]) end
    add("")
    add("--- match attempts (ring) ---")
    if #anc.mlog == 0 then add("  (none yet, open the map over land)") end
    for i = 1, #anc.mlog do
        local e = anc.mlog[i]
        add(string.format("  f=%d%s %s", e.f0,
            e.cnt > 1 and string.format("..%d(x%d)", e.f1, e.cnt) or "", e.core))
    end
    add("")
    add("--- title candidates ---")
    if #S.shownCands == 0 then add("(none)") end
    for i = 1, #S.shownCands do add(S.shownCands[i]) end
    add("")
    add("--- readable text (latest sampled frame) ---")
    if #S.shownLines == 0 then add("(none)") end
    for i = 1, #S.shownLines do add(S.shownLines[i]) end
    add("")
    add("--- event log ---")
    for i = 1, #logBuf do add(logBuf[i]) end
    bolt.saveconfig(LOG_NAME, table.concat(p, "\n") .. "\n")
end

-- tiles.txt: what the scan collected this frame (written by the driver on
-- sample frames while UNANCHORED)
function M.writeTiles()
    if not DEBUG then return end
    local d = { "=== tiles diagnostic ===", "frame=" .. S.frame,
        "window_raw=" .. tile.rawW .. "x" .. tile.rawH
            .. "  window_px=" .. tile.winW .. "x" .. tile.winH,
        "merged_tile_candidates=" .. #tile.list,
        "elected_atlas=" .. tostring(anc.elect)
            .. "  anchored=" .. tostring(anc.ok)
            .. "  slots=" .. anc.slotN,
        "samples_this_frame=" .. (function()
            local parts = {}
            for aw, bkt in pairs(tile.samples) do
                parts[#parts + 1] = aw .. ":" .. #bkt
            end
            return #parts > 0 and table.concat(parts, " ") or "0"
        end)(), "" }
    for i = 1, math.min(#tile.dump, 16) do
        local b = tile.dump[i]
        d[#d + 1] = string.format("batch#%d tiles=%d(of %d) atlas=%dx%d",
            b.batch, b.n, b.n0, b.aw, b.ah)
    end
    d[#d + 1] = ""
    d[#d + 1] = "atlas-size histogram:"
    local hkeys = {}
    for k in pairs(tile.hist) do hkeys[#hkeys + 1] = k end
    table.sort(hkeys, function(a, b) return tile.hist[a].n > tile.hist[b].n end)
    for i = 1, math.min(#hkeys, 24) do
        d[#d + 1] = string.format("  %-11s n=%d", hkeys[i], tile.hist[hkeys[i]].n)
    end
    bolt.saveconfig("tiles.txt", table.concat(d, "\n") .. "\n")
end

return M

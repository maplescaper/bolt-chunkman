-- ---- per-frame driver ----
-- Runs once per swapbuffers: open-state upkeep, zoom-readout OCR parse, map
-- view refresh, anchor update, transition events, overlay draw, diagnostics
-- cadence, sampling decision for the next frame, perf accounting, per-frame
-- state reset.

local mreq = ...
local bolt = mreq("bolt")
local state = mreq("state")
local mapview = mreq("mapview")
local anchor = mreq("anchor")
local overlay = mreq("overlay")
local points = mreq("points")
local regions = mreq("regions")
local dbg = mreq("debuglog")

local S, tile, anc, perf, log = state.S, state.tile, state.anc, state.perf, state.log
local resolveMapView = mapview.resolveMapView
local updateAnchor = anchor.updateAnchor
local drawOverlays = overlay.drawOverlays
local OPEN_TTL, SAMPLE_EVERY = state.OPEN_TTL, state.SAMPLE_EVERY
local FLUSH_EVERY, VERIFY_EVERY = state.FLUSH_EVERY, state.VERIFY_EVERY
local MAX_DUMP_LINES = state.MAX_DUMP_LINES

local function sortedKeys(set, cap)
    local arr = {}
    for k in pairs(set) do arr[#arr + 1] = k end
    table.sort(arr)
    if cap then for k = #arr, cap + 1, -1 do arr[k] = nil end end
    return arr
end

-- fire a detection transition ("open"/"close"/"anchor"/"anchor-lost") to
-- every consumer callback registered through the facade's onEvent
local evErrN = 0
local function fire(ev)
    for name, fn in pairs(state.events) do
        local ok, err = pcall(fn, ev)
        if not ok and evErrN < 10 then
            evErrN = evErrN + 1
            log("event '" .. tostring(name) .. "' callback ERROR (" .. ev .. "): "
                .. tostring(err))
        end
    end
end

local function onswap()
    S.swaps = S.swaps + 1
    if S.seen then S.ttl = OPEN_TTL elseif S.ttl > 0 then S.ttl = S.ttl - 1 end
    local open = S.ttl > 0
    if open ~= S.wasOpen then
        log(string.format("[f%d] map %s%s", S.frame, open and "OPEN" or "closed",
            open and (" matched='" .. S.lastLine .. "'") or ""))
        S.wasOpen = open
        fire(open and "open" or "close")
    end
    -- zoom readout OCR: the zoom % renders right after the title, so the
    -- recognised line reads like "RuneScapeSurface200%". Two consecutive
    -- identical parses guard against garbled frames. This is an INDEPENDENT
    -- absolute-scale reference for the content matcher (chunk px is
    -- proportional to the zoom %), used to veto wrong-scale acquisitions.
    if open then
        local z = tonumber(S.lastLine:match("(%d+)%%"))
        if z and z >= 10 and z <= 400 then
            if z == S.zoomCand then
                S.zoomN = S.zoomN + 1
                if S.zoomN >= 2 then S.zoom, S.zoomF = z, S.frame end
            else
                S.zoomCand, S.zoomN = z, 1
            end
        end
    else
        S.zoom, S.zoomCand, S.zoomN = nil, nil, 0
    end
    S.shownImages, S.shownGlyphs = S.images, S.glyphs
    if next(S.lines) ~= nil then S.shownLines = sortedKeys(S.lines, MAX_DUMP_LINES) end
    if next(S.cands) ~= nil then S.shownCands = sortedKeys(S.cands, MAX_DUMP_LINES) end

    -- map view rect: re-resolve on sample frames while open (the panels only
    -- reflow on open/resize; keeping the last good rect covers the gaps)
    if open then
        if S.frame % SAMPLE_EVERY == 0 or not S.mapView
                or S.mapView.winW ~= tile.winW then
            local mv = resolveMapView()
            if mv then mv.winW = tile.winW; S.mapView = mv end
        end
    else
        S.mapView = nil
    end
    local haveMV = S.mapView ~= nil
    if haveMV ~= S.wasMapView then
        log(string.format("[f%d] map view %s%s", S.frame, haveMV and "DETECTED" or "lost",
            haveMV and string.format(" x%d y%d w%d h%d", S.mapView.x, S.mapView.y,
                S.mapView.w, S.mapView.h) or ""))
        S.wasMapView = haveMV
    end

    local tA = bolt.time()
    updateAnchor(open)
    perf.anchor = bolt.time() - tA
    if anc.ok ~= S.wasAnchored then
        S.wasAnchored = anc.ok
        fire(anc.ok and "anchor" or "anchor-lost")
    end
    -- a mapping that stays lost for ~20 frames means the tracked pitch no
    -- longer describes what is being drawn (mid-zoom LOD change, layer swap):
    -- discard it so nothing downstream keeps trusting a stale scale
    if open and not anc.draw then
        anc.lossN = (anc.lossN or 0) + 1
        if anc.lossN == 20 and anc.cw then
            log(string.format("[f%d] stale pitch cw=%.1f cleared after 20 lost frames",
                S.frame, anc.cw))
            anc.cw = nil
        end
    else
        anc.lossN = 0
    end
    local tD = bolt.time()
    regions.drawVisitors(open)   -- mass per-visible-cell painting: lowest layer
    regions.drawUnder(open)      -- explicit region fills paint on top (priority)
    drawOverlays(open)           -- grid lines/labels over both (if enabled)
    regions.drawOver(open)       -- region draw callbacks over the grid
    points.draw(open)            -- point markers above the built-in layers
    overlay.drawViewHooks(open)  -- consumer view draw hooks topmost
    perf.draw = bolt.time() - tD

    -- tiles.txt diagnostic on sample frames (only while UNANCHORED)
    if open and not anc.ok and S.frame % SAMPLE_EVERY == 0 then
        dbg.writeTiles()
    end

    -- debug.log: frequent while things are moving (closed/unanchored), every
    -- ~5s in the anchored steady state. It is a SYNCHRONOUS disk write +
    -- string build, and at a once-a-second cadence it was a visible
    -- periodic hitch while panning
    if S.frame % (anc.ok and 300 or FLUSH_EVERY) == 0 then
        local tF = bolt.time()
        dbg.flush()
        perf.flush = bolt.time() - tF
    end

    -- decide texel sampling for the NEXT frame: aggressive until anchored (or
    -- while a disagreement is pending), then only the periodic verify
    if open then
        if not anc.ok or anc.badN > 0 then
            tile.needSamples = (S.frame % 2 == 0)
        else
            -- a verify is a whole-frame hitch (texel readbacks + a GLOBAL
            -- match), so defer it while the mapping is IN MOTION: during a
            -- pan/zoom the slot cache tracks exactly, and content jumps land
            -- through the unknown-slot path regardless. Rest must be
            -- SUSTAINED (perf ring showed a real pan is drag/micro-pause/
            -- drag, and a one-frame gate let a 10ms verify through at every
            -- micro-pause). A long soft cap (~9s) still forces one during
            -- pathological never-resting panning.
            local due = (S.frame - anc.lastTryF) >= VERIFY_EVERY
            local moving = false
            if anc.draw and anc.lastVX then
                moving = math.abs(anc.draw.x0 - anc.lastVX) > 1
                    or math.abs(anc.draw.y0 - anc.lastVY) > 1
                    or math.abs(anc.draw.cw - anc.lastVW) > 0.01
            end
            if moving then anc.restN = 0 else anc.restN = (anc.restN or 0) + 1 end
            tile.needSamples = due and (anc.restN >= 10
                or (S.frame - anc.lastTryF) >= VERIFY_EVERY * 12)
        end
    else
        tile.needSamples = false
    end
    if anc.draw then
        anc.lastVX, anc.lastVY, anc.lastVW = anc.draw.x0, anc.draw.y0, anc.draw.cw
    end
    -- per-atlas-size sampling strides for the next sampling frame, from this
    -- one's per-group tile counts (a global stride let a numerous non-map
    -- layer starve the few big map tiles at 100/200% zoom)
    for aw, seen in pairs(tile.smSeen) do
        tile.smStride[aw] = math.max(1, math.floor(seen / 24))
    end

    -- perf accounting: plugin microsecond this frame + alloc rate; frames >=3ms go in
    -- a ring so debug.log shows exactly WHICH section a pan hitch lives in
    do
        local total = perf.scan + perf.anchor + perf.draw + perf.flush
        local kb = collectgarbage("count")
        perf.n = perf.n + 1
        perf.sum = perf.sum + total
        if total > perf.max then perf.max, perf.maxF = total, S.frame end
        local d = kb - (perf.memPrev or kb)
        if d > 0 then
            perf.allocSum = (perf.allocSum or 0) + d
            perf.allocN = (perf.allocN or 0) + 1
        end
        perf.memPrev = kb
        if total >= 3000 and open then
            local r = perf.ring
            r[#r + 1] = string.format(
                "f=%d total=%.1fms scan=%.1f anchor=%.1f draw=%.1f flush=%.1f"
                    .. " tiles=%d img=%d smp=%s mem=%.0fKB",
                S.frame, total / 1000, perf.scan / 1000, perf.anchor / 1000,
                perf.draw / 1000, perf.flush / 1000, #tile.list, S.images,
                tostring(next(tile.samples) ~= nil), kb)
            if #r > 16 then table.remove(r, 1) end
        end
        perf.scan, perf.anchor, perf.draw, perf.flush = 0, 0, 0, 0
    end

    -- reset per-frame collections
    S.seen = false
    S.images, S.glyphs = 0, 0
    S.lines, S.cands = {}, {}
    tile.list, tile.big, tile.dump = {}, {}, {}
    tile.hist, tile.histN = {}, 0
    tile.samples, tile.smSeen = {}, {}
    S.frame = S.frame + 1
end

return { onswap = onswap }

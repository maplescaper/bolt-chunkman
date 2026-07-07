-- ---- chunk anchor upkeep ----
-- Maintains the atlas-slot identity cache and this frame's chunk mapping:
-- cached slots vote the mapping in every frame (exact through pan/zoom),
-- the content matcher (chunkfind.lua) acquires it globally when cold and
-- periodically verifies it while anchored.

-- loaded by the worldmap internal loader: mreq loads sibling modules
local mreq = ...
local state = mreq("state")
local find = mreq("chunkfind")
local lattice = mreq("lattice")

local S, tile, anc, log = state.S, state.tile, state.anc, state.log
local groupGeom, tileTL = lattice.groupGeom, lattice.tileTL
local groupSamples = lattice.groupSamples
local MAP_MIN_TILES, MIN_PTS = state.MAP_MIN_TILES, state.MIN_PTS
local ACQ_NCC, ACQ_MARGIN = state.ACQ_NCC, state.ACQ_MARGIN
local CONF_NCC, DIS_NCC, DIS_MARGIN = state.CONF_NCC, state.DIS_NCC, state.DIS_MARGIN
local DIS_BAD, SLOT_CAP = state.DIS_BAD, state.SLOT_CAP

local LOG2 = math.log(2)

local function median(arr)
    local t = {}
    for i = 1, #arr do t[i] = arr[i] end
    table.sort(t)
    return t[math.floor((#t + 1) / 2)]
end

-- ring log of match attempts; identical consecutive results collapse
local function mlogAdd(core)
    local ml = anc.mlog
    local last = ml[#ml]
    if last and last.core == core then
        last.cnt, last.f1 = last.cnt + 1, S.frame
    else
        ml[#ml + 1] = { core = core, f0 = S.frame, f1 = S.frame, cnt = 1 }
        if #ml > 30 then table.remove(ml, 1) end
    end
end

local function updateAnchor(open)
    anc.draw, anc.bbox = nil, nil
    anc.votesN, anc.keptN = 0, 0
    if not open then
        if anc.slotN > 0 then log("[f" .. S.frame .. "] anchor cleared (map closed)") end
        anc.slots, anc.slotN = {}, 0
        anc.cw, anc.ok, anc.badN, anc.e2, anc.elect = nil, false, 0, nil, nil
        anc.pend = nil
        anc.lastElectM, anc.lastVX, anc.restN = nil, nil, 0
        return
    end
    local s = tile.scale or 1
    -- absolute-scale sanity from the OCR'd zoom readout: cw is proportional
    -- to the zoom %, and anc.cwpp (cw per percent, learned from content-
    -- verified anchors) makes that an independent yardstick. A match whose
    -- chunk pitch is way off the readout-implied scale is a wrong-scale fit
    -- no matter how well it correlates.
    local zFresh = S.zoom and (S.frame - S.zoomF) <= 60
    local function scaleOK(c)
        if not (zFresh and anc.cwpp) then return true end
        local r = math.log(c / (anc.cwpp * S.zoom)) / LOG2
        return r > -0.75 and r < 0.75
    end
    -- group this frame's candidates by atlas size; lattice fit per group
    local groups = {}
    for i = 1, #tile.list do
        local t = tile.list[i]
        local g = groups[t.aw]
        if not g then g = {}; groups[t.aw] = g end
        g[#g + 1] = t
    end
    local glist = {}
    for aw, g in pairs(groups) do
        if #g >= MAP_MIN_TILES then
            local gj = groupGeom(aw, g)
            if gj then
                local hits = 0
                for i = 1, #g do
                    if anc.slots[aw .. ":" .. g[i].ax .. "," .. g[i].ay] then hits = hits + 1 end
                end
                gj.hits = hits
                glist[#glist + 1] = gj
            end
        end
    end
    if #glist == 0 then return end
    -- elect the drawing layer: most cached identity first, then most tiles
    -- (the game can draw a coarser streaming underlay alongside the map)
    table.sort(glist, function(a, b)
        if a.hits ~= b.hits then return a.hits > b.hits end
        return a.n > b.n
    end)
    local gi = glist[1]
    anc.elect = gi.aw
    -- motion gate: during a zoom the elected group's drawn pitch changes every
    -- frame, so a global acquisition search would only correlate a mid-
    -- transition frame at full cost. Track the pitch and defer ACQUISITION
    -- (below) until it settles; live-mapping verification is unaffected. This
    -- turns a sustained zoom-out CPU spike into a single post-settle match.
    local pitchMoving = anc.lastElectM ~= nil
        and (gi.m / anc.lastElectM < 0.97 or gi.m / anc.lastElectM > 1.03)
    anc.lastElectM = gi.m
    -- bbox of the elected group (clip fallback when the panels aren't resolved)
    local function setBBox(gj)
        local bx0, by0, bx1, by1 = math.huge, math.huge, -math.huge, -math.huge
        for i = 1, #gj.tiles do
            local t = gj.tiles[i]
            if t.cx - t.w / 2 < bx0 then bx0 = t.cx - t.w / 2 end
            if t.cy - t.h / 2 < by0 then by0 = t.cy - t.h / 2 end
            if t.cx + t.w / 2 > bx1 then bx1 = t.cx + t.w / 2 end
            if t.cy + t.h / 2 > by1 then by1 = t.cy + t.h / 2 end
        end
        anc.bbox = { x = bx0 * s, y = by0 * s, w = (bx1 - bx0) * s, h = (by1 - by0) * s }
    end
    setBBox(gi)
    -- per-group diagnostic snapshot for debug.log
    do
        local gd = {}
        for i = 1, #glist do
            local gj = glist[i]
            local resid = "-"
            if anc.cw then
                local l2 = math.log(gj.m * s / anc.cw) / LOG2
                resid = string.format("%.2f", math.abs(l2 - math.floor(l2 + 0.5)))
            end
            local bkt = tile.samples[gj.aw]
            gd[i] = string.format(
                "aw=%d n=%d hits=%d m=%.0fraw phase=(%.0f,%.0f) resid=%s samples=%d",
                gj.aw, gj.n, gj.hits, gj.m, gj.px, gj.py, resid, bkt and #bkt or 0)
        end
        anc.gdump = gd
    end

    -- 1) mapping from cached slots (all pitch-consistent groups vote; chunk
    -- pitch follows the drawn geometry, so pan AND zoom track exactly with no
    -- estimators). cwE comes from the largest group whose pitch is a clean
    -- power-of-two of the tracked chunk size. The game sometimes draws a
    -- NON-chunk-pitched streaming underlay (legacy saw a 345px-seam layer at
    -- 200%) that must steer neither the pitch nor the votes.
    -- gate 0.3: a wheel-zoom fling changes the pitch by up to ~23% in ONE
    -- frame (resid 0.30) and the anchor must ride through it; the non-chunk
    -- streaming underlay sits at resid ~0.415 and stays excluded. (cwE itself
    -- is exact either way, it comes from THIS frame's drawn pitch, the
    -- residual only picks e2.)
    local mapping
    local cwE
    if anc.cw then
        local pg
        for i = 1, #glist do
            local gj = glist[i]
            local l2 = math.log(gj.m * s / anc.cw) / LOG2
            local e2 = math.floor(l2 + 0.5)
            if e2 >= -3 and e2 <= 3 and math.abs(l2 - e2) <= 0.3
                    and (not pg or gj.n > pg.n) then
                pg = gj
                cwE = gj.m * s / 2 ^ e2
            end
        end
    end
    if cwE then
        local vx, vy, vk = {}, {}, {}
        for gidx = 1, #glist do
            local gj = glist[gidx]
            local l2 = math.log(gj.m * s / cwE) / LOG2
            local e2j = math.floor(l2 + 0.5)
            if e2j >= -3 and e2j <= 3 and math.abs(l2 - e2j) <= 0.3 then
                for i = 1, #gj.tiles do
                    local t = gj.tiles[i]
                    local key = gj.aw .. ":" .. t.ax .. "," .. t.ay
                    local sl = anc.slots[key]
                    if sl then
                        local utx, uty = tileTL(gj, t)
                        vx[#vx + 1] = utx * s - sl.cx * cwE
                        vy[#vy + 1] = uty * s - sl.cy * cwE
                        vk[#vk + 1] = key
                    end
                end
            end
        end
        anc.votesN = #vx
        if #vx > 0 then
            local mx, my = median(vx), median(vy)
            local kept = 0
            for i = 1, #vx do
                if math.abs(vx[i] - mx) > cwE * 0.25 or math.abs(vy[i] - my) > cwE * 0.25 then
                    anc.slots[vk[i]] = nil          -- stale identity (atlas slot reused)
                    anc.slotN = anc.slotN - 1
                else
                    kept = kept + 1
                end
            end
            anc.keptN = kept
            if kept > 0 then mapping = { x0 = mx, y0 = my, cw = cwE } end
        end
    end

    -- 2) content match: global acquisition when unanchored, global
    -- verification of the live mapping otherwise. Verification must be
    -- GLOBAL too: a search restricted around the current mapping cannot
    -- see a content jump bigger than its radius (the exact blind spot the
    -- legacy tracker suffered). With e2 known it is cheap.
    -- On acquisition the top TWO groups get a try. The biggest group can be
    -- the non-map underlay, and it must not starve the true map layer.
    local smTotal = 0
    for _, bkt in pairs(tile.samples) do smTotal = smTotal + #bkt end
    -- verify a live mapping regardless (cheap, single-scale); but while the
    -- pitch is still moving, DEFER cold acquisition (see pitchMoving above)
    if smTotal >= MIN_PTS and (mapping or not pitchMoving) then
        anc.lastTryF = S.frame
        local cwRef = mapping and mapping.cw or anc.cw
        -- the tracked pitch is only a HINT for acquisition, and a stale one
        -- can be plausibly WRONG: after a preset zoom (100->200%) the new
        -- pitch is an exact power-of-two of the stale cw, so the hinted e2
        -- locks the matcher to half/double the true chunk size forever.
        -- Alternate: every other attempt sweeps all scales.
        anc.acqN = (anc.acqN or 0) + 1
        local tries = 0
        local bestAcq, bestGj   -- best gate-passing acquisition across groups
        for ci = 1, #glist do
            local gj = glist[ci]
            if tries >= 2 then break end
            if mapping and gj ~= gi then break end   -- verify: elected group only
            local opts = { scale = s, winW = tile.winW }
            local skip = false
            if cwRef then
                local l2 = math.log(gj.m * s / cwRef) / LOG2
                local e2k = math.floor(l2 + 0.5)
                local clean = e2k >= -3 and e2k <= 3 and math.abs(l2 - e2k) <= 0.2
                if mapping then
                    -- verifying the live mapping: its scale is authoritative,
                    -- but every 8th verify ALSO checks one alternate scale so
                    -- a wrong-scale anchor cannot self-confirm forever (a
                    -- same-scale search would keep finding the same wrong
                    -- peak and agreeing). ONE alternate per pass, rotating
                    -- over all of -3..3: the old all-scales-in-one-frame
                    -- sweep was a measured 140ms freeze mid-pan
                    if clean then opts.e2 = e2k else skip = true end
                    anc.vfN = (anc.vfN or 0) + 1
                    if clean and anc.vfN % 8 == 0 then
                        local alt = math.floor(anc.vfN / 8) % 7 - 3
                        if alt ~= e2k then opts.e2 = { e2k, alt } end
                    end
                elseif clean then
                    -- acquisition: a zoom is a +-1 LOD step, so restrict the
                    -- search to a +-1 window around the stale-pitch-implied e2
                    -- instead of the full 7-scale sweep. This still escapes a
                    -- stale/preset-zoom pitch (which shifts e2 by ~1). Every
                    -- 6th attempt sweeps ALL scales as a cold-start safety net
                    -- (so a >1-LOD stale pitch can't lock the window out).
                    if anc.acqN % 6 ~= 0 then
                        local w = {}
                        for de = -1, 1 do
                            local ee = e2k + de
                            if ee >= -3 and ee <= 3 then w[#w + 1] = ee end
                        end
                        opts.e2 = w
                    end
                end
            end
            local sm = not skip and groupSamples(gj) or nil
            if sm and #sm >= MIN_PTS then
                tries = tries + 1
                local res, why = find.match(sm, gj.m, opts)
                if not res then
                    mlogAdd(string.format("--- %s n=%d aw=%d %s", why, #sm, gj.aw,
                        mapping and "verify" or "acquire"))
                else
                    local rcw = gj.m * s / 2 ^ res.e2
                    local rx0 = res.ol * s - res.cx * rcw
                    local ry0 = res.ot * s - res.cy * rcw
                    local core = string.format(
                        "%s aw=%d ncc=%.2f margin=%.2f e2=%d cells=%d n=%d span=%.1fx%.1f%s",
                        mapping and "verify" or "acquire", gj.aw, res.ncc, res.margin,
                        res.e2, res.cells, res.n, res.spanX, res.spanY,
                        res.weak and " WEAK" or "")
                    if mapping then
                        local agrees = math.abs(rx0 - mapping.x0) <= rcw * 0.3
                                and math.abs(ry0 - mapping.y0) <= rcw * 0.3
                        if agrees and res.ncc >= CONF_NCC then
                            anc.badN = 0
                            mlogAdd(core .. " OK")
                            if zFresh then
                                local pp = mapping.cw / S.zoom
                                anc.cwpp = anc.cwpp and (anc.cwpp + 0.2 * (pp - anc.cwpp)) or pp
                            end
                        elseif not agrees and res.ncc >= DIS_NCC and res.margin >= DIS_MARGIN then
                            anc.badN = anc.badN + 1
                            mlogAdd(core .. string.format(" DISAGREE d=(%.1f,%.1f)chunks bad=%d",
                                (rx0 - mapping.x0) / rcw, (ry0 - mapping.y0) / rcw, anc.badN))
                            if anc.badN >= DIS_BAD then
                                anc.slots, anc.slotN, anc.badN = {}, 0, 0
                                if res.weak or not scaleOK(rcw) then
                                    -- narrow-strip or scale-implausible evidence
                                    -- may kill a bad anchor but not seed a new
                                    -- one: re-acquire instead. The dead anchor's
                                    -- pitch goes too, it must not gate what
                                    -- re-acquisition may consider.
                                    log(string.format("[f%d] anchor DROPPED by content (%s)",
                                        S.frame, core))
                                    mapping = nil
                                    anc.cw = nil
                                else
                                    log(string.format(
                                        "[f%d] anchor REJECTED by content (%s), re-anchoring",
                                        S.frame, core))
                                    mapping = { x0 = rx0, y0 = ry0, cw = rcw }
                                    if zFresh then anc.cwpp = rcw / S.zoom end
                                end
                            end
                        else
                            mlogAdd(core .. " weak/ignored")
                        end
                        break
                    elseif res.ncc >= ACQ_NCC and res.margin >= ACQ_MARGIN and not res.weak then
                        -- gate-passing acquisition candidate: DON'T commit yet.
                        -- All groups race on ncc (first-pass-wins let a lucky
                        -- underlay fit shut the true map layer out).
                        if not scaleOK(rcw) then
                            mlogAdd(core .. string.format(" SCALE-BLOCKED cw=%.0f expect=%.0f",
                                rcw, anc.cwpp * S.zoom))
                        elseif not bestAcq or res.ncc > bestAcq.ncc then
                            bestAcq = { ncc = res.ncc, x0 = rx0, y0 = ry0,
                                        cw = rcw, core = core }
                            bestGj = gj
                        else
                            mlogAdd(core .. " pass(outscored)")
                        end
                    else
                        mlogAdd(core .. " reject")
                    end
                end
            end
        end
        -- two-attempt confirmation: a mapping is only committed when TWO
        -- acquisition attempts, on different sample grids, agree on
        -- position and pitch. A one-off spurious fit (wrong scale or wrong
        -- layer clearing the gates by luck) then never reaches the screen:
        -- that was the intermittent wrong-chunk-size grid flash at 200%.
        if bestAcq then
            local pend = anc.pend
            local agrees = pend and S.frame - pend.f <= 15
                and math.abs(bestAcq.cw - pend.cw) <= pend.cw * 0.05
                and math.abs(bestAcq.x0 - pend.x0) <= bestAcq.cw * 0.35
                and math.abs(bestAcq.y0 - pend.y0) <= bestAcq.cw * 0.35
            if agrees then
                anc.pend = nil
                anc.slots, anc.slotN = {}, 0   -- stale identity must not survive a fresh fix
                mapping = { x0 = bestAcq.x0, y0 = bestAcq.y0, cw = bestAcq.cw }
                log(string.format("[f%d] anchor ACQUIRED %s cw=%.1fpx",
                    S.frame, bestAcq.core, bestAcq.cw))
                mlogAdd(bestAcq.core .. " CONFIRM")
                -- doubly-confirmed content evidence: (re)calibrate the
                -- zoom-relative scale yardstick
                if zFresh then anc.cwpp = bestAcq.cw / S.zoom end
                if bestGj ~= gi then
                    gi = bestGj            -- the matched layer is the map
                    anc.elect = bestGj.aw
                    setBBox(bestGj)
                end
            else
                anc.pend = { x0 = bestAcq.x0, y0 = bestAcq.y0, cw = bestAcq.cw,
                             f = S.frame }
                mlogAdd(bestAcq.core .. " PEND")
            end
        end
    elseif smTotal >= MIN_PTS and pitchMoving then
        -- zoom in flight: the drawn pitch is still changing, so any global
        -- acquisition search would only correlate a mid-transition frame at
        -- full cost. Skip it and wait for the pitch to settle.
        mlogAdd("--- deferred: pitch moving")
    end

    -- 3) cache identity for this frame's unknown slots from the mapping
    -- every tile in every pitch-consistent group, clipped or not (the
    -- unclipped lattice position is exact either way)
    if mapping then
        local cw = mapping.cw
        if anc.slotN >= SLOT_CAP then
            anc.slots, anc.slotN = {}, 0   -- rebuilt below from the live mapping
        end
        for gidx = 1, #glist do
            local gj = glist[gidx]
            local l2 = math.log(gj.m * s / cw) / LOG2
            local e2j = math.floor(l2 + 0.5)
            if e2j >= -3 and e2j <= 3 and math.abs(l2 - e2j) <= 0.2 then
                -- the tile lattice can sit half a tile off the chunk grid
                local half = 2 ^ e2j / 2
                for i = 1, #gj.tiles do
                    local t = gj.tiles[i]
                    local key = gj.aw .. ":" .. t.ax .. "," .. t.ay
                    if not anc.slots[key] then
                        local utx, uty = tileTL(gj, t)
                        local cx = (utx * s - mapping.x0) / cw
                        local cy = (uty * s - mapping.y0) / cw
                        local qx, qy = cx / half, cy / half
                        local rx, ry = qx - math.floor(qx + 0.5), qy - math.floor(qy + 0.5)
                        if math.abs(rx) <= 0.4 and math.abs(ry) <= 0.4 then
                            anc.slots[key] = { cx = math.floor(qx + 0.5) * half,
                                               cy = math.floor(qy + 0.5) * half }
                            anc.slotN = anc.slotN + 1
                        end
                    end
                end
                if gj == gi then anc.e2 = e2j end
            end
        end
        anc.cw = cw
        anc.frame = S.frame
        anc.draw = mapping
    end
    -- edge-triggered loss diagnosis: WHY did a live mapping vanish?
    if not anc.draw and anc.wasDrawF == S.frame - 1 then
        local why
        if not cwE then
            why = anc.cw and "no pitch-consistent group" or "no tracked pitch (cold)"
        elseif anc.votesN == 0 then
            why = "no cached slots among visible tiles"
        else
            why = "all slot votes evicted"
        end
        log(string.format("[f%d] mapping LOST: %s (groups=%d slots=%d elect=%s)",
            S.frame, why, #glist, anc.slotN, tostring(anc.elect)))
    end
    if anc.draw then anc.wasDrawF = S.frame end
    anc.ok = anc.draw ~= nil
end

return { updateAnchor = updateAnchor }

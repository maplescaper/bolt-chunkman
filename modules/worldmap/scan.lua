-- ---- 2D batch scan: OCR + tile collection + panel quads + texel samples ----
-- OCR parsing note: RS3 draws UI text outlined. Each glyph is emitted
-- several times; glyphs are read in RENDER ORDER with minimal dedup (see
-- record/scan2d), never sorted.

-- loaded by the worldmap internal loader: mreq loads sibling modules
local mreq = ...
local bolt = mreq("bolt")
local chat = mreq("chat")
local state = mreq("state")

local S, tile, anc = state.S, state.tile, state.anc
local TARGET, FRAGMENTS = state.TARGET, state.FRAGMENTS
local DUP_PX, MAX_IMAGES = state.DUP_PX, state.MAX_IMAGES
local SAMPLE_EVERY, SAMPLE_CAP = state.SAMPLE_EVERY, state.SAMPLE_CAP
local TILE_MIN_ATLAS, TILE_MAX_ATLAS = state.TILE_MIN_ATLAS, state.TILE_MAX_ATLAS
local TILE_MIN_DRAWN, TILE_MAX_LIST = state.TILE_MIN_DRAWN, state.TILE_MAX_LIST

-- ---- OCR ----
local function record(line, sample)
    local low = line:lower()
    -- The map is "open" only when the ACTIVE title is seen, and the active
    -- title's glyph run carries the zoom readout right after it (it reads
    -- like "runescapesurface100%"). The same surface NAME also renders as a
    -- bare label in the map-selection dropdown, even while a different
    -- surface is displayed, so a bare match without the digits+% suffix must
    -- not count: it would hold the map "open" (and paint overlays) over
    -- surfaces that can never anchor.
    local ti = low:find(TARGET, 1, true)
    if ti and low:find("%d+%%", ti + #TARGET) then
        S.seen = true
        S.lastLine = line
    end
    for f = 1, #FRAGMENTS do
        if low:find(FRAGMENTS[f], 1, true) then S.cands[line] = true; break end
    end
    if sample and #line >= 3 then S.lines[line] = true end
end

local function scan2d(event)
    S.batches = S.batches + 1
    local vertexcount = event:vertexcount()
    local vpi = event:verticesperimage()
    if not vpi or vpi == 0 or vertexcount < vpi then return end
    local sample = (S.frame % SAMPLE_EVERY == 0)
    local doTrack = S.wasOpen or S.seen
    local scale = 1
    if doTrack then
        local okw, w, h = pcall(bolt.gamewindowsize)
        local okt, tw, th = pcall(event.targetsize, event)
        if okw and w and okt and tw and tw > 0 then
            scale = w / tw
            tile.winW, tile.winH, tile.rawW, tile.rawH = w, h, tw, th
        end
    end

    -- map-area OCR skip: while the map view is resolved, the only OCR that
    -- matters is the TITLE BAR (open detection + zoom readout), which sits
    -- above the view rect. Glyph-sized images inside the view are map icons
    -- and place labels, and each one whose height matches a font height costs
    -- a texturedata readback + string alloc in lookupchatcharacter.
    local mvx0, mvy0
    if S.mapView and scale > 0 then
        mvx0, mvy0 = S.mapView.x / scale, S.mapView.y / scale
    end
    -- the panel hunt (3-vertex probe of every image + big-quad list) only
    -- needs to run when the map view is unresolved/stale; once anchored with
    -- a good rect, refresh it at 1Hz instead of every sample frame
    local wantBig = sample and doTrack
        and (not anc.ok or not S.mapView or S.mapView.winW ~= tile.winW
             or S.frame % 60 == 0)

    local scanned = 0
    local lastx, lasty, lastax, lastay      -- consecutive-dup glyph skip
    local run = {}                          -- chars of the current string
    local runY, runLastX, prevLine
    local batchTiles = {}

    local function endRun()
        if #run > 0 then
            local line = table.concat(run)
            if line ~= prevLine then record(line, sample); prevLine = line end
            run = {}
        end
        runY, runLastX = nil, nil
    end

    for i = 1, vertexcount, vpi do
        scanned = scanned + 1
        if scanned > MAX_IMAGES then break end
        local ax, ay, aw, ah = event:vertexatlasdetails(i)
        local x, y = event:vertexxy(i + 2)
        if doTrack then
            -- diagnostic atlas-size histogram (sample frames, for tiles.txt
            -- which is only written while UNANCHORED, so don't pay the
            -- per-image string key in the anchored steady state)
            if sample and not anc.ok then
                local hk = aw .. "x" .. ah
                local e = tile.hist[hk]
                if e then
                    e.n = e.n + 1
                elseif (aw >= 32 or ah >= 32) and tile.histN < 48 then
                    tile.hist[hk] = { n = 1 }
                    tile.histN = tile.histN + 1
                end
            end
            local tileLike = aw >= TILE_MIN_ATLAS and aw <= TILE_MAX_ATLAS
                    and ah >= TILE_MIN_ATLAS and ah <= TILE_MAX_ATLAS
                    and math.abs(aw - ah) <= math.max(4, aw / 8)
            local isTile = tileLike and #batchTiles < TILE_MAX_LIST
            if isTile or wantBig then
                -- tiles need the exact bbox; non-tile images (scanned on
                -- sample frames for the panel hunt) probe 3 vertices first
                -- and refine only the few that pass the >=400px gate
                local minx, miny, maxx, maxy = x, y, x, y
                local kmax = isTile and vpi - 1 or math.min(2, vpi - 1)
                for k = 0, kmax do
                    local vx, vy = event:vertexxy(i + k)
                    if vx then
                        if vx < minx then minx = vx elseif vx > maxx then maxx = vx end
                        if vy < miny then miny = vy elseif vy > maxy then maxy = vy end
                    end
                end
                local sw, sh = maxx - minx, maxy - miny
                if not isTile and (sw >= 400 or sh >= 400) then
                    for k = kmax + 1, vpi - 1 do
                        local vx, vy = event:vertexxy(i + k)
                        if vx then
                            if vx < minx then minx = vx elseif vx > maxx then maxx = vx end
                            if vy < miny then miny = vy elseif vy > maxy then maxy = vy end
                        end
                    end
                    sw, sh = maxx - minx, maxy - miny
                end
                if isTile and sw >= TILE_MIN_DRAWN and sh >= TILE_MIN_DRAWN then
                    batchTiles[#batchTiles + 1] = {
                        cx = (minx + maxx) / 2, cy = (miny + maxy) / 2,
                        w = sw, h = sh, aw = aw, ah = ah, ax = ax, ay = ay }
                    -- texel samples for the chunk matcher: per-ATLAS-SIZE
                    -- bucket with its own stride, so a numerous non-map layer
                    -- cannot starve the few big map tiles at high zoom.
                    -- smSeen counts EVERY candidate tile (even once the bucket
                    -- is full). It feeds the next frame's stride, and under-
                    -- counting locked the stride at 1, sampling only the first
                    -- rows of the batch (narrow-strip templates).
                    local bkt
                    if tile.needSamples and aw == ah then
                        tile.smSeen[aw] = (tile.smSeen[aw] or 0) + 1
                        bkt = tile.samples[aw]
                        if not bkt then bkt = {}; tile.samples[aw] = bkt end
                        if #bkt >= SAMPLE_CAP then bkt = nil end
                    end
                    if bkt then
                        if tile.smSeen[aw] % (tile.smStride[aw] or 1) == 0 then
                            -- alternate the sample grid between attempts (3x3
                            -- vs 4x4 / 2x2 vs 3x3): consecutive acquisition
                            -- attempts then see genuinely different texels, so
                            -- a spurious match cannot CONFIRM itself on a
                            -- static screen, while a true match persists
                            local nn = (sw * scale) >= 600 and 4 or 2
                            if S.frame % 4 >= 2 then nn = 3 end
                            local sp = 0.25 / nn
                            for ui = 0, nn - 1 do
                                for vi = 0, nn - 1 do
                                    local u, v = (ui + 0.5) / nn, (vi + 0.5) / nn
                                    -- one reference cell is a box average; a
                                    -- single texel against that is noise, so
                                    -- average 4 texels spread over the cell
                                    local acc, na = 0, 0
                                    for du = -1, 1, 2 do
                                        for dv = -1, 1, 2 do
                                            local okd, d = pcall(event.texturedata, event,
                                                math.floor(ax + (u + du * sp) * aw),
                                                math.floor(ay + (v + dv * sp) * ah), 4)
                                            if okd and d then
                                                local r, g, b = string.byte(d, 1, 3)
                                                acc = acc + ((r or 0) + (g or 0) + (b or 0)) / 3
                                                na = na + 1
                                            end
                                        end
                                    end
                                    if na >= 3 and #bkt < SAMPLE_CAP then
                                        bkt[#bkt + 1] = {
                                            left = minx, top = miny, w = sw, h = sh,
                                            u = u, v = v, lum = acc / na }
                                    end
                                end
                            end
                        end
                    end
                end
                -- panel/background candidates for resolveMapView. Tile-shaped
                -- quads must NOT qualify: at 200% zoom a clipped ~900px map
                -- tile passes every panel filter and its right edge outbids
                -- the real left panel, so the view rect shrank while panning
                if wantBig and not tileLike
                        and (sw >= 400 or sh >= 400) and #tile.big < 300 then
                    tile.big[#tile.big + 1] = { x = minx, y = miny, w = sw, h = sh }
                end
            end
        end
        -- glyph OCR: chat-font glyphs are small, skip the (per-image!)
        -- font-table lookup for tiles, panels, icons outright
        if aw > 64 or ah > 64 then goto continue end
        -- ... and for everything inside the map view (icons/place labels);
        -- the title bar above the view is all the OCR that matters when open
        if mvx0 and x >= mvx0 and y >= mvy0 then goto continue end
        -- skip interleaved outline/shadow copies, then read runs
        if lastx and math.abs(x - lastx) < DUP_PX and math.abs(y - lasty) < DUP_PX
                and ax == lastax and ay == lastay then
            goto continue
        end
        lastx, lasty, lastax, lastay = x, y, ax, ay
        do
            local c = chat:lookupchatcharacter(event, ax, ay, aw, ah)
            if not c then goto continue end
            S.glyphs = S.glyphs + 1
            if runY == nil then
                runY, runLastX, run[1] = y, x, c
            elseif math.abs(y - runY) <= 3 and x >= runLastX - DUP_PX then
                run[#run + 1] = c
                runLastX = x
            else
                endRun()
                runY, runLastX, run[1] = y, x, c
            end
        end
        ::continue::
    end
    endRun()
    -- MERGE into the frame list unreduced: the map can draw its tiles across
    -- several batches in one frame, AND a batch can mix the map layer with a
    -- more numerous streaming underlay (200%), keeping only the batch's
    -- dominant atlas size here would throw the real map tiles away. All
    -- grouping/election happens per-frame in updateAnchor.
    for i = 1, #batchTiles do tile.list[#tile.list + 1] = batchTiles[i] end
    if #batchTiles > 0 then
        tile.scale = scale
        tile.dump[#tile.dump + 1] = { batch = S.batches, n = #batchTiles,
            n0 = #batchTiles, aw = batchTiles[1].aw, ah = batchTiles[1].ah }
    end
    S.images = S.images + scanned
end

return { scan2d = scan2d }

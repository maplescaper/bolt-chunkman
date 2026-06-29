-- All GPU drawing and the two render callbacks' logic. Region boundary lines and
-- the locked-chunk grey-out are drawn here; the camera matrix and ground height
-- are captured here too. main.lua registers the bolt callbacks and forwards them
-- to onRender3d / onRenderGameView.

local bolt     = require("bolt")
local util     = require("util")
local config   = require("config")
local settings = require("settings")
local world    = require("world")
local chunks   = require("chunks")
local shaders  = require("shaders")

local cfg              = settings.cfg
local unpack           = util.unpack
local UNITS_PER_TILE   = config.UNITS_PER_TILE
local TILES_PER_REGION = config.TILES_PER_REGION
local GRID_STEP_TILES  = config.GRID_STEP_TILES
local GROUND_MAX_SAMPLES = config.GROUND_MAX_SAMPLES

local M = {}

-- ---- line geometry helpers ----

-- add a world-space segment to the list if both ends are in front of the camera
local function addSeg(lines, x0, y, z0, x1, z1, col)
    if world.inFront(x0, y, z0) and world.inFront(x1, y, z1) then
        lines[#lines + 1] = {
            x0 = x0, y0 = y, z0 = z0, x1 = x1, y1 = y, z1 = z1,
            r = col.r, g = col.g, b = col.b, a = 1.0,
        }
    end
end

-- add a boundary line (constant tileX or constant tileZ), subdivided per step
local function addBoundary(lines, constX, fixedTile, t0, t1, y, col)
    local prev
    for t = t0, t1, GRID_STEP_TILES do
        if prev then
            if constX then
                addSeg(lines, fixedTile * UNITS_PER_TILE, y, prev * UNITS_PER_TILE,
                    fixedTile * UNITS_PER_TILE, t * UNITS_PER_TILE, col)
            else
                addSeg(lines, prev * UNITS_PER_TILE, y, fixedTile * UNITS_PER_TILE,
                    t * UNITS_PER_TILE, fixedTile * UNITS_PER_TILE, col)
            end
        end
        prev = t
    end
end

-- ---- GPU grey-out mode A: per-pixel by reconstructed world position ----
-- One full-screen pass. The fragment shader reconstructs each pixel's world
-- position from the depth buffer (using the inverse camera matrix), works out
-- which chunk it lies in, and greys it unless that chunk is unlocked. Because
-- every pixel is judged by where it actually is, the grey boundary follows the
-- terrain exactly and never floats or drifts with the camera. Nothing to draw if no chunk is
-- unlocked (the whole-view dim handles "everything locked" instead).
-- Hard ceiling on the keep list: the shader's uKeep array is vec4[64] and its
-- per-pixel loop is bounded the same way. When more chunks are unlocked than fit,
-- chunks.nearestKeepIds selects the KEEP_MAX nearest the player, so the chunks
-- that could actually be on screen are always included.
local KEEP_VEC4_MAX = 64                 -- 64 vec4s => up to 256 chunks uploaded
local KEEP_MAX = KEEP_VEC4_MAX * 4
local CHUNKS_PER_AXIS = config.CHUNKS_PER_AXIS
local GREY_GRID_RADIUS = config.GREY_GRID_RADIUS

-- Inverse viewproj is needed every frame to reconstruct world position, but when
-- the camera is idle the matrix is bit-identical frame to frame. Cache the last
-- matrix and its inverse so an idle camera skips the ~200-multiply inversion (and
-- its table churn) entirely; only a moved camera pays for it.
local cachedVP, cachedInvVP
local function invViewproj()
    local m = { world.viewproj:get() }
    if cachedVP then
        local same = true
        for i = 1, 16 do if cachedVP[i] ~= m[i] then same = false; break end end
        if same then return cachedInvVP end
    end
    cachedVP, cachedInvVP = m, util.invertMat4(m)
    return cachedInvVP
end

-- The non-camera uniforms (tint, screen size, keep-list, sky flag, keep bbox)
-- only change on a settings edit, a window resize, or when the player crosses
-- into a region that reselects the nearest keep-list. GL keeps uniform state on
-- the program between draws, so re-upload this block only when one of its inputs
-- actually changes instead of every frame (saving up to ~64 setuniform4f calls
-- per frame). keepIds reference identity is a reliable "did the list change"
-- signal: both nearestKeepIds and rebuildGreyChunks replace the table wholesale.
local up = {}
local function uploadStatic(grey, keepIds, n, sw, sh, prx, prz)
    local c = cfg.lockedColour
    local sky = cfg.greySky and 1 or 0
    if up.keep == keepIds and up.n == n and up.sw == sw and up.sh == sh
        and up.r == c.r and up.g == c.g and up.b == c.b and up.a == c.a and up.sky == sky
        and up.prx == prx and up.prz == prz then
        return
    end

    -- region bounding box of the uploaded keep set, for the shader's early-out
    local rxMin, rzMin, rxMax, rzMax = math.huge, math.huge, -math.huge, -math.huge
    for i = 1, n do
        local id = keepIds[i]
        local rx, rz = math.floor(id / CHUNKS_PER_AXIS), id % CHUNKS_PER_AXIS
        if rx < rxMin then rxMin = rx end
        if rx > rxMax then rxMax = rx end
        if rz < rzMin then rzMin = rz end
        if rz > rzMax then rzMax = rz end
    end

    grey:setuniform4f(1, c.r, c.g, c.b, c.a)
    grey:setuniform2f(2, sw, sh)
    grey:setuniform4f(4, rxMin, rzMin, rxMax, rzMax)
    -- (2r+1)x(2r+1) grey window centred on the player's region; chunks outside it
    -- are left untouched so the grey-out never extends beyond this grid.
    grey:setuniform4f(5, prx - GREY_GRID_RADIUS, prz - GREY_GRID_RADIUS,
        prx + GREY_GRID_RADIUS, prz + GREY_GRID_RADIUS)
    grey:setuniform1f(8, n)
    grey:setuniform1f(9, sky)
    for j = 0, math.ceil(n / 4) - 1 do
        grey:setuniform4f(10 + j,
            keepIds[j * 4 + 1] or -1, keepIds[j * 4 + 2] or -1,
            keepIds[j * 4 + 3] or -1, keepIds[j * 4 + 4] or -1)
    end

    up.keep, up.n, up.sw, up.sh = keepIds, n, sw, sh
    up.r, up.g, up.b, up.a, up.sky = c.r, c.g, c.b, c.a, sky
    up.prx, up.prz = prx, prz
end

local function drawGreyReconstruct(event, prx, prz)
    local keepIds = chunks.nearestKeepIds(prx, prz, KEEP_MAX)
    local n = #keepIds
    if not shaders.grey or n == 0 then return end
    local inv = invViewproj()
    if not inv then return end
    local sw, sh = bolt.gamewindowsize()
    local grey = shaders.grey
    uploadStatic(grey, keepIds, n, sw, sh, prx, prz)
    grey:setuniformmatrix4f(3, false, unpack(inv))
    grey:setuniformdepthbuffer(7, event)
    grey:drawtogameview(event, shaders.fillBuffer, 6)
end

-- ---- GPU grey-out mode B: vertical curtains along chunk frontiers (original) ----
-- The shared uniforms (camera, height range, colour, depth) are set once per
-- frame via beginWalls; drawWallSeg then raises a single curtain along one
-- ground edge. drawGreyCurtains uses these to wall off the frontier of the
-- unlocked area. This is the original approach: a vertical wall is projected per
-- chunk edge and the depth buffer darkens whatever lies behind it. Kept as a
-- selectable mode (cfg.reconstructGrey = false); its edges can float/drift over
-- undulating terrain, which is exactly why mode A exists.
local function beginWalls(event, y)
    local fill = shaders.fill
    local sw, sh = bolt.gamewindowsize()
    fill:setuniformmatrix4f(3, false, world.viewproj:get())
    fill:setuniform2f(2, y, y + cfg.lockedWallHeight)
    fill:setuniform4f(4, cfg.lockedColour.r, cfg.lockedColour.g, cfg.lockedColour.b, cfg.lockedColour.a)
    fill:setuniformdepthbuffer(5, event)
    fill:setuniform2f(6, sw, sh)
end

-- one curtain along a ground base-line {x0,z0 -> x1,z1}, raised by the shader
local function drawWallSeg(event, x0, z0, x1, z1)
    shaders.fill:setuniform4f(1, x0, z0, x1, z1)
    shaders.fill:drawtogameview(event, shaders.fillBuffer, 6)
end

-- grey out the whole world EXCEPT the listed chunks: the listed chunks are the
-- "unlocked" ones. We wall off only the frontier, each edge of an unlocked
-- chunk that borders a chunk NOT in the list. Edges shared by two unlocked
-- chunks stay open, so a contiguous unlocked area is fully clear inside and
-- curtained at its perimeter. If nothing is unlocked there are no frontiers and
-- this draws nothing. The whole-view dim (below) covers that case instead.
local function drawGreyCurtains(event, y)
    local keepRegions, keepSet = chunks.keepRegions, chunks.keepSet
    if not shaders.fill or #keepRegions == 0 then return end
    beginWalls(event, y)
    local U = UNITS_PER_TILE * TILES_PER_REGION
    for _, rg in ipairs(keepRegions) do
        local rx, rz = rg.rx, rg.rz
        local x0, z0 = rx * U, rz * U
        local x1, z1 = x0 + U, z0 + U
        if not keepSet[(rx - 1) .. "," .. rz] then drawWallSeg(event, x0, z1, x0, z0) end  -- min-x frontier
        if not keepSet[(rx + 1) .. "," .. rz] then drawWallSeg(event, x1, z0, x1, z1) end  -- max-x frontier
        if not keepSet[rx .. "," .. (rz - 1)] then drawWallSeg(event, x0, z0, x1, z0) end  -- min-z frontier
        if not keepSet[rx .. "," .. (rz + 1)] then drawWallSeg(event, x1, z1, x0, z1) end  -- max-z frontier
    end
end

-- ---- full-screen dim (when standing in a locked chunk) ----
-- Reuses the curtain fill shader to paint one screen-filling quad. We feed it
-- an identity matrix and place the quad at the near plane (NDC z = -1) so its
-- depth-occlusion test can never discard, and so the whole game view is tinted
-- by uColor with the shader's normal alpha blend (black + alpha => darken).
local function drawLockedViewDim(event)
    local fill = shaders.fill
    if not fill then return end
    local sw, sh = bolt.gamewindowsize()
    fill:setuniformmatrix4f(3, false, 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1)
    fill:setuniform4f(1, -1, -1, 1, -1)   -- uBase: x spans -1..1, z fixed at -1 (near)
    fill:setuniform2f(2, -1, 1)           -- uYrange: y spans -1..1
    fill:setuniform4f(4, cfg.lockedColour.r, cfg.lockedColour.g, cfg.lockedColour.b, cfg.lockedColour.a)
    fill:setuniformdepthbuffer(5, event)
    fill:setuniform2f(6, sw, sh)
    fill:drawtogameview(event, shaders.fillBuffer, 6)
end

-- ---- GPU line batch ----
local function drawLines(event, lines)
    local shader = shaders.line
    if not shader or #lines == 0 then return end
    local sw, sh = bolt.gamewindowsize()
    shader:setuniformmatrix4f(3, false, world.viewproj:get())
    shader:setuniform2f(6, sw, sh)
    shader:setuniform1f(10, 0)
    shader:setuniform1f(11, 0)   -- no pulses
    shader:setuniform1f(12, 0)
    shader:setuniform1f(13, 0)   -- no rainbow
    shader:setuniformdepthbuffer(14, event)
    shader:setuniform2f(15, sw, sh)
    shader:setuniform1f(16, 0)   -- no rounded caps

    -- Per-pass-constant uniforms (thickness, the constant flags, and the colour
    -- when the outline pass forces black) are set once here rather than per
    -- segment; only the endpoints (and the per-line colour) change in the loop.
    local function batch(extra, forceBlack)
        local th = cfg.lineThickness + extra
        shader:setuniform1f(4, th / 2.0)
        shader:setuniform1f(9, th / 2.0)
        shader:setuniform1f(7, 0)
        shader:setuniform1f(8, 1)
        if forceBlack then shader:setuniform4f(5, 0, 0, 0, 0.6) end
        for _, ln in ipairs(lines) do
            shader:setuniform3f(1, ln.x0, ln.y0, ln.z0)
            shader:setuniform3f(2, ln.x1, ln.y1, ln.z1)
            if not forceBlack then shader:setuniform4f(5, ln.r, ln.g, ln.b, ln.a) end
            shader:drawtogameview(event, shaders.lineBuffer, 6)
        end
    end

    if cfg.blackOutline then batch(2, true) end
    batch(0, false)
end

-- ---- render callbacks ----

-- Capture the camera matrix from the LAST 3D pass each frame (matches the
-- bolt-questhelper convention). The first pass of a frame is an early /
-- off-screen render with a different matrix, so using it makes world overlays
-- drift as the camera moves. Last-write-wins gives the matrix that matches the
-- game view that's actually composited this frame. While here (and not pinned to
-- a fixed height), sample the terrain to find the ground height under the player.
function M.onRender3d(event)
    world.viewproj = event:viewprojmatrix()
    world.haveVPThisFrame = true

    if cfg.useFixedHeight then return end
    -- mode A (pixel-perfect grey) reconstructs height per-pixel and never reads
    -- world.groundY; only curtain mode and the region lines need the scan, so skip
    -- the per-frame terrain sampling when neither is in play.
    if cfg.reconstructGrey and not cfg.showRegionLines then return end
    if not world.doGroundScan or world.terrainScannedThisFrame or not world.haveMM then return end
    if event:animated() then return end
    local vc = event:vertexcount()
    if vc < 1000 then return end
    world.terrainScannedThisFrame = true

    local mm = event:modelmatrix()
    local step = math.max(8, math.floor(vc / GROUND_MAX_SAMPLES))
    local bestD, bestY = math.huge, nil
    for i = 1, vc, step do
        local wx, wy, wz = event:vertexpoint(i):transform(mm):get()
        local d = math.abs(wx - world.mmX) + math.abs(wz - world.mmZ)
        if d < bestD then bestD, bestY = d, wy end
    end
    if bestY then world.groundY, world.haveGroundY = bestY, true end
end

function M.onRenderGameView(event)
    world.lastWinW, world.lastWinH = bolt.gamewindowsize()
    if not (world.viewproj and world.haveMM) then return end

    local prx, prz = world.playerRegion()

    -- grey out everything except the hand-picked "unlocked" chunks. Two modes:
    -- A (reconstructGrey) greys per-pixel by reconstructed world position (no
    -- placement height needed); B is the original projected curtain walls (needs
    -- a flat height). Skipped entirely outside the overworld (e.g. dungeons).
    if cfg.greyLocked and chunks.isOverworld(prx, prz) then
        if cfg.reconstructGrey then
            drawGreyReconstruct(event, prx, prz)
        else
            local y = world.gridHeight()
            if y then drawGreyCurtains(event, y) end
        end
        -- if you're standing in a locked chunk, dim the entire camera view. With
        -- nothing unlocked, every chunk is locked, so this dims the world.
        if cfg.dimLockedView and not chunks.keepSet[prx .. "," .. prz] then
            drawLockedViewDim(event)
        end
    end

    -- region boundary lines (orange grid + cyan current region). These sit on a
    -- flat plane, so they still need a placement height.
    if cfg.showRegionLines then
        local y = world.gridHeight()
        if y then
            local txMin = (prx - cfg.regionRadius) * TILES_PER_REGION
            local txMax = (prx + cfg.regionRadius + 1) * TILES_PER_REGION
            local tzMin = (prz - cfg.regionRadius) * TILES_PER_REGION
            local tzMax = (prz + cfg.regionRadius + 1) * TILES_PER_REGION

            local lines = {}
            for rx = prx - cfg.regionRadius, prx + cfg.regionRadius + 1 do
                addBoundary(lines, true, rx * TILES_PER_REGION, tzMin, tzMax, y, cfg.regionColour)
            end
            for rz = prz - cfg.regionRadius, prz + cfg.regionRadius + 1 do
                addBoundary(lines, false, rz * TILES_PER_REGION, txMin, txMax, y, cfg.regionColour)
            end

            -- highlight the region the player is in
            local x0, x1 = prx * TILES_PER_REGION, (prx + 1) * TILES_PER_REGION
            local z0, z1 = prz * TILES_PER_REGION, (prz + 1) * TILES_PER_REGION
            addBoundary(lines, true, x0, z0, z1, y, cfg.currentRegionColour)
            addBoundary(lines, true, x1, z0, z1, y, cfg.currentRegionColour)
            addBoundary(lines, false, z0, x0, x1, y, cfg.currentRegionColour)
            addBoundary(lines, false, z1, x0, x1, y, cfg.currentRegionColour)

            drawLines(event, lines)
        end
    end
end

return M

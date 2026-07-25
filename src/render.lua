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

-- ---- GPU grey-out: per-pixel by reconstructed world position ----
-- One full-screen pass. The fragment shader reconstructs each pixel's world
-- position from the depth buffer (using the inverse camera matrix), works out
-- which chunk it lies in, and greys it unless that chunk is unlocked. Because
-- every pixel is judged by where it actually is, the grey boundary follows the
-- terrain exactly and never floats or drifts with the camera. Still runs with
-- zero chunks unlocked: the keep texture is then all-empty, so every pixel
-- greys, dimming the whole view.
-- The "is this chunk unlocked?" test is a single texelFetch into a 256x256 keep
-- texture (shaders.keepTex), so it is O(1) per pixel with no cap on the unlock
-- count.
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

-- Repaint the keep texture (one white texel per unlocked chunk) whenever the
-- unlocked set changes, and (re)bind it to the grey shader's sampler. The set
-- only changes on load / reset / a panel edit, so this is rare; chunks.keepIds is
-- replaced wholesale on rebuild, so its table identity is the change signal.
-- Returns false if the texture isn't available (shader pass then skips).
local KEEP_WHITE = "\xFF\xFF\xFF\xFF"
local keepTexBuiltFor
local function refreshKeepTex(grey)
    local tex = shaders.keepTex
    if not tex then return false end
    local ids = chunks.keepIds
    if keepTexBuiltFor == ids then return true end
    tex:clear(0, 0, 0, 0)
    for i = 1, #ids do
        local id = ids[i]
        local rx, rz = math.floor(id / CHUNKS_PER_AXIS), id % CHUNKS_PER_AXIS
        if rx >= 0 and rx < CHUNKS_PER_AXIS and rz >= 0 and rz < CHUNKS_PER_AXIS then
            tex:subimage(rx, rz, 1, 1, KEEP_WHITE)
        end
    end
    grey:setuniformsurface(6, tex)
    keepTexBuiltFor = ids
    return true
end

local function drawGreyReconstruct(event, prx, prz)
    if not shaders.grey then return end
    local inv = invViewproj()
    if not inv then return end
    local grey = shaders.grey
    if not refreshKeepTex(grey) then return end

    -- The inverse camera matrix and depth buffer are the only genuinely per-frame
    -- inputs. The rest (tint, sky flag, grey window) are a few cheap uniforms that
    -- change rarely, so just set them each frame rather than tracking dirtiness.
    local c = cfg.lockedColour
    grey:setuniform4f(1, c.r, c.g, c.b, c.a)
    -- (2r+1)x(2r+1) grey window centred on the player's region; chunks outside it
    -- are left untouched so the grey-out never extends beyond this grid.
    grey:setuniform4f(5, prx - GREY_GRID_RADIUS, prz - GREY_GRID_RADIUS,
        prx + GREY_GRID_RADIUS, prz + GREY_GRID_RADIUS)
    grey:setuniform1f(9, cfg.greySky and 1 or 0)

    grey:setuniformmatrix4f(3, false, unpack(inv))
    grey:setuniformdepthbuffer(7, event)
    grey:drawtogameview(event, shaders.fillBuffer, 6)
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
-- Last camera position we captured the viewproj for, and the frame we did it on.
-- Used to avoid re-allocating the viewproj matrix on every single 3D pass.
local capFrame, capX, capY, capZ = -1, nil, nil, nil

function M.onRender3d(event)
    -- event:viewprojmatrix() allocates a matrix object every call. An open vista
    -- (e.g. looking out over a waterfall to the sky) draws thousands of 3D passes
    -- per frame, and capturing on each one was thrashing the GC. But the viewproj
    -- is the *camera* matrix: identical across every pass that shares a camera, and
    -- only the off-screen/minimap passes use a different one. cameraposition() is
    -- allocation-free, so use it as a cheap guard and only pay for viewprojmatrix()
    -- when the camera actually changes (about once per frame instead of once per
    -- draw call). We still re-capture at least once each frame (the frame check),
    -- and the last distinct camera wins, which is the main view, exactly as before.
    -- Animated passes share the same camera, so skip them outright.
    if cfg.writeDiag then world.calls3d = world.calls3d + 1 end
    if event:animated() then return end
    if cfg.writeDiag then
        world.callsNonAnim = world.callsNonAnim + 1
        local dvc = event:vertexcount()
        if dvc > world.maxVertexCount then world.maxVertexCount = dvc end
    end
    local cx, cy, cz = event:cameraposition()
    if world.frameCount ~= capFrame or cx ~= capX or cy ~= capY or cz ~= capZ then
        world.viewproj = event:viewprojmatrix()
        world.haveVPThisFrame = true
        capFrame, capX, capY, capZ = world.frameCount, cx, cy, cz
    end

    if cfg.useFixedHeight then return end
    -- the grey-out reconstructs height per-pixel and never reads world.groundY;
    -- only the region lines need the scan, so skip the per-frame terrain
    -- sampling when they're off.
    if not cfg.showRegionLines then return end
    if not world.doGroundScan or world.terrainScannedThisFrame or not world.haveMM then return end
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
    if cfg.writeDiag then world.callsGameView = world.callsGameView + 1 end
    if not (world.viewproj and world.haveMM) then return end

    local prx, prz = world.playerRegion()

    -- grey out everything except the hand-picked "unlocked" chunks, per-pixel
    -- by reconstructed world position (no placement height needed). Skipped
    -- entirely outside the overworld (e.g. dungeons).
    if cfg.greyLocked and chunks.isOverworld(prx, prz) then
        drawGreyReconstruct(event, prx, prz)
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

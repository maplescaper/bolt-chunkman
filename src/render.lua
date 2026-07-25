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
local GROUND_MAX_SAMPLES = config.GROUND_MAX_SAMPLES

local M = {}

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

-- ---- region boundary grid: per-pixel by reconstructed world position ----
-- Same method as the grey-out: one full-screen pass whose fragment shader
-- reconstructs each pixel's world position from the depth buffer and paints it
-- where it lies within the line thickness of a region boundary. The lines
-- therefore hug the terrain exactly (climbing over hills, following dips)
-- instead of sitting on a flat plane at a guessed height, and they are
-- inherently depth-correct with no geometry to build or clip. The current
-- region's border is painted in its own colour by the shader.
local function drawRegionGrid(event, prx, prz)
    local grid = shaders.grid
    if not grid or cfg.lineOpacity <= 0 then return end
    local inv = invViewproj()
    if not inv then return end

    local sw, sh = bolt.gamewindowsize()
    local r = cfg.regionRadius
    local gc, cc, a = cfg.regionColour, cfg.currentRegionColour, cfg.lineOpacity
    grid:setuniform4f(1, gc.r, gc.g, gc.b, a)
    grid:setuniform4f(2, cc.r, cc.g, cc.b, a)
    grid:setuniformmatrix4f(3, false, unpack(inv))
    grid:setuniformdepthbuffer(7, event)
    grid:setuniformmatrix4f(8, false, world.viewproj:get())
    -- grid window in region coords, mirroring the old geometry's extent:
    -- boundaries rx in [prx-r, prx+r+1] over the same span of z, and vice versa
    grid:setuniform4f(12, prx - r, prz - r, prx + r + 1, prz + r + 1)
    grid:setuniform2f(13, prx, prz)
    -- half thickness in px, plus the black-outline ring width (0 disables it;
    -- 1px each side matches the old outline pass's thickness+2)
    grid:setuniform2f(14, cfg.lineThickness / 2, cfg.blackOutline and 1 or 0)
    grid:setuniform2f(15, sw, sh)
    grid:drawtogameview(event, shaders.fillBuffer, 6)
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
    -- the grey-out and the region grid reconstruct height per-pixel and never
    -- read world.groundY; only click-picking (input.lua) still needs a plane
    -- height, so the terrain scan only runs when that height isn't pinned.
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

    -- region boundary lines (orange grid + cyan current region), painted by the
    -- same per-pixel reconstruction pass as the grey-out (no placement height)
    if cfg.showRegionLines then
        drawRegionGrid(event, prx, prz)
    end
end

return M

-- Chunk Man Plugin
-- Draws region / map-square outlines (64x64 tile grid) on the ground and greys
-- out the world beyond the chunks you've unlocked, for RuneScape 3 via the Bolt
-- plugin engine.
--
-- This file is the entry point: it installs a small module loader, wires up the
-- bolt event callbacks, and runs the per-frame loop. The actual work lives in
-- src/:
--   util     - pure helpers (deepcopy, colour<->hex, JSON encode, matrix inverse)
--   config   - constants, default settings, the settings-UI schema, overworld boxes
--   settings - the live config, (de)serialisation, persistence, per-character files
--   chunks   - the unlocked-chunk set and overworld detection
--   world    - shared per-frame state (camera, player pos, ground, window) + helpers
--   shaders  - the line / fill / grey GPU shader programs
--   render   - the draw passes and the render callbacks
--   ui       - the embedded browsers (gear icon, settings panel, readout, popup)
--   input    - ctrl+alt+middle-click to (un)lock a chunk
--   tasks/   - the Chunk Picker tasks panel (reads the picker's Firebase map)
--
-- The line shader (resources/lineshader.*) and its vertex buffer are vendored
-- verbatim from JasperSurmont's bolt-questhelper (AGPL).

local bolt = require("bolt")
bolt.checkversion(1, 0)

-- ---- local module loader ----
-- Bolt gives plugins only bolt.loadfile (read a plugin file into a string) and
-- no require() for files shipped with the plugin. So we read, compile and cache
-- each module ourselves, and override the global require so the modules below can
-- pull in their siblings with a plain require "name" (mapping to src/name.lua).
-- Each module returns a (non-nil) table. The dependency graph is kept acyclic,
-- since a module is cached only after it finishes loading.
do
    local loadCode = load or loadstring
    local builtinRequire = require
    local cache = { bolt = bolt }
    require = function(name)
        local m = cache[name]
        if m then return m end
        local path = "src/" .. tostring(name):gsub("%.", "/") .. ".lua"
        local src = bolt.loadfile(path)
        if not src then return builtinRequire(name) end   -- not local; defer to bolt
        local chunk = assert(loadCode(src, "@" .. path))
        m = chunk()
        assert(m ~= nil, path .. " must return a table")
        cache[name] = m
        return m
    end
end

local config   = require("config")
local settings = require("settings")
local chunks   = require("chunks")
local world    = require("world")
local shaders  = require("shaders")
local render   = require("render")
local ui       = require("ui")
local input    = require("input")

print("[chunk-man] loaded")

-- ---- startup ----
settings.loadSettings()
chunks.rebuildGreyChunks()
ui.init()

-- ---- bolt event wiring ----
bolt.onminimapterrain(function(event)
    local x, z = event:position()
    if x then world.mmX, world.mmZ, world.haveMM = x, z, true end
end)

bolt.onrender3d(render.onRender3d)
bolt.onrendergameview(render.onRenderGameView)

bolt.onmousebutton(input.onMouseButton)

-- ---- per-frame loop ----
local UNITS_PER_TILE        = config.UNITS_PER_TILE
local TILES_PER_REGION      = config.TILES_PER_REGION
local GROUND_REFRESH_FRAMES = config.GROUND_REFRESH_FRAMES
local snap = 0

bolt.onswapbuffers(function(event)
    -- Once a character is logged in, switch to that character's settings file and
    -- (re)load it, so settings are kept per-account instead of shared.
    if settings.resolveSettingsFile() then
        settings.resetDefaults()
        settings.loadSettings()
        chunks.rebuildGreyChunks()
        -- the always-on UI was created at startup with the pre-login scale;
        -- rebuild it so the character's saved uiScale takes effect
        ui.createIconBrowser()
        ui.createReadoutBrowser()
        ui.refreshPanelValues()
    end

    -- open any UI deferred out of a browser message callback (avoids a freeze)
    ui.pump()

    world.frameCount = world.frameCount + 1
    world.doGroundScan = (world.frameCount % GROUND_REFRESH_FRAMES == 0)
    world.terrainScannedThisFrame = false
    world.haveVPThisFrame = false

    -- keep the window size fresh every frame so centred popups land correctly
    -- even if onrendergameview hasn't run recently
    local okw, w, h = pcall(bolt.gamewindowsize)
    if okw and w and w > 0 and h and h > 0 then world.lastWinW, world.lastWinH = w, h end

    -- update the chunk ID badge (cheap: only sends when the value changes)
    if world.haveMM then
        local prx, prz = world.playerRegion()
        ui.pushChunkReadout(prx, prz)
    else
        ui.pushChunkReadout(nil, nil)
    end

    if settings.cfg.writeDiag then
        snap = snap + 1
        if snap % 100 == 0 then
            local haveMM = world.haveMM
            local ptx = haveMM and math.floor(world.mmX / UNITS_PER_TILE)
            local ptz = haveMM and math.floor(world.mmZ / UNITS_PER_TILE)
            bolt.saveconfig("diag.txt", table.concat({
                "shader_ok=" .. tostring(shaders.line ~= nil),
                "player_tile=" .. (haveMM and string.format("%d,%d", ptx, ptz) or "nil"),
                "player_region=" .. (haveMM and string.format("%d,%d", math.floor(ptx / TILES_PER_REGION), math.floor(ptz / TILES_PER_REGION)) or "nil"),
                "overworld=" .. (haveMM and tostring(chunks.isOverworld(math.floor(ptx / TILES_PER_REGION), math.floor(ptz / TILES_PER_REGION))) or "nil"),
                "ground_y=" .. (world.haveGroundY and string.format("%.0f", world.groundY) or "nil"),
                "win_size=" .. string.format("%d,%d", world.lastWinW or 0, world.lastWinH or 0),
                "last_popup=" .. ui.lastPopupGeom,
            }, "\n") .. "\n")
        end
    end
end)

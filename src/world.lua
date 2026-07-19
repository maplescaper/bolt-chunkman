-- Shared per-frame world state and the helpers derived from it. The render
-- callbacks write these fields each frame (camera matrix, player ground
-- position from the minimap, detected ground height, window size); the
-- renderer, input picking and the frame loop read them. Kept in one table so
-- those concerns don't have to reach into each other.
--
-- Read/write through this module table (e.g. world.viewproj), since the fields
-- are reassigned every frame.

local bolt     = require("bolt")
local settings = require("settings")
local config   = require("config")

local cfg             = settings.cfg
local UNITS_PER_TILE  = config.UNITS_PER_TILE
local TILES_PER_REGION = config.TILES_PER_REGION

local M = {}

M.viewproj = nil
M.haveVPThisFrame = false

M.mmX, M.mmZ, M.haveMM = 0, 0, false           -- player ground pos from the minimap
M.groundY, M.haveGroundY = 0, false            -- detected terrain height under the player

M.frameCount = 0
M.doGroundScan = true
M.terrainScannedThisFrame = false

-- diagnostic counters, only advanced while cfg.writeDiag is on: how often each
-- render hook fires, and the largest non-animated 3D pass seen. These tell
-- "hook never fires" apart from "hook fires but no pass ever qualifies".
M.calls3d, M.callsNonAnim, M.callsGameView = 0, 0, 0
M.maxVertexCount = 0

M.lastWinW, M.lastWinH = 0, 0                  -- most recent game window size (for centering popups)

-- placement height for the flat overlays: pinned, or the detected ground
function M.gridHeight()
    if cfg.useFixedHeight then return cfg.fixedHeight end
    if M.haveGroundY then return M.groundY end
    return nil
end

-- is a world-units point in front of the camera (and thus drawable)?
function M.inFront(x, y, z)
    local _, _, sd = bolt.point(x, y, z):transform(M.viewproj):aspixels()
    return sd and sd >= 0.0 and sd <= 1.0
end

-- the region (rx, rz) the player currently stands in, from the minimap position
function M.playerRegion()
    local ptx = math.floor(M.mmX / UNITS_PER_TILE)
    local ptz = math.floor(M.mmZ / UNITS_PER_TILE)
    return math.floor(ptx / TILES_PER_REGION), math.floor(ptz / TILES_PER_REGION)
end

return M

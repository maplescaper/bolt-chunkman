-- Ctrl+Alt+middle-click to (un)lock the chunk under the cursor. Resolves the
-- clicked screen pixel to a ground point, finds the region it lies in, and
-- toggles that chunk in/out of the unlocked list. main.lua registers the bolt
-- mouse callback and forwards it to onMouseButton.

local bolt     = require("bolt")
local config   = require("config")
local settings = require("settings")
local world    = require("world")
local chunks   = require("chunks")
local ui       = require("ui")

local cfg              = settings.cfg
local UNITS_PER_TILE   = config.UNITS_PER_TILE
local TILES_PER_REGION = config.TILES_PER_REGION
local CHUNKS_PER_AXIS  = config.CHUNKS_PER_AXIS

local M = {}

-- Toggle a chunk in/out of the unlocked list. The canonical store is the
-- unlockedChunkIds string; we rebuild it from the current set with the one
-- change, persist, refresh the parsed cache, and update the panel if it's open.
local function applyChunkToggle(rx, rz)
    local key = rx .. "," .. rz
    local remove = chunks.keepSet[key] and true or false
    local ids = {}
    for _, rg in ipairs(chunks.keepRegions) do
        if not (rg.rx == rx and rg.rz == rz) then
            ids[#ids + 1] = rg.rx * CHUNKS_PER_AXIS + rg.rz
        end
    end
    if not remove then ids[#ids + 1] = rx * CHUNKS_PER_AXIS + rz end
    table.sort(ids)
    for i, v in ipairs(ids) do ids[i] = tostring(v) end
    cfg.unlockedChunkIds = table.concat(ids, ", ")
    chunks.rebuildGreyChunks()
    settings.saveSettings()
    ui.refreshPanelValues()
    -- celebrate a newly unlocked chunk (not when locking one back up)
    if not remove and cfg.showUnlockPopup then
        ui.showCongrats(rx, rz, rx * CHUNKS_PER_AXIS + rz)
    end
end

-- Find the world ground point (X,Z) on the overlay plane (height y) that the
-- screen pixel (mx,my) points at. Quad-containment picking can't see the chunk
-- you're standing in since the camera sits inside its huge footprint, so a corner
-- falls behind the camera and the quad is rejected. Instead we solve directly:
-- ground->screen on a flat plane is a smooth projective map, so Newton's method
-- (seeded under the player) converges in a few iterations. Returns nil if it
-- doesn't land on the click (e.g. the pixel is above the horizon / not ground).
local function project(wx, y, wz)
    return bolt.point(wx, y, wz):transform(world.viewproj):toscreen()
end

local function groundPointAtScreen(mx, my, y)
    local X, Z = world.mmX, world.mmZ   -- seed: the ground under the player
    local eps = 64                      -- finite-difference step (world units)
    for _ = 1, 16 do
        local sx, sy, sd = project(X, y, Z)
        if not sx then return nil end
        local fx, fz = sx - mx, sy - my
        if fx * fx + fz * fz < 1.0 then return X, Z end   -- within ~1px
        -- numerical 2x2 Jacobian of (screenx,screeny) w.r.t. (X,Z)
        local sxX, syX = project(X + eps, y, Z)
        local sxZ, syZ = project(X, y, Z + eps)
        if not (sxX and sxZ) then return nil end
        local a, b = (sxX - sx) / eps, (sxZ - sx) / eps
        local c, d = (syX - sy) / eps, (syZ - sy) / eps
        local det = a * d - b * c
        if math.abs(det) < 1e-9 then return nil end
        X = X - ( d * fx - b * fz) / det
        Z = Z - (-c * fx + a * fz) / det
    end
    -- accept only if the final point really projects onto the click, in front
    local sx, sy, sd = project(X, y, Z)
    if sx and (sx - mx) ^ 2 + (sy - my) ^ 2 < 9.0 and sd and sd >= 0.0 and sd <= 1.0 then
        return X, Z
    end
    return nil
end

local PICK_MAX_REGIONS = 16   -- ignore clicks that resolve absurdly far away

function M.onMouseButton(event)
    if not cfg.clickUnlock then return end
    if event:button() ~= 3 then return end          -- middle button only
    if not (event:ctrl() and event:alt()) then return end
    if not (world.viewproj and world.haveMM) then return end
    local y = world.gridHeight()
    if not y then return end

    local mx, my = event:xy()
    local wx, wz = groundPointAtScreen(mx, my, y)
    if not wx then return end

    local rx = math.floor(math.floor(wx / UNITS_PER_TILE) / TILES_PER_REGION)
    local rz = math.floor(math.floor(wz / UNITS_PER_TILE) / TILES_PER_REGION)
    local prx, prz = world.playerRegion()
    if math.abs(rx - prx) > PICK_MAX_REGIONS or math.abs(rz - prz) > PICK_MAX_REGIONS then return end
    applyChunkToggle(rx, rz)
end

return M

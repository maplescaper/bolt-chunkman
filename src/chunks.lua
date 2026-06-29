-- Chunk / region domain logic. A chunk ID is regionX*256 + regionZ, so it
-- decodes to a region X/Z. This module turns the user's comma-separated
-- "unlocked chunk IDs" string into fast lookup structures for the renderer, and
-- answers "is this region in the overworld?".
--
-- Consumers should read keepRegions / keepSet / keepIds through this module
-- table (e.g. chunks.keepSet[key]); rebuildGreyChunks replaces them.

local settings = require("settings")
local config   = require("config")

local cfg              = settings.cfg
local CHUNKS_PER_AXIS  = config.CHUNKS_PER_AXIS

local M = {}

-- Parsed cache of the chunk-ID list, turned into region coordinates so the
-- render loop never has to parse the string. These are the "unlocked" chunks
-- that stay visible; everything else is greyed. keepRegions is the list;
-- keepSet is an "rx,rz" -> true lookup for the frontier test; keepIds is a flat
-- list of unlocked chunk IDs (for the grey shader). Rebuilt whenever the setting
-- changes (after load, reset, or a panel edit).
M.keepRegions = {}
M.keepSet = {}
M.keepIds = {}

-- Cache for nearestKeepIds: the subset uploaded to the grey shader, plus the
-- player region it was computed for. Invalidated (nearPrx = nil) whenever the
-- unlocked set is rebuilt.
M.nearIds = {}
local nearPrx, nearPrz

function M.rebuildGreyChunks()
    local list, set, ids = {}, {}, {}
    for tok in tostring(cfg.unlockedChunkIds):gmatch("[^,%s]+") do
        local id = tonumber(tok)
        if id and id >= 0 then
            id = math.floor(id)
            local rx, rz = math.floor(id / CHUNKS_PER_AXIS), id % CHUNKS_PER_AXIS
            local key = rx .. "," .. rz
            if not set[key] then
                set[key] = true
                list[#list + 1] = { rx = rx, rz = rz }
                ids[#ids + 1] = rx * CHUNKS_PER_AXIS + rz
            end
        end
    end
    M.keepRegions, M.keepSet, M.keepIds = list, set, ids
    nearPrx = nil
end

-- The grey shader's uniform array holds a bounded number of chunk ids and runs a
-- per-pixel loop over them, so the keep list can't be uploaded unbounded. But
-- only chunks near the camera can ever appear on screen, so when there are more
-- unlocked chunks than fit we upload the maxN *nearest* the player rather than an
-- arbitrary first-N (which could drop a chunk right next to us while keeping far
-- ones that are never visible). The result is recomputed only when the player's
-- region or the unlocked set changes.
function M.nearestKeepIds(prx, prz, maxN)
    if #M.keepIds <= maxN then return M.keepIds end
    if prx == nearPrx and prz == nearPrz then return M.nearIds end
    local order = {}
    for i = 1, #M.keepRegions do
        local rg = M.keepRegions[i]
        local dx, dz = rg.rx - prx, rg.rz - prz
        order[i] = { id = M.keepIds[i], d = dx * dx + dz * dz }
    end
    table.sort(order, function(a, b) return a.d < b.d end)
    local near = {}
    for i = 1, maxN do near[i] = order[i].id end
    M.nearIds, nearPrx, nearPrz = near, prx, prz
    return near
end

-- True if region (prx, prz) falls inside the box whose opposite corners are the
-- two given chunk IDs.
local function regionInBox(prx, prz, lo, hi)
    local rxA, rzA = math.floor(lo / CHUNKS_PER_AXIS), lo % CHUNKS_PER_AXIS
    local rxB, rzB = math.floor(hi / CHUNKS_PER_AXIS), hi % CHUNKS_PER_AXIS
    if rxA > rxB then rxA, rxB = rxB, rxA end
    if rzA > rzB then rzA, rzB = rzB, rzA end
    return prx >= rxA and prx <= rxB and prz >= rzA and prz <= rzB
end

-- Convert a Chunk Picker chunk ID to the Bolt chunk ID. Most IDs already agree
-- between the two; a few regions (Arc Islands, Anachronia, Havenhythe, Lost
-- Grove) sit at a constant offset in the picker. config.REGION_REMAP lists each
-- as { pickerSW, pickerNE, offset }: decode the picker ID to a region, and if it
-- falls inside one of those boxes, add that box's offset. The box test is 2D
-- (regionInBox) on purpose.
function M.pickerToBolt(id)
    local prx, prz = math.floor(id / CHUNKS_PER_AXIS), id % CHUNKS_PER_AXIS
    for _, r in ipairs(config.REGION_REMAP) do
        if regionInBox(prx, prz, r[1], r[2]) then
            return id + r[3]
        end
    end
    return id
end

-- Is the player currently in the overworld? The overworld is made up of one or
-- more rectangular boxes of regions, each defined by two opposite-corner chunk
-- IDs. The primary box comes from the configured corners; additional boxes are
-- listed in config.EXTRA_OVERWORLD_BOXES. A region is in the overworld when it
-- falls inside any of these boxes; dungeons, instances and other off-map areas
-- fall outside them all.
function M.isOverworld(prx, prz)
    if not cfg.overworldDetection then return true end
    if regionInBox(prx, prz, cfg.overworldMinChunkId, cfg.overworldMaxChunkId) then
        return true
    end
    for _, box in ipairs(config.EXTRA_OVERWORLD_BOXES) do
        if regionInBox(prx, prz, box[1], box[2]) then return true end
    end
    return false
end

return M

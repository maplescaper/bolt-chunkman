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

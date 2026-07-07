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
-- list of unlocked chunk IDs (used to paint the grey shader's keep texture).
-- Rebuilt whenever the setting changes (after load, reset, or a panel edit); the
-- table is replaced wholesale, so its identity doubles as a "did it change?" flag.
M.keepRegions = {}
M.keepSet = {}
M.keepIds = {}

-- "rx,rz" -> true for the picker's current roll candidates (locked chunks that
-- could be rolled next), synced from the Chunk Picker. Purely cosmetic: the
-- world map paints these green instead of grey. Rebuilt with the sets above.
M.rollableSet = {}

-- "rx,rz" -> { rx, rz, type, color } for the picker's stickers ("id:type:#rrggbb"
-- triples in cfg.stickerData, chunk IDs already remapped to Bolt IDs). The
-- world map draws a marker in the sticker's colour on each. Rebuilt with the
-- sets above.
M.stickerMap = {}

-- "rx,rz" -> array of { type, color } (plus rx/rz fields on the array itself)
-- for stickers added locally through the world map's ctrl+click editor
-- (cfg.localStickerData, same triple format but a chunk id may repeat). Drawn
-- stacked below the chunk's picker sticker. Rebuilt with the sets above.
M.localStickers = {}

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

    local roll = {}
    for tok in tostring(cfg.rollableChunkIds or ""):gmatch("[^,%s]+") do
        local id = tonumber(tok)
        if id and id >= 0 then
            id = math.floor(id)
            roll[math.floor(id / CHUNKS_PER_AXIS) .. "," .. (id % CHUNKS_PER_AXIS)] = true
        end
    end
    M.rollableSet = roll

    local stick = {}
    for tok, typ, col in tostring(cfg.stickerData or ""):gmatch("(%d+):([%w%-_]*):(#%x%x%x%x%x%x)") do
        local id = tonumber(tok)
        if id and id >= 0 then
            local rx, rz = math.floor(id / CHUNKS_PER_AXIS), id % CHUNKS_PER_AXIS
            stick[rx .. "," .. rz] = { rx = rx, rz = rz, type = typ, color = col }
        end
    end
    M.stickerMap = stick

    local loc = {}
    for tok, typ, col in tostring(cfg.localStickerData or ""):gmatch("(%d+):([%w%-_]*):(#%x%x%x%x%x%x)") do
        local id = tonumber(tok)
        if id and id >= 0 then
            local rx, rz = math.floor(id / CHUNKS_PER_AXIS), id % CHUNKS_PER_AXIS
            local key = rx .. "," .. rz
            local l = loc[key]
            if not l then
                l = { rx = rx, rz = rz }
                loc[key] = l
            end
            l[#l + 1] = { type = typ, color = col }
        end
    end
    M.localStickers = loc
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

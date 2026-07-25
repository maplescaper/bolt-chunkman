-- Static configuration: fixed world constants, factory-default settings, the
-- settings-UI schema, and the overworld region boxes. Pure data with no state
-- and no bolt API. `settings.lua` holds the live, editable copy of the defaults.

local M = {}

-- ============================ Fixed constants =========================
M.UNITS_PER_TILE = 512
M.TILES_PER_REGION = 64
M.CHUNKS_PER_AXIS = 256       -- chunk ID = regionX * 256 + regionZ
M.GREY_GRID_RADIUS = 4        -- pixel-perfect grey-out only covers a (2r+1)x(2r+1) grid of regions centered on the player (4 => 9x9); chunks further out are left untouched
M.GROUND_REFRESH_FRAMES = 30
M.GROUND_MAX_SAMPLES = 200
M.LEGACY_SETTINGS_FILE = "chunkman-settings.cfg"  -- old shared (all-account) file; migrated per-character on first load

-- ====================== Adjustable settings (defaults) =================
-- The factory values, used for "Reset" and as the base each character's saved
-- file is applied on top of. `settings.cfg` is the live working copy.
M.DEFAULTS = {
    -- grey out the whole world EXCEPT a hand-picked list of "unlocked" chunks
    greyLocked = true,                                 -- grey everything but the unlocked chunks listed below
    greySky = true,                                    -- also grey the sky (belongs to no unlocked chunk)
    overworldDetection = true,                         -- master switch: detect the overworld at all (off => treat everywhere as overworld)
    overworldMinChunkId = 6950,                        -- one corner of the overworld region box (SW)
    overworldMaxChunkId = 15424,                       -- opposite corner of the overworld region box (NE)
    unlockedChunkIds = "",                             -- comma-separated unlocked chunk IDs, e.g. "13108, 13109"
    rollableChunkIds = "",                             -- comma-separated roll-candidate chunk IDs, synced from the Chunk Picker (not hand-edited)
    stickerData = "",                                  -- comma-separated "id:type:#rrggbb" sticker triples, synced from the Chunk Picker (not hand-edited)
    localStickerData = "",                             -- comma-separated "id:type:#rrggbb" triples added locally via ctrl+click on the world map (may repeat a chunk id)
    clickUnlock = true,                                -- ctrl+alt+middle-click a chunk to toggle it
    showPopups = true,                                 -- master toggle for all celebration popups (chunk unlocked/complete, task complete)
    lockedColour = { r = 0, g = 0, b = 0, a = 0.75 },  -- grey-out colour + opacity

    -- region boundary lines
    showRegionLines = false,                           -- draw the region boundary grid
    regionRadius = 1,                                  -- regions out from yours (1 => 3x3)
    regionColour = { r = 1, g = 0.4, b = 0 },          -- orange region edges
    currentRegionColour = { r = 0, g = 1, b = 1 },     -- cyan: the region you're in
    lineThickness = 3,
    lineOpacity = 1.0,                                 -- 0 = invisible, 1 = solid (outline fades with it)
    terrainOnly = false,                               -- skip lines on steep surfaces (walls, trees); flat roofs still count as terrain
    terrainMaxSlope = 45,                              -- degrees from horizontal a surface may tilt and still get lines
    blackOutline = true,                               -- dark underlay for contrast

    -- placement: the ground-plane height used by ctrl+alt+middle-click chunk
    -- picking (the grey-out and region grid are per-pixel and need no height):
    -- pinned to a fixed value, else use the detected ground under the player
    useFixedHeight = true,
    fixedHeight = 0,                                   -- world units Y

    -- chunk ID readout
    showChunkId = true,                                -- show the current chunk ID badge

    -- world map (in-game world map overlay, via the vendored worldmap library)
    mapGreyLocked = true,                              -- grey out locked chunks on the world map
    mapNoticeShown = false,                            -- one-time "new feature" notice already shown

    -- interface
    uiScale = 1.0,                                     -- scale factor for the on-screen UI (icon, badge, panel, popup)
    panelHeight = 560,                                 -- settings panel height (base/unscaled units; drag its bottom edge)
    tasksHeight = 560,                                 -- tasks panel height (base/unscaled units; drag its bottom edge)
    iconX = 10,                                        -- gear icon top-left X (screen px; drag the icon to move it)
    iconY = 10,                                        -- gear icon top-left Y (screen px; drag the icon to move it)

    -- chunk picker integration (https://source-chunk.github.io/chunk-picker-rs3)
    chunkPickerMapId = "",                             -- your chunk-picker map id (the "?<id>" in your picker URL, e.g. "vel")
    resolveTaskNames = true,                           -- fetch tasksMap.json to show task names (off => raw t_<id> codes)

    -- diagnostics
    writeDiag = false,                                 -- periodically write diag.txt (off by default: it's a disk write every ~100 frames)
}

-- Schema: single source of truth for the settings UI. The panel form is built
-- from this (sent to the browser as JSON), and persistence/parsing keys off it.
-- type: "bool" | "int" | "float" | "text" | "rgb" | "rgba"
M.SCHEMA = {
    { key = "greyLocked",          type = "bool",  group = "Unlocked Chunks",    label = "Grey out locked chunks" },
    { key = "greySky",             type = "bool",  group = "Unlocked Chunks",    label = "Grey out the sky" },
    { key = "overworldDetection",  type = "bool",  group = "Unlocked Chunks",    label = "Enable overworld detection" },
    { key = "overworldMinChunkId", type = "int",   group = "Unlocked Chunks",    label = "Overworld box corner chunk ID (SW)", min = 0, max = 65535, step = 1 },
    { key = "overworldMaxChunkId", type = "int",   group = "Unlocked Chunks",    label = "Overworld box corner chunk ID (NE)", min = 0, max = 65535, step = 1 },
    { key = "unlockedChunkIds",    type = "text",  group = "Unlocked Chunks",    label = "Unlocked chunk IDs", placeholder = "e.g. 13108, 13109" },
    -- hidden: synced from the Chunk Picker's roll-candidate list, not hand-edited
    { key = "rollableChunkIds",    type = "text",  group = "Unlocked Chunks",    label = "Rollable chunk IDs", hidden = true },
    -- hidden: synced from the Chunk Picker's sticker layer, not hand-edited
    { key = "stickerData",         type = "text",  group = "Unlocked Chunks",    label = "Sticker data", hidden = true },
    -- hidden: stickers added locally through the world-map ctrl+click editor
    { key = "localStickerData",    type = "text",  group = "Unlocked Chunks",    label = "Local sticker data", hidden = true },
    { key = "clickUnlock",         type = "bool",  group = "Unlocked Chunks",    label = "Ctrl+Alt+middle-click to unlock/lock a chunk" },
    { key = "lockedColour",        type = "rgba",  group = "Unlocked Chunks",    label = "Locked-chunk colour & opacity" },

    -- editor = "external": typed in a real OS window, because Bolt's in-game
    -- (embedded) overlay browsers receive mouse events only, never keyboard.
    { key = "chunkPickerMapId",    type = "text",  group = "Chunk Picker",       label = "Chunk Picker map ID", placeholder = "e.g. vel", editor = "external" },
    { key = "resolveTaskNames",    type = "bool",  group = "Chunk Picker",       label = "Resolve task names (downloads task list)" },

    { key = "showRegionLines",     type = "bool",  group = "Region grid lines",  label = "Show region boundary lines" },
    { key = "regionRadius",        type = "int",   group = "Region grid lines",  label = "Region radius (rings out)", min = 0, max = 5, step = 1 },
    { key = "regionColour",        type = "rgb",   group = "Region grid lines",  label = "Grid line colour" },
    { key = "currentRegionColour", type = "rgb",   group = "Region grid lines",  label = "Current-region colour" },
    { key = "lineThickness",       type = "float", group = "Region grid lines",  label = "Line thickness", min = 1, max = 12, step = 0.5 },
    { key = "lineOpacity",         type = "float", group = "Region grid lines",  label = "Line opacity", min = 0, max = 1, step = 0.05 },
    { key = "terrainOnly",         type = "bool",  group = "Region grid lines",  label = "Terrain only (skip walls and objects)" },
    { key = "terrainMaxSlope",     type = "int",   group = "Region grid lines",  label = "Terrain max slope (degrees)", min = 5, max = 85, step = 5 },
    { key = "blackOutline",        type = "bool",  group = "Region grid lines",  label = "Black outline for contrast" },

    { key = "useFixedHeight",      type = "bool",  group = "Placement",          label = "Pin click-picking to a fixed height" },
    { key = "fixedHeight",         type = "int",   group = "Placement",          label = "Fixed height (world Y)", min = -5000, max = 10000, step = 50 },

    { key = "showChunkId",         type = "bool",  group = "Chunk ID readout",   label = "Show current chunk ID" },

    { key = "mapGreyLocked",       type = "bool",  group = "World Map",          label = "Grey out locked chunks on the world map" },
    -- hidden: set true after the one-time world-map notice popup has been shown
    { key = "mapNoticeShown",      type = "bool",  group = "World Map",          label = "World-map notice shown", hidden = true },

    { key = "uiScale",             type = "float", group = "Interface",          label = "UI scale", min = 0.5, max = 3, step = 0.1 },
    { key = "showPopups",          type = "bool",  group = "Interface",          label = "Show popups" },
    -- hidden: persisted UI state, set by dragging each panel's bottom edge (not shown as a form row)
    { key = "panelHeight",         type = "int",   group = "Interface",          label = "Settings panel height", hidden = true, min = 220, max = 1400, step = 1 },
    { key = "tasksHeight",         type = "int",   group = "Interface",          label = "Tasks panel height",    hidden = true, min = 220, max = 1400, step = 1 },
    { key = "iconX",               type = "int",   group = "Interface",          label = "Gear icon X", hidden = true, min = 0, max = 10000, step = 1 },
    { key = "iconY",               type = "int",   group = "Interface",          label = "Gear icon Y", hidden = true, min = 0, max = 10000, step = 1 },

    { key = "writeDiag",           type = "bool",  group = "Diagnostics",        label = "Write diag.txt" },
}

M.SCHEMA_BY_KEY = {}
for _, e in ipairs(M.SCHEMA) do M.SCHEMA_BY_KEY[e.key] = e end

-- Additional overworld region boxes beyond the configured primary one. Each
-- entry is a { SW chunk ID, NE chunk ID } pair (same encoding: regionX*256 +
-- regionZ). Some overworld areas sit outside the main box, so they're listed
-- here so the locked-chunk grey-out still applies there.
M.EXTRA_OVERWORLD_BOXES = {
    { 5206, 5721 },
    { 7085, 10427 },
    { 20512, 22824 },
    { 13332, 14876 },
}

-- Chunk Picker -> Bolt chunk-ID remap. The picker stores a handful of regions at
-- a different ID offset than Bolt; everywhere else the two agree. Each entry is
-- { pickerSW, pickerNE, offset }: opposite-corner chunk IDs of the region's box
-- *in picker IDs*, plus the value to ADD to a picker ID inside that box to get
-- the Bolt ID. The membership test is 2D (see chunks.pickerToBolt). The Arc
-- Islands and Anachronia picker ranges overlap as plain number ranges but not as
-- region boxes, so a scalar lo<=id<=hi test would misclassify them.
M.REGION_REMAP = {
    { 14870, 18212, -7785 },   -- Arc Islands
    { 14655, 16967,  5857 },   -- Anachronia
    { 16176, 17720, -2844 },   -- Havenhythe
    {  7471,  7986, -2265 },   -- Lost Grove
}

return M

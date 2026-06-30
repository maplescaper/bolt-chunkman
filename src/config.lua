-- Static configuration: fixed world constants, factory-default settings, the
-- settings-UI schema, and the overworld region boxes. Pure data -- no state, no
-- bolt API. `settings.lua` holds the live, editable copy of the defaults.

local M = {}

-- ============================ Fixed constants =========================
M.UNITS_PER_TILE = 512
M.TILES_PER_REGION = 64
M.CHUNKS_PER_AXIS = 256       -- chunk ID = regionX * 256 + regionZ
M.GRID_STEP_TILES = 8         -- boundary subdivision (for clipping behind camera)
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
    reconstructGrey = true,                            -- true: per-pixel depth-reconstruction grey-out; false: original curtain walls
    greySky = true,                                    -- mode A: also grey the sky (belongs to no unlocked chunk)
    overworldDetection = true,                         -- master switch: detect the overworld at all (off => treat everywhere as overworld)
    overworldMinChunkId = 6950,                        -- one corner of the overworld region box (SW)
    overworldMaxChunkId = 15424,                       -- opposite corner of the overworld region box (NE)
    unlockedChunkIds = "",                             -- comma-separated unlocked chunk IDs, e.g. "13108, 13109"
    clickUnlock = true,                                -- ctrl+alt+middle-click a chunk to toggle it
    showPopups = true,                                 -- master toggle for all celebration popups (chunk unlocked/complete, task complete)
    dimLockedView = true,                              -- dim the whole view while standing in a locked chunk
    lockedColour = { r = 0, g = 0, b = 0, a = 0.75 },  -- curtain colour + opacity
    lockedWallHeight = 60000,                          -- world units the curtains rise toward the sky

    -- region boundary lines
    showRegionLines = false,                           -- draw the region boundary grid
    regionRadius = 1,                                  -- regions out from yours (1 => 3x3)
    regionColour = { r = 1, g = 0.4, b = 0 },          -- orange region edges
    currentRegionColour = { r = 0, g = 1, b = 1 },     -- cyan: the region you're in
    lineThickness = 3,
    blackOutline = true,                               -- dark underlay for contrast

    -- placement: pin the overlay to a fixed height, else use detected ground
    useFixedHeight = true,
    fixedHeight = 0,                                   -- world units Y

    -- chunk ID readout
    showChunkId = true,                                -- show the current chunk ID badge

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
    { key = "reconstructGrey",     type = "bool",  group = "Unlocked Chunks",    label = "Pixel-perfect grey-out (off = curtain walls)" },
    { key = "greySky",             type = "bool",  group = "Unlocked Chunks",    label = "Grey out the sky (pixel-perfect mode)" },
    { key = "overworldDetection",  type = "bool",  group = "Unlocked Chunks",    label = "Enable overworld detection" },
    { key = "overworldMinChunkId", type = "int",   group = "Unlocked Chunks",    label = "Overworld box corner chunk ID (SW)", min = 0, max = 65535, step = 1 },
    { key = "overworldMaxChunkId", type = "int",   group = "Unlocked Chunks",    label = "Overworld box corner chunk ID (NE)", min = 0, max = 65535, step = 1 },
    { key = "unlockedChunkIds",    type = "text",  group = "Unlocked Chunks",    label = "Unlocked chunk IDs", placeholder = "e.g. 13108, 13109" },
    { key = "clickUnlock",         type = "bool",  group = "Unlocked Chunks",    label = "Ctrl+Alt+middle-click to unlock/lock a chunk" },
    { key = "dimLockedView",       type = "bool",  group = "Unlocked Chunks",    label = "Dim the view when in a locked chunk" },
    { key = "lockedColour",        type = "rgba",  group = "Unlocked Chunks",    label = "Locked-chunk colour & opacity" },
    { key = "lockedWallHeight",    type = "int",   group = "Unlocked Chunks",    label = "Locked-chunk wall height (world units)", min = 1000, max = 200000, step = 1000 },

    -- editor = "external": typed in a real OS window, because Bolt's in-game
    -- (embedded) overlay browsers receive mouse events only, never keyboard.
    { key = "chunkPickerMapId",    type = "text",  group = "Chunk Picker",       label = "Chunk Picker map ID", placeholder = "e.g. vel", editor = "external" },
    { key = "resolveTaskNames",    type = "bool",  group = "Chunk Picker",       label = "Resolve task names (downloads task list)" },

    { key = "showRegionLines",     type = "bool",  group = "Region grid lines",  label = "Show region boundary lines" },
    { key = "regionRadius",        type = "int",   group = "Region grid lines",  label = "Region radius (rings out)", min = 0, max = 5, step = 1 },
    { key = "regionColour",        type = "rgb",   group = "Region grid lines",  label = "Grid line colour" },
    { key = "currentRegionColour", type = "rgb",   group = "Region grid lines",  label = "Current-region colour" },
    { key = "lineThickness",       type = "float", group = "Region grid lines",  label = "Line thickness", min = 1, max = 12, step = 0.5 },
    { key = "blackOutline",        type = "bool",  group = "Region grid lines",  label = "Black outline for contrast" },

    { key = "useFixedHeight",      type = "bool",  group = "Placement",          label = "Pin overlay to a fixed height" },
    { key = "fixedHeight",         type = "int",   group = "Placement",          label = "Fixed height (world Y)", min = -5000, max = 10000, step = 50 },

    { key = "showChunkId",         type = "bool",  group = "Chunk ID readout",   label = "Show current chunk ID" },

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

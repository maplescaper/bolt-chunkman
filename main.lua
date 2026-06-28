-- Chunk Man Plugin
-- Draws region / map-square outlines (64x64 tile grid) on the ground at a
-- single flat height, and greys out the world beyond the region you're in.
--
-- Region edges are deterministic: a region is 64x64 tiles anchored at absolute
-- tile 0, so region edges are every tile coordinate divisible by 64.
--
-- Lines are drawn on the GPU with a line shader: each boundary segment is one
-- shader draw (via drawtogameview), instead of thousands of per-pixel
-- drawtoscreen calls. The shader projects the segment with the camera viewproj
-- matrix, expands it to the requested thickness in screen space, and darkens
-- the parts occluded by terrain (using the game view's depth buffer).
--
-- The line shader (lineshader.vert/frag) and its vertex buffer are vendored
-- verbatim from JasperSurmont's bolt-questhelper (AGPL).
--
-- Settings are adjustable in-game: a gear icon at the top-left of the screen
-- opens a settings panel (an embedded browser, ui/panel.html). Changes apply
-- live and are persisted to the plugin config dir (chunkman-settings.cfg).

local bolt = require("bolt")
bolt.checkversion(1, 0)
print("[chunk-man] loaded")

-- ============================ Fixed constants =========================
local UNITS_PER_TILE = 512
local TILES_PER_REGION = 64
local CHUNKS_PER_AXIS = 256       -- chunk ID = regionX * 256 + regionZ
local GRID_STEP_TILES = 8        -- boundary subdivision (for clipping behind camera)
local GROUND_REFRESH_FRAMES = 30
local GROUND_MAX_SAMPLES = 200
local LEGACY_SETTINGS_FILE = "chunkman-settings.cfg"  -- old shared (all-account) file; migrated per-character on first load
-- The active settings file. Resolved per-character (see resolveSettingsFile);
-- until a character is known it points at the legacy shared file.
local SETTINGS_FILE = LEGACY_SETTINGS_FILE
-- ======================================================================

-- ====================== Adjustable settings (defaults) =================
-- These are the live, user-editable settings. DEFAULTS holds the factory
-- values (for "Reset"); cfg is the working copy that the renderer reads.
local DEFAULTS = {
    -- grey out the whole world EXCEPT a hand-picked list of "unlocked" chunks
    greyLocked = true,                                 -- grey everything but the unlocked chunks listed below
    overworldDetection = true,                         -- master switch: detect the overworld at all (off => treat everywhere as overworld)
    overworldMinChunkId = 6950,                        -- one corner of the overworld region box (SW)
    overworldMaxChunkId = 15424,                       -- opposite corner of the overworld region box (NE)
    unlockedChunkIds = "",                             -- comma-separated unlocked chunk IDs, e.g. "13108, 13109"
    clickUnlock = true,                                -- ctrl+alt+middle-click a chunk to toggle it
    showUnlockPopup = true,                            -- show the "chunk unlocked" congratulations popup
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

    -- diagnostics
    writeDiag = true,                                  -- periodically write diag.txt
}

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = deepcopy(v) end
    return r
end

local cfg = deepcopy(DEFAULTS)

-- Schema: single source of truth for the settings UI. The panel form is built
-- from this (sent to the browser as JSON), and persistence/parsing keys off it.
-- type: "bool" | "int" | "float" | "rgb" | "rgba"
local SCHEMA = {
    { key = "greyLocked",          type = "bool",  group = "Unlocked Chunks",    label = "Grey out locked chunks" },
    { key = "overworldDetection",  type = "bool",  group = "Unlocked Chunks",    label = "Enable overworld detection" },
    { key = "overworldMinChunkId", type = "int",   group = "Unlocked Chunks",    label = "Overworld box corner chunk ID (SW)", min = 0, max = 65535, step = 1 },
    { key = "overworldMaxChunkId", type = "int",   group = "Unlocked Chunks",    label = "Overworld box corner chunk ID (NE)", min = 0, max = 65535, step = 1 },
    { key = "unlockedChunkIds",    type = "text",  group = "Unlocked Chunks",    label = "Unlocked chunk IDs", placeholder = "e.g. 13108, 13109" },
    { key = "clickUnlock",         type = "bool",  group = "Unlocked Chunks",    label = "Ctrl+Alt+middle-click to unlock/lock a chunk" },
    { key = "showUnlockPopup",     type = "bool",  group = "Unlocked Chunks",    label = "Show the \"chunk unlocked\" popup" },
    { key = "dimLockedView",       type = "bool",  group = "Unlocked Chunks",    label = "Dim the view when in a locked chunk" },
    { key = "lockedColour",        type = "rgba",  group = "Unlocked Chunks",    label = "Locked-chunk colour & opacity" },
    { key = "lockedWallHeight",    type = "int",   group = "Unlocked Chunks",    label = "Locked-chunk wall height (world units)", min = 1000, max = 200000, step = 1000 },

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

    { key = "writeDiag",           type = "bool",  group = "Diagnostics",        label = "Write diag.txt" },
}
local SCHEMA_BY_KEY = {}
for _, e in ipairs(SCHEMA) do SCHEMA_BY_KEY[e.key] = e end

-- ---- colour <-> hex helpers ----
local function clampChannel(x)
    local n = math.floor(x * 255 + 0.5)
    if n < 0 then n = 0 elseif n > 255 then n = 255 end
    return n
end
local function rgbToHex(c)
    return string.format("#%02x%02x%02x", clampChannel(c.r), clampChannel(c.g), clampChannel(c.b))
end
local function hexToRgb(hex)
    -- accepts "#rrggbb"
    local r = (tonumber(hex:sub(2, 3), 16) or 0) / 255
    local g = (tonumber(hex:sub(4, 5), 16) or 0) / 255
    local b = (tonumber(hex:sub(6, 7), 16) or 0) / 255
    return r, g, b
end

-- ---- minimal JSON encoder (encode only; the browser does the decoding) ----
local function jsonString(s)
    local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
    s = s:gsub('[%z\1-\31\\"]', function(c)
        return map[c] or string.format('\\u%04x', string.byte(c))
    end)
    return '"' .. s .. '"'
end
local function jsonEncode(v)
    local t = type(v)
    if t == "nil" then return "null"
    elseif t == "boolean" then return tostring(v)
    elseif t == "number" then return tostring(v)
    elseif t == "string" then return jsonString(v)
    elseif t == "table" then
        local n = 0
        for _ in pairs(v) do n = n + 1 end
        if n == #v then -- array (also handles empty -> [])
            local parts = {}
            for i = 1, #v do parts[i] = jsonEncode(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local parts = {}
        for k, val in pairs(v) do
            parts[#parts + 1] = jsonString(tostring(k)) .. ":" .. jsonEncode(val)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

-- ---- value (de)serialisation, shared by persistence and the browser bridge --
local function round(x) return math.floor(x + 0.5) end

-- the string form of a setting's value (used for saving to disk)
local function valueString(e)
    local k, t = e.key, e.type
    if t == "bool" then
        return cfg[k] and "true" or "false"
    elseif t == "int" or t == "float" then
        return tostring(cfg[k])
    elseif t == "text" then
        return tostring(cfg[k])
    elseif t == "rgb" then
        return rgbToHex(cfg[k])
    elseif t == "rgba" then
        return rgbToHex(cfg[k]) .. "," .. tostring(cfg[k].a)
    end
    return ""
end

-- apply a value (given as a string) to cfg, dispatching on the schema type
local function applySet(key, valueStr)
    local e = SCHEMA_BY_KEY[key]
    if not e then return false end
    local t = e.type
    if t == "bool" then
        cfg[key] = (valueStr == "true")
    elseif t == "int" then
        local n = tonumber(valueStr); if n then cfg[key] = round(n) end
    elseif t == "float" then
        local n = tonumber(valueStr); if n then cfg[key] = n end
    elseif t == "text" then
        cfg[key] = valueStr or ""
    elseif t == "rgb" then
        local r, g, b = hexToRgb(valueStr)
        cfg[key] = { r = r, g = g, b = b }
    elseif t == "rgba" then
        local hex, a = valueStr:match("^([^,]+),(.+)$")
        if hex then
            local r, g, b = hexToRgb(hex)
            cfg[key] = { r = r, g = g, b = b, a = tonumber(a) or 1 }
        end
    end
    return true
end

-- the value of a setting in the shape the browser form expects (for JSON)
local function valueForBrowser(e)
    local k, t = e.key, e.type
    if t == "bool" then
        return cfg[k] and true or false
    elseif t == "int" or t == "float" then
        return cfg[k]
    elseif t == "text" then
        return cfg[k]
    elseif t == "rgb" then
        return rgbToHex(cfg[k])
    elseif t == "rgba" then
        return { c = rgbToHex(cfg[k]), a = cfg[k].a }
    end
end
local function valuesPayload()
    local vals = {}
    for _, e in ipairs(SCHEMA) do vals[e.key] = valueForBrowser(e) end
    return vals
end

-- ---- persistence ----
local function saveSettings()
    local out = {}
    for _, e in ipairs(SCHEMA) do
        out[#out + 1] = e.key .. "=" .. valueString(e)
    end
    bolt.saveconfig(SETTINGS_FILE, table.concat(out, "\n") .. "\n")
end
-- legacy config keys -> current keys, so older saved files still load. The
-- old write (greyOutside) was dropped; the rest were renamed to lock/unlock.
local LEGACY_KEYS = {
    greyChunks   = "greyLocked",
    greyChunkIds = "unlockedChunkIds",
    greyColour   = "lockedColour",
    greyWallHeight = "lockedWallHeight",
}
local function applySettingsData(data)
    if not data then return false end
    for line in data:gmatch("[^\r\n]+") do
        local k, v = line:match("^([^=]+)=(.*)$")
        if k then applySet(LEGACY_KEYS[k] or k, v) end
    end
    return true
end
local function loadSettings()
    -- Per-character file first; if the character has none yet, seed (migrate)
    -- from the old shared file so existing setups carry over. From then on each
    -- character saves to its own file, so settings no longer leak across
    -- accounts.
    if applySettingsData(bolt.loadconfig(SETTINGS_FILE)) then return end
    if SETTINGS_FILE ~= LEGACY_SETTINGS_FILE then
        applySettingsData(bolt.loadconfig(LEGACY_SETTINGS_FILE))
    end
end

-- Resolve SETTINGS_FILE to the current character's file. bolt.characterid() is
-- a stable, unique, alphanumeric id that isn't available until a character is
-- logged in, so this is re-checked each frame until it resolves. Returns true
-- when the active file changed (i.e. caller should (re)load).
local loadedCharId = nil
local function resolveSettingsFile()
    local ok, id = pcall(bolt.characterid)
    if not ok or not id or id == "" then return false end
    id = tostring(id):gsub("[^%w]", "")
    if id == "" or id == loadedCharId then return false end
    loadedCharId = id
    SETTINGS_FILE = "chunkman-settings-" .. id .. ".cfg"
    return true
end
local function resetDefaults()
    cfg = deepcopy(DEFAULTS)
end

-- Parsed cache of the chunk-ID list, turned into region coordinates so the
-- render loop never has to parse the string. These are the "unlocked" chunks
-- that stay visible; everything else is greyed. A chunk ID is regionX*256+
-- regionZ, so regionX = id // 256 and regionZ = id % 256. keepRegions is the
-- list; keepSet is an "rx,rz" -> true lookup for the frontier test. Rebuilt
-- whenever the setting changes (after load, reset, or a panel edit).
local keepRegions = {}
local keepSet = {}
local function rebuildGreyChunks()
    local list, set = {}, {}
    for tok in tostring(cfg.unlockedChunkIds):gmatch("[^,%s]+") do
        local id = tonumber(tok)
        if id and id >= 0 then
            id = math.floor(id)
            local rx, rz = math.floor(id / CHUNKS_PER_AXIS), id % CHUNKS_PER_AXIS
            local key = rx .. "," .. rz
            if not set[key] then
                set[key] = true
                list[#list + 1] = { rx = rx, rz = rz }
            end
        end
    end
    keepRegions, keepSet = list, set
end

-- Additional overworld region boxes beyond the configured primary one. Each
-- entry is a { SW chunk ID, NE chunk ID } pair (same encoding: regionX*256 +
-- regionZ). Some overworld areas sit outside the main box, so they're listed
-- here so the locked-chunk grey-out still applies there.
local EXTRA_OVERWORLD_BOXES = {
    { 5206, 5721 },
    { 7085, 10427 },
    { 20512, 22824 },
    { 13332, 14876 },
}

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
-- IDs (each chunk ID = regionX*256 + regionZ, so it decodes to a region X/Z).
-- The primary box comes from the configured corners; additional boxes are listed
-- in EXTRA_OVERWORLD_BOXES. A region is in the overworld when it falls inside any
-- of these boxes; dungeons, instances and other off-map areas fall outside them
-- all. While outside, we suppress the locked-chunk grey-out entirely, so nothing
-- is greyed in a dungeon. With the gate disabled, locks apply everywhere (the
-- previous behaviour).
local function isOverworld(prx, prz)
    if not cfg.overworldDetection then return true end
    if regionInBox(prx, prz, cfg.overworldMinChunkId, cfg.overworldMaxChunkId) then
        return true
    end
    for _, box in ipairs(EXTRA_OVERWORLD_BOXES) do
        if regionInBox(prx, prz, box[1], box[2]) then return true end
    end
    return false
end

loadSettings()
rebuildGreyChunks()

-- ============================ Settings UI =============================
-- A gear icon (small embedded browser, ui/icon.html) sits at the top-left.
-- Clicking it toggles the settings panel (ui/panel.html). The panel is built
-- dynamically from SCHEMA and talks back over the bolt-api message bridge.
-- Base (unscaled) layout. All sizes/offsets are multiplied by cfg.uiScale so the
-- whole interface can be made bigger or smaller from the settings panel.
local UI_MARGIN = 10
local ICON_BASE = 44
local READOUT_BASE_W = 150
local PANEL_BASE_W, PANEL_BASE_H = 360, 560

local function uiScale()
    local s = tonumber(cfg.uiScale) or 1
    if s < 0.1 then s = 0.1 end
    return s
end

-- plugin page URL carrying the current UI scale, so each embedded page can zoom
-- its content to fill the (scaled) browser rectangle Lua sizes for it.
local function pageUrl(path)
    return string.format("plugin://ui/%s?s=%s", path, tostring(uiScale()))
end

-- forward declarations: the panel's message handler (re)builds these when the
-- scale changes, but they're defined further down.
local iconBrowser, panelBrowser, readoutBrowser
local createIconBrowser, createReadoutBrowser

local function closePanel()
    if panelBrowser then
        panelBrowser:close()
        panelBrowser = nil
    end
end

local function onPanelMessage(msg)
    if msg == "ready" then
        if panelBrowser then
            panelBrowser:sendmessage(jsonEncode({
                type = "init", schema = SCHEMA, values = valuesPayload(),
            }))
        end
    elseif msg == "reset" then
        resetDefaults()
        rebuildGreyChunks()
        saveSettings()
        createIconBrowser()
        createReadoutBrowser()
        if panelBrowser then
            panelBrowser:sendmessage(jsonEncode({ type = "values", values = valuesPayload() }))
        end
    else
        local key, val = msg:match("^set\n([^\n]*)\n(.*)$")
        if key then
            applySet(key, val)
            if key == "unlockedChunkIds" then rebuildGreyChunks() end
            -- rescale the always-on UI immediately; the open panel keeps its
            -- current size and picks up the new scale next time it's opened.
            if key == "uiScale" then
                createIconBrowser()
                createReadoutBrowser()
            end
            saveSettings()
        end
    end
end

local function openPanel()
    if panelBrowser then return end
    local s = uiScale()
    local px = UI_MARGIN
    local py = UI_MARGIN + math.floor(ICON_BASE * s) + 8
    local pw = math.floor(PANEL_BASE_W * s)
    local ph = math.floor(PANEL_BASE_H * s)
    local ok, b = pcall(bolt.createembeddedbrowser, px, py, pw, ph, pageUrl("panel.html"))
    if not ok or not b then
        print("[chunk-man] could not open settings panel: " .. tostring(b))
        return
    end
    panelBrowser = b
    panelBrowser:onmessage(onPanelMessage)
    panelBrowser:oncloserequest(closePanel)
end

local function togglePanel()
    if panelBrowser then closePanel() else openPanel() end
end

-- (re)create the gear icon at the current UI scale
function createIconBrowser()
    if iconBrowser then iconBrowser:close(); iconBrowser = nil end
    local sz = math.floor(ICON_BASE * uiScale())
    local ok, err = pcall(function()
        iconBrowser = bolt.createembeddedbrowser(UI_MARGIN, UI_MARGIN, sz, sz, pageUrl("icon.html"))
        iconBrowser:onmessage(function(msg)
            if msg == "toggle" then togglePanel() end
        end)
    end)
    if not ok then print("[chunk-man] settings icon init failed: " .. tostring(err)) end
end
createIconBrowser()

-- ---- chunk ID readout (small badge to the right of the gear icon) ----
-- The chunk ID is the RuneScape region id: regionX * 256 + regionZ. It is shown
-- in a tiny always-present embedded browser whose text the Lua side pushes
-- whenever the player's chunk (or the show/hide setting) changes.
local lastReadout = nil   -- last payload string pushed, to avoid redundant sends

-- (re)create the badge at the current UI scale, to the right of the gear icon
function createReadoutBrowser()
    if readoutBrowser then readoutBrowser:close(); readoutBrowser = nil end
    local s = uiScale()
    local rx = UI_MARGIN + math.floor(ICON_BASE * s) + 6
    local rw = math.floor(READOUT_BASE_W * s)
    local rh = math.floor(ICON_BASE * s)
    local ok, err = pcall(function()
        readoutBrowser = bolt.createembeddedbrowser(rx, UI_MARGIN, rw, rh, pageUrl("readout.html"))
    end)
    if not ok then print("[chunk-man] chunk readout init failed: " .. tostring(err)) end
    if readoutBrowser then
        lastReadout = nil   -- new page; re-push state once it reports "ready"
        readoutBrowser:onmessage(function(msg)
            if msg == "ready" then lastReadout = nil end
        end)
    end
end
createReadoutBrowser()

local function pushChunkReadout(prx, prz)
    if not readoutBrowser then return end
    local payload
    if cfg.showChunkId and prx then
        local chunkId = prx * 256 + prz
        payload = jsonEncode({ type = "chunk", id = chunkId, rx = prx, rz = prz, show = true })
    else
        payload = jsonEncode({ type = "chunk", show = false })
    end
    if payload ~= lastReadout then
        lastReadout = payload
        readoutBrowser:sendmessage(payload)
    end
end
-- ======================================================================

-- ---- "chunk unlocked" congratulations popup ----
-- A big, temporary card shown at the centre of the game view when a chunk is
-- newly unlocked. It's an on-demand embedded browser (ui/congrats.html): we
-- create it centred on the current window, push the chunk info, and the page
-- plays its animation then asks us to close it again via oncloserequest.
local CONGRATS_BASE_W, CONGRATS_BASE_H = 460, 230
local congratsBrowser

local function closeCongrats()
    if congratsBrowser then
        congratsBrowser:close()
        congratsBrowser = nil
    end
end

local lastCongratsGeom = "none"   -- diagnostics: last popup window/size/pos

local function showCongrats(rx, rz, chunkId)
    closeCongrats()   -- replace any popup still on screen
    local s = uiScale()
    local cw = math.floor(CONGRATS_BASE_W * s)
    local ch = math.floor(CONGRATS_BASE_H * s)
    -- prefer a fresh read of the window size; fall back to the cached value
    local okw, w, h = pcall(bolt.gamewindowsize)
    local sw = (okw and w and w > 0) and w or ((lastWinW and lastWinW > 0) and lastWinW or 1280)
    local sh = (okw and h and h > 0) and h or ((lastWinH and lastWinH > 0) and lastWinH or 720)
    local x = math.floor((sw - cw) / 2)
    -- horizontally centred, but raised toward the top quarter of the screen
    local y = math.floor(sh * 0.18)
    lastCongratsGeom = string.format("win=%dx%d size=%dx%d pos=%d,%d", sw, sh, cw, ch, x, y)
    local ok, b = pcall(bolt.createembeddedbrowser, x, y, cw, ch, pageUrl("congrats.html"))
    if not ok or not b then
        print("[chunk-man] could not open congrats popup: " .. tostring(b))
        return
    end
    congratsBrowser = b
    local payload = jsonEncode({ type = "congrats", id = chunkId, rx = rx, rz = rz })
    congratsBrowser:onmessage(function(msg)
        if msg == "ready" and congratsBrowser then congratsBrowser:sendmessage(payload) end
    end)
    congratsBrowser:oncloserequest(closeCongrats)
end
-- ======================================================================

-- ---- line shader ----
local shader, lineBuffer
do
    local ok, err = pcall(function()
        local vs = bolt.createvertexshader(bolt.loadfile("resources/lineshader.vert"))
        local fs = bolt.createfragmentshader(bolt.loadfile("resources/lineshader.frag"))
        shader = bolt.createshaderprogram(vs, fs)
        shader:setattribute(0, 1, true, false, 2, 0, 2)
        lineBuffer = bolt.createshaderbuffer("\xFF\x00\x01\x00\x01\x01\xFF\x00\x01\x01\xFF\x01")
    end)
    if not ok then print("[chunk-man] shader init failed: " .. tostring(err)) end
end

-- ---- fill shader (greys out surrounding regions) ----
local fillShader, fillBuffer
do
    local ok, err = pcall(function()
        local vs = bolt.createvertexshader(bolt.loadfile("resources/fillshader.vert"))
        local fs = bolt.createfragmentshader(bolt.loadfile("resources/fillshader.frag"))
        fillShader = bolt.createshaderprogram(vs, fs)
        fillShader:setattribute(0, 1, true, false, 2, 0, 2)
        -- unit-square corners: two triangles (0,0)(1,0)(1,1) and (0,0)(1,1)(0,1)
        fillBuffer = bolt.createshaderbuffer("\x00\x00\x01\x00\x01\x01\x00\x00\x01\x01\x00\x01")
    end)
    if not ok then print("[chunk-man] fill shader init failed: " .. tostring(err)) end
end

-- ---- state ----
local viewproj = nil
local lastWinW, lastWinH = 0, 0   -- most recent game window size (for centering popups)
local mmX, mmZ, haveMM = 0, 0, false
local groundY, haveGroundY = 0, false
local frameCount, doGroundScan, terrainScannedThisFrame = 0, true, false
local haveVPThisFrame = false

bolt.onminimapterrain(function(event)
    local x, z = event:position()
    if x then mmX, mmZ, haveMM = x, z, true end
end)

bolt.onrender3d(function(event)
    -- Capture the camera matrix from the LAST 3D pass each frame (matches the
    -- bolt-questhelper convention). The first pass of a frame is an early /
    -- off-screen render with a different matrix, so using it makes world
    -- overlays drift as the camera moves. Last-write-wins gives the matrix that
    -- matches the game view that's actually composited this frame.
    viewproj = event:viewprojmatrix()
    haveVPThisFrame = true

    if cfg.useFixedHeight then return end
    if not doGroundScan or terrainScannedThisFrame or not haveMM then return end
    if event:animated() then return end
    local vc = event:vertexcount()
    if vc < 1000 then return end
    terrainScannedThisFrame = true

    local mm = event:modelmatrix()
    local step = math.max(8, math.floor(vc / GROUND_MAX_SAMPLES))
    local bestD, bestY = math.huge, nil
    for i = 1, vc, step do
        local wx, wy, wz = event:vertexpoint(i):transform(mm):get()
        local d = math.abs(wx - mmX) + math.abs(wz - mmZ)
        if d < bestD then bestD, bestY = d, wy end
    end
    if bestY then groundY, haveGroundY = bestY, true end
end)

local function gridHeight()
    if cfg.useFixedHeight then return cfg.fixedHeight end
    if haveGroundY then return groundY end
    return nil
end

-- is a world-units point in front of the camera (and thus drawable)?
local function inFront(x, y, z)
    local _, _, sd = bolt.point(x, y, z):transform(viewproj):aspixels()
    return sd and sd >= 0.0 and sd <= 1.0
end

-- add a world-space segment to the list if both ends are in front of the camera
local function addSeg(lines, x0, y, z0, x1, z1, col)
    if inFront(x0, y, z0) and inFront(x1, y, z1) then
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

-- ---- GPU grey-out: vertical curtains along chunk frontiers ----
-- The shared uniforms (camera, height range, colour, depth) are set once per
-- frame via beginWalls; drawWallSeg then raises a single curtain along one
-- ground edge. drawGreyChunks uses these to wall off the frontier of the
-- unlocked area.
local function beginWalls(event, y)
    local sw, sh = bolt.gamewindowsize()
    fillShader:setuniformmatrix4f(3, false, viewproj:get())
    fillShader:setuniform2f(2, y, y + cfg.lockedWallHeight)
    fillShader:setuniform4f(4, cfg.lockedColour.r, cfg.lockedColour.g, cfg.lockedColour.b, cfg.lockedColour.a)
    fillShader:setuniformdepthbuffer(5, event)
    fillShader:setuniform2f(6, sw, sh)
end

-- one curtain along a ground base-line {x0,z0 -> x1,z1}, raised by the shader
local function drawWallSeg(event, x0, z0, x1, z1)
    fillShader:setuniform4f(1, x0, z0, x1, z1)
    fillShader:drawtogameview(event, fillBuffer, 6)
end

-- grey out the whole world EXCEPT the listed chunks: the listed chunks are the
-- "unlocked" ones. We wall off only the frontier -- each edge of an unlocked
-- chunk that borders a chunk NOT in the list. Edges shared by two unlocked
-- chunks stay open, so a contiguous unlocked area is fully clear inside and
-- curtained at its perimeter. If nothing is unlocked there are no frontiers and
-- this draws nothing -- the whole-view dim (below) covers that case instead.
local function drawGreyChunks(event, y)
    if not fillShader or #keepRegions == 0 then return end
    beginWalls(event, y)
    local U = UNITS_PER_TILE * TILES_PER_REGION
    for _, rg in ipairs(keepRegions) do
        local rx, rz = rg.rx, rg.rz
        local x0, z0 = rx * U, rz * U
        local x1, z1 = x0 + U, z0 + U
        if not keepSet[(rx - 1) .. "," .. rz] then drawWallSeg(event, x0, z1, x0, z0) end  -- min-x frontier
        if not keepSet[(rx + 1) .. "," .. rz] then drawWallSeg(event, x1, z0, x1, z1) end  -- max-x frontier
        if not keepSet[rx .. "," .. (rz - 1)] then drawWallSeg(event, x0, z0, x1, z0) end  -- min-z frontier
        if not keepSet[rx .. "," .. (rz + 1)] then drawWallSeg(event, x1, z1, x0, z1) end  -- max-z frontier
    end
end

-- ---- full-screen dim (when standing in a locked chunk) ----
-- Reuses the curtain fill shader to paint one screen-filling quad. We feed it
-- an identity matrix and place the quad at the near plane (NDC z = -1) so its
-- depth-occlusion test can never discard, and so the whole game view is tinted
-- by uColor with the shader's normal alpha blend (black + alpha => darken).
local function drawLockedViewDim(event)
    if not fillShader then return end
    local sw, sh = bolt.gamewindowsize()
    fillShader:setuniformmatrix4f(3, false, 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1)
    fillShader:setuniform4f(1, -1, -1, 1, -1)   -- uBase: x spans -1..1, z fixed at -1 (near)
    fillShader:setuniform2f(2, -1, 1)           -- uYrange: y spans -1..1
    fillShader:setuniform4f(4, cfg.lockedColour.r, cfg.lockedColour.g, cfg.lockedColour.b, cfg.lockedColour.a)
    fillShader:setuniformdepthbuffer(5, event)
    fillShader:setuniform2f(6, sw, sh)
    fillShader:drawtogameview(event, fillBuffer, 6)
end

-- ---- GPU line batch ----
local function drawLines(event, lines)
    if not shader or #lines == 0 then return end
    local sw, sh = bolt.gamewindowsize()
    shader:setuniformmatrix4f(3, false, viewproj:get())
    shader:setuniform2f(6, sw, sh)
    shader:setuniform1f(10, 0)
    shader:setuniform1f(11, 0)   -- no pulses
    shader:setuniform1f(12, 0)
    shader:setuniform1f(13, 0)   -- no rainbow
    shader:setuniformdepthbuffer(14, event)
    shader:setuniform2f(15, sw, sh)
    shader:setuniform1f(16, 0)   -- no rounded caps

    local function batch(extra, forceBlack)
        for _, ln in ipairs(lines) do
            local th = cfg.lineThickness + extra
            shader:setuniform3f(1, ln.x0, ln.y0, ln.z0)
            shader:setuniform3f(2, ln.x1, ln.y1, ln.z1)
            shader:setuniform1f(4, th / 2.0)
            shader:setuniform1f(9, th / 2.0)
            if forceBlack then
                shader:setuniform4f(5, 0, 0, 0, 0.6)
            else
                shader:setuniform4f(5, ln.r, ln.g, ln.b, ln.a)
            end
            shader:setuniform1f(7, 0)
            shader:setuniform1f(8, 1)
            shader:drawtogameview(event, lineBuffer, 6)
        end
    end

    if cfg.blackOutline then batch(2, true) end
    batch(0, false)
end

bolt.onrendergameview(function(event)
    lastWinW, lastWinH = bolt.gamewindowsize()
    local y = gridHeight()
    if not (viewproj and haveMM and y) then return end

    local ptx = math.floor(mmX / UNITS_PER_TILE)
    local ptz = math.floor(mmZ / UNITS_PER_TILE)
    local prx = math.floor(ptx / TILES_PER_REGION)
    local prz = math.floor(ptz / TILES_PER_REGION)

    local txMin = (prx - cfg.regionRadius) * TILES_PER_REGION
    local txMax = (prx + cfg.regionRadius + 1) * TILES_PER_REGION
    local tzMin = (prz - cfg.regionRadius) * TILES_PER_REGION
    local tzMax = (prz + cfg.regionRadius + 1) * TILES_PER_REGION

    -- grey out everything except the hand-picked "unlocked" chunks, as vertical
    -- curtains (drawn first, so the boundary lines render on top). Skipped
    -- entirely when outside the overworld (e.g. dungeons), so nothing is greyed.
    if cfg.greyLocked and isOverworld(prx, prz) then
        drawGreyChunks(event, y)
        -- if you're standing in a locked chunk, dim the entire camera view. With
        -- nothing unlocked, every chunk is locked, so this dims the world.
        if cfg.dimLockedView and not keepSet[prx .. "," .. prz] then
            drawLockedViewDim(event)
        end
    end

    -- region boundary lines (orange grid + cyan current region)
    if cfg.showRegionLines then
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
end)

-- ===================== Ctrl+Alt+middle-click to (un)lock a chunk ============
-- Toggle a chunk in/out of the unlocked list. The canonical store is the
-- unlockedChunkIds string; we rebuild it from the current set with the one change,
-- persist, refresh the parsed cache, and update the panel if it's open.
local function applyChunkToggle(rx, rz)
    local key = rx .. "," .. rz
    local remove = keepSet[key] and true or false
    local ids = {}
    for _, rg in ipairs(keepRegions) do
        if not (rg.rx == rx and rg.rz == rz) then
            ids[#ids + 1] = rg.rx * CHUNKS_PER_AXIS + rg.rz
        end
    end
    if not remove then ids[#ids + 1] = rx * CHUNKS_PER_AXIS + rz end
    table.sort(ids)
    for i, v in ipairs(ids) do ids[i] = tostring(v) end
    cfg.unlockedChunkIds = table.concat(ids, ", ")
    rebuildGreyChunks()
    saveSettings()
    if panelBrowser then
        panelBrowser:sendmessage(jsonEncode({ type = "values", values = valuesPayload() }))
    end
    -- celebrate a newly unlocked chunk (not when locking one back up)
    if not remove and cfg.showUnlockPopup then
        showCongrats(rx, rz, rx * CHUNKS_PER_AXIS + rz)
    end
end

-- Find the world ground point (X,Z) on the overlay plane (height y) that the
-- screen pixel (mx,my) points at. Quad-containment picking can't see the chunk
-- you're standing in -- the camera sits inside its huge footprint, so a corner
-- falls behind the camera and the quad is rejected. Instead we solve directly:
-- ground->screen on a flat plane is a smooth projective map, so Newton's method
-- (seeded under the player) converges in a few iterations. Returns nil if it
-- doesn't land on the click (e.g. the pixel is above the horizon / not ground).
local function project(wx, y, wz)
    return bolt.point(wx, y, wz):transform(viewproj):toscreen()
end
local function groundPointAtScreen(mx, my, y)
    local X, Z = mmX, mmZ          -- seed: the ground under the player
    local eps = 64                 -- finite-difference step (world units)
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

bolt.onmousebutton(function(event)
    if not cfg.clickUnlock then return end
    if event:button() ~= 3 then return end          -- middle button only
    if not (event:ctrl() and event:alt()) then return end
    if not (viewproj and haveMM) then return end
    local y = gridHeight()
    if not y then return end

    local mx, my = event:xy()
    local wx, wz = groundPointAtScreen(mx, my, y)
    if not wx then return end

    local rx = math.floor(math.floor(wx / UNITS_PER_TILE) / TILES_PER_REGION)
    local rz = math.floor(math.floor(wz / UNITS_PER_TILE) / TILES_PER_REGION)
    local prx = math.floor(math.floor(mmX / UNITS_PER_TILE) / TILES_PER_REGION)
    local prz = math.floor(math.floor(mmZ / UNITS_PER_TILE) / TILES_PER_REGION)
    if math.abs(rx - prx) > PICK_MAX_REGIONS or math.abs(rz - prz) > PICK_MAX_REGIONS then return end
    applyChunkToggle(rx, rz)
end)
-- ===========================================================================

local snap = 0
bolt.onswapbuffers(function(event)
    -- Once a character is logged in, switch to that character's settings file and
    -- (re)load it, so settings are kept per-account instead of shared.
    if resolveSettingsFile() then
        resetDefaults()
        loadSettings()
        rebuildGreyChunks()
    end

    frameCount = frameCount + 1
    doGroundScan = (frameCount % GROUND_REFRESH_FRAMES == 0)
    terrainScannedThisFrame = false
    haveVPThisFrame = false

    -- keep the window size fresh every frame so centred popups land correctly
    -- even if onrendergameview hasn't run recently
    local okw, w, h = pcall(bolt.gamewindowsize)
    if okw and w and w > 0 and h and h > 0 then lastWinW, lastWinH = w, h end

    -- update the chunk ID badge (cheap: only sends when the value changes)
    if haveMM then
        local prx = math.floor(math.floor(mmX / UNITS_PER_TILE) / TILES_PER_REGION)
        local prz = math.floor(math.floor(mmZ / UNITS_PER_TILE) / TILES_PER_REGION)
        pushChunkReadout(prx, prz)
    else
        pushChunkReadout(nil, nil)
    end

    if cfg.writeDiag then
        snap = snap + 1
        if snap % 100 == 0 then
            local ptx = haveMM and math.floor(mmX / UNITS_PER_TILE)
            local ptz = haveMM and math.floor(mmZ / UNITS_PER_TILE)
            bolt.saveconfig("diag.txt", table.concat({
                "shader_ok=" .. tostring(shader ~= nil),
                "player_tile=" .. (haveMM and string.format("%d,%d", ptx, ptz) or "nil"),
                "player_region=" .. (haveMM and string.format("%d,%d", math.floor(ptx / 64), math.floor(ptz / 64)) or "nil"),
                "overworld=" .. (haveMM and tostring(isOverworld(math.floor(ptx / 64), math.floor(ptz / 64))) or "nil"),
                "ground_y=" .. (haveGroundY and string.format("%.0f", groundY) or "nil"),
                "win_size=" .. string.format("%d,%d", lastWinW or 0, lastWinH or 0),
                "last_congrats=" .. lastCongratsGeom,
            }, "\n") .. "\n")
        end
    end
end)

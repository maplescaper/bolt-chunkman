-- Chunk Picker tasks panel.
--
-- A separate embedded browser that lists the "active" chunk-man tasks for a map
-- saved in the Chunk Picker tool (https://source-chunk.github.io/chunk-picker-rs3).
-- The picker stores every map in a public Firebase Realtime Database, readable
-- without auth via its REST API, so the page (ui/tasks.html) does the fetching.
-- This module owns the browser's lifecycle (open/close/toggle and rebuilds when
-- the UI scale or map id changes) and the per-character cache: the page asks for
-- the cached data on open and only re-fetches on first use or a manual refresh,
-- handing the fresh result back here to store.
--
-- The map id is the "?<id>" in the user's picker URL (e.g. ".../?vel" -> "vel")
-- and is set in the settings panel (cfg.chunkPickerMapId). It is passed to the
-- page through the page URL, like the rest of the embedded UI passes uiScale.

local bolt     = require("bolt")
local util     = require("util")
local settings = require("settings")
local chunks   = require("chunks")

local cfg = settings.cfg

local M = {}

-- Base (unscaled) layout, mirroring ui.lua so the panel lines up with the
-- existing UI. Everything is multiplied by cfg.uiScale.
local UI_MARGIN = 10
local ICON_BASE = 44
local PANEL_BASE_W = util.PANEL_BASE_W

local tasksBrowser

local function uiScale()
    return util.clampUiScale(cfg.uiScale)
end

-- Per-character cache of the last fetched task data, so the panel opens
-- instantly (and offline) and only hits the network on first use or a manual
-- refresh. The page fetches and resolves the data, then sends it here as a JSON
-- blob; we store it verbatim and hand it straight back next time. (We never
-- parse it -- the page validates that the cached map id / settings still match
-- and re-fetches itself if not.)
local function cacheFile()
    return "chunkman-tasks-" .. (settings.charId or "shared") .. ".json"
end

-- Local per-character check-off overrides (keyed by map id, then task), kept
-- separate from the fetched cache so a refresh never clobbers them. Stored as
-- an opaque JSON blob the page owns; we only persist and hand it back.
local function overridesFile()
    return "chunkman-taskchecks-" .. (settings.charId or "shared") .. ".json"
end

local function blobOrNull(s)
    if s and s ~= "" then return s else return "null" end
end

-- handle messages from the tasks page
local function onTasksMessage(m)
    if m == "ready" then
        if not tasksBrowser then return end
        -- both blobs are themselves JSON, so splice them straight in (no decode)
        local body = '{"type":"cache","blob":' .. blobOrNull(bolt.loadconfig(cacheFile()))
            .. ',"overrides":' .. blobOrNull(bolt.loadconfig(overridesFile())) .. "}"
        tasksBrowser:sendmessage(body)
        return
    end
    local json = m:match("^store\n(.*)$")
    if json then bolt.saveconfig(cacheFile(), json); return end
    local checks = m:match("^checks\n(.*)$")
    if checks then bolt.saveconfig(overridesFile(), checks); return end
    -- The page sends the picker's unlocked chunk IDs (raw picker IDs) after a
    -- fetch. Convert each to its Bolt chunk ID and overwrite the unlocked set,
    -- making the picker the source of truth for what's unlocked.
    local unlocked = m:match("^unlocked\n(.*)$")
    if unlocked then
        local ids = {}
        for tok in unlocked:gmatch("[^,%s]+") do
            local id = tonumber(tok)
            if id and id >= 0 then ids[#ids + 1] = tostring(chunks.pickerToBolt(math.floor(id))) end
        end
        cfg.unlockedChunkIds = table.concat(ids, ",")
        chunks.rebuildGreyChunks()
        settings.saveSettings()
        return
    end
end

-- plugin page URL carrying the UI scale (for zoom), the map id to read, and
-- whether to resolve task ids to names.
local function pageUrl()
    local mid = tostring(cfg.chunkPickerMapId or ""):gsub("[^%w]", "")   -- map ids are alphanumeric
    return string.format("plugin://ui/tasks.html?s=%s&mid=%s&resolve=%s",
        tostring(uiScale()), mid, cfg.resolveTaskNames and "1" or "0")
end

local function closeTasks()
    if tasksBrowser then
        tasksBrowser:close()
        tasksBrowser = nil
    end
end
M.close = closeTasks

function M.open()
    if tasksBrowser then return end
    local s = uiScale()
    -- sit to the right of where the settings panel opens; the page is draggable
    local px = UI_MARGIN + math.floor(PANEL_BASE_W * s) + 16
    local py = UI_MARGIN + math.floor(ICON_BASE * s) + 8
    local pw = math.floor(PANEL_BASE_W * s)
    local ph = math.floor(util.clampPanelHeight(cfg.tasksHeight) * s)
    local ok, b = pcall(bolt.createembeddedbrowser, px, py, pw, ph, pageUrl())
    if not ok or not b then
        print("[chunk-man] could not open tasks panel: " .. tostring(b))
        return
    end
    tasksBrowser = b
    tasksBrowser:onmessage(onTasksMessage)
    tasksBrowser:oncloserequest(closeTasks)
    -- persist the height when the user drags the panel's bottom edge
    tasksBrowser:onreposition(function(event)
        local _, _, _, h = event:xywh()
        if not h or h <= 0 then return end
        local base = util.clampPanelHeight(math.floor(h / uiScale() + 0.5))
        if base ~= cfg.tasksHeight then
            cfg.tasksHeight = base
            settings.saveSettings()
        end
    end)
end

function M.toggle()
    if tasksBrowser then closeTasks() else M.open() end
end

-- Recreate the panel with a fresh URL when something it was built from changed
-- (UI scale, map id, or the resolve-names toggle). No-op when it isn't open.
function M.rebuildIfOpen()
    if tasksBrowser then
        closeTasks()
        M.open()
    end
end

return M

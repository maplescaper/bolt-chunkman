-- The on-screen interface, all embedded browsers (small web pages Bolt renders
-- over the game):
--   * gear icon (ui/icon.html)      -- toggles the settings panel
--   * settings panel (ui/panel.html) -- built from config.SCHEMA, edits apply live
--   * chunk-ID readout (ui/readout.html) -- the current chunk-ID badge
--   * congrats popup (ui/congrats.html)  -- shown when a chunk is newly unlocked
-- Everything is laid out at a base size multiplied by cfg.uiScale, so the whole
-- interface scales from the panel. The panel talks back over the bolt-api
-- message bridge (onPanelMessage).

local bolt     = require("bolt")
local util     = require("util")
local config   = require("config")
local settings = require("settings")
local chunks   = require("chunks")
local world    = require("world")

local cfg        = settings.cfg
local jsonEncode = util.jsonEncode

local M = {}

-- Base (unscaled) layout. All sizes/offsets are multiplied by cfg.uiScale.
local UI_MARGIN = 10
local ICON_BASE = 44
local READOUT_BASE_W = 150
local PANEL_BASE_W, PANEL_BASE_H = 360, 560
local CONGRATS_BASE_W, CONGRATS_BASE_H = 460, 230

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

-- the embedded browsers; (re)built when the scale changes
local iconBrowser, panelBrowser, readoutBrowser, congratsBrowser
-- forward declarations: onPanelMessage rebuilds these when the scale changes
local createIconBrowser, createReadoutBrowser

-- push the current settings values to the open panel (if any)
function M.refreshPanelValues()
    if panelBrowser then
        panelBrowser:sendmessage(jsonEncode({ type = "values", values = settings.valuesPayload() }))
    end
end

-- ---- settings panel ----
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
                type = "init", schema = config.SCHEMA, values = settings.valuesPayload(),
            }))
        end
    elseif msg == "reset" then
        settings.resetDefaults()
        chunks.rebuildGreyChunks()
        settings.saveSettings()
        createIconBrowser()
        createReadoutBrowser()
        M.refreshPanelValues()
    else
        local key, val = msg:match("^set\n([^\n]*)\n(.*)$")
        if key then
            settings.applySet(key, val)
            if key == "unlockedChunkIds" then chunks.rebuildGreyChunks() end
            -- rescale the always-on UI immediately; the open panel keeps its
            -- current size and picks up the new scale next time it's opened.
            if key == "uiScale" then
                createIconBrowser()
                createReadoutBrowser()
            end
            settings.saveSettings()
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

-- ---- gear icon ----
-- (re)create the gear icon at the current UI scale
createIconBrowser = function()
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
M.createIconBrowser = createIconBrowser

-- ---- chunk ID readout (small badge to the right of the gear icon) ----
-- The chunk ID is the RuneScape region id: regionX * 256 + regionZ. It is shown
-- in a tiny always-present embedded browser whose text the Lua side pushes
-- whenever the player's chunk (or the show/hide setting) changes.
local lastReadout = nil   -- last payload string pushed, to avoid redundant sends
local lastRx, lastRz, lastShown   -- badge state the last payload was built from

-- (re)create the badge at the current UI scale, to the right of the gear icon
createReadoutBrowser = function()
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
M.createReadoutBrowser = createReadoutBrowser

function M.pushChunkReadout(prx, prz)
    if not readoutBrowser then return end
    local show = cfg.showChunkId and prx ~= nil
    -- Fast path: the badge only changes when the player crosses a chunk boundary
    -- or the show/hide setting flips, so skip rebuilding the JSON every frame when
    -- nothing changed. lastReadout == nil means a fresh page still needs the state
    -- pushed (set by createReadoutBrowser / the "ready" message), so never skip then.
    if lastReadout then
        if show then
            if prx == lastRx and prz == lastRz and lastShown then return end
        elseif lastShown == false then
            return
        end
    end
    lastRx, lastRz, lastShown = prx, prz, show
    local payload
    if show then
        payload = jsonEncode({ type = "chunk", id = prx * 256 + prz, rx = prx, rz = prz, show = true })
    else
        payload = jsonEncode({ type = "chunk", show = false })
    end
    if payload ~= lastReadout then
        lastReadout = payload
        readoutBrowser:sendmessage(payload)
    end
end

-- ---- "chunk unlocked" congratulations popup ----
-- A big, temporary card shown near the top of the game view when a chunk is
-- newly unlocked. It's an on-demand embedded browser: we create it centred on
-- the current window, push the chunk info, and the page plays its animation then
-- asks us to close it again via oncloserequest.
M.lastCongratsGeom = "none"   -- diagnostics: last popup window/size/pos

local function closeCongrats()
    if congratsBrowser then
        congratsBrowser:close()
        congratsBrowser = nil
    end
end

function M.showCongrats(rx, rz, chunkId)
    closeCongrats()   -- replace any popup still on screen
    local s = uiScale()
    local cw = math.floor(CONGRATS_BASE_W * s)
    local ch = math.floor(CONGRATS_BASE_H * s)
    -- prefer a fresh read of the window size; fall back to the cached value
    local okw, w, h = pcall(bolt.gamewindowsize)
    local sw = (okw and w and w > 0) and w or ((world.lastWinW and world.lastWinW > 0) and world.lastWinW or 1280)
    local sh = (okw and h and h > 0) and h or ((world.lastWinH and world.lastWinH > 0) and world.lastWinH or 720)
    local x = math.floor((sw - cw) / 2)
    -- horizontally centred, but raised toward the top quarter of the screen
    local y = math.floor(sh * 0.18)
    M.lastCongratsGeom = string.format("win=%dx%d size=%dx%d pos=%d,%d", sw, sh, cw, ch, x, y)
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

-- build the always-on UI (gear icon + chunk readout)
function M.init()
    createIconBrowser()
    createReadoutBrowser()
end

return M

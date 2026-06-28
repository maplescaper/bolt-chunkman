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
local tasks    = require("tasks.client")

local cfg        = settings.cfg
local jsonEncode = util.jsonEncode

local M = {}

-- Base (unscaled) layout. All sizes/offsets are multiplied by cfg.uiScale.
local UI_MARGIN = 10
local ICON_BASE = 44
local READOUT_BASE_W = 150
local PANEL_BASE_W = util.PANEL_BASE_W
local CONGRATS_BASE_W, CONGRATS_BASE_H = 460, 230

local function uiScale()
    return util.clampUiScale(cfg.uiScale)
end

-- plugin page URL carrying the current UI scale, so each embedded page can zoom
-- its content to fill the (scaled) browser rectangle Lua sizes for it.
local function pageUrl(path)
    return string.format("plugin://ui/%s?s=%s", path, tostring(uiScale()))
end

-- the embedded browsers; (re)built when the scale changes
local iconBrowser, panelBrowser, readoutBrowser, congratsBrowser
-- a real OS window for text entry (embedded overlays get no keyboard input)
local textEditorBrowser
-- a setting key whose external editor was requested from the panel but must be
-- opened outside that message callback (see M.pump / openTextEditor)
local pendingEdit
-- forward declarations: onPanelMessage rebuilds these when the scale changes
local createIconBrowser, createReadoutBrowser, openTextEditor

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
    elseif msg == "tasks" then
        tasks.toggle()
    elseif msg:match("^editext\n") then
        -- defer: opening the external window here (inside this browser message
        -- callback) hard-freezes the client; M.pump() does it next frame.
        pendingEdit = msg:match("^editext\n(.*)$")
    elseif msg == "reset" then
        settings.resetDefaults()
        chunks.rebuildGreyChunks()
        settings.saveSettings()
        createIconBrowser()
        createReadoutBrowser()
        tasks.rebuildIfOpen()
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
                tasks.rebuildIfOpen()
            end
            -- the tasks page is built from the map id / resolve toggle, so
            -- recreate it (if open) to pick up the change.
            if key == "chunkPickerMapId" or key == "resolveTaskNames" then
                tasks.rebuildIfOpen()
            end
            settings.saveSettings()
        end
    end
end

-- ---- external text editor ----
-- Embedded overlay browsers only receive mouse events, so text settings can't
-- be typed into the in-game panel. Schema entries with editor="external" are
-- edited here instead: a real OS browser window (createbrowser, not the
-- embedded variant) that has keyboard focus. It returns the new value over the
-- same message bridge, which we apply and persist like any other setting.
local function closeTextEditor()
    if textEditorBrowser then
        textEditorBrowser:close()
        textEditorBrowser = nil
    end
end

openTextEditor = function(key)
    local e = config.SCHEMA_BY_KEY[key]
    if not e then return end
    closeTextEditor()
    local s = uiScale()
    local w = math.floor(440 * s)
    local h = math.floor(210 * s)
    local ok, b = pcall(bolt.createbrowser, w, h, pageUrl("textedit.html"))
    if not ok or not b then
        print("[chunk-man] could not open text editor: " .. tostring(b))
        return
    end
    textEditorBrowser = b
    b:onmessage(function(m)
        if m == "ready" then
            b:sendmessage(jsonEncode({
                type = "init", key = key, label = e.label,
                value = tostring(cfg[key] or ""), placeholder = e.placeholder or "",
            }))
        elseif m == "cancel" then
            closeTextEditor()
        else
            local v = m:match("^save\n(.*)$")
            if v ~= nil then
                settings.applySet(key, v)
                if key == "unlockedChunkIds" then chunks.rebuildGreyChunks() end
                if key == "chunkPickerMapId" then tasks.rebuildIfOpen() end
                settings.saveSettings()
                M.refreshPanelValues()
                closeTextEditor()
            end
        end
    end)
    b:oncloserequest(closeTextEditor)
end

-- Service deferred work that must not run inside a browser message callback.
-- Creating the external editor window (createbrowser) from within the settings
-- panel's onmessage handler hard-freezes the client, so that handler only sets
-- pendingEdit and we actually open the window here, called once per frame.
function M.pump()
    if pendingEdit then
        local key = pendingEdit
        pendingEdit = nil
        openTextEditor(key)
    end
end

local function openPanel()
    if panelBrowser then return end
    local s = uiScale()
    local px = UI_MARGIN
    local py = UI_MARGIN + math.floor(ICON_BASE * s) + 8
    local pw = math.floor(PANEL_BASE_W * s)
    local ph = math.floor(util.clampPanelHeight(cfg.panelHeight) * s)
    local ok, b = pcall(bolt.createembeddedbrowser, px, py, pw, ph, pageUrl("panel.html"))
    if not ok or not b then
        print("[chunk-man] could not open settings panel: " .. tostring(b))
        return
    end
    panelBrowser = b
    panelBrowser:onmessage(onPanelMessage)
    panelBrowser:oncloserequest(closePanel)
    -- persist the height when the user drags the panel's bottom edge
    panelBrowser:onreposition(function(event)
        local _, _, _, h = event:xywh()
        if not h or h <= 0 then return end
        local base = util.clampPanelHeight(math.floor(h / uiScale() + 0.5))
        if base ~= cfg.panelHeight then
            cfg.panelHeight = base
            settings.saveSettings()
        end
    end)
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

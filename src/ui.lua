-- The on-screen interface, all embedded browsers (small web pages Bolt renders
-- over the game):
--   * gear icon (ui/icon.html)      -- toggles the settings panel
--   * settings panel (ui/panel.html) -- built from config.SCHEMA, edits apply live
--   * chunk-ID readout (ui/readout.html) -- the current chunk-ID badge
--   * congrats popup (ui/popup.html?p=congrats) -- shown when a chunk is newly unlocked
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
local POPUP_BASE_W, POPUP_BASE_H = 460, 230

local function uiScale()
    return util.clampUiScale(cfg.uiScale)
end

-- plugin page URL carrying the current UI scale, so each embedded page can zoom
-- its content to fill the (scaled) browser rectangle Lua sizes for it.
local function pageUrl(path)
    return string.format("plugin://ui/%s?s=%s", path, tostring(uiScale()))
end

-- the embedded browsers; (re)built when the scale changes
local iconBrowser, panelBrowser, readoutBrowser, popupBrowser
-- a real OS window for text entry (embedded overlays get no keyboard input)
local textEditorBrowser
-- a setting key whose external editor was requested from the panel but must be
-- opened outside that message callback (see M.pump / openTextEditor)
local pendingEdit
-- a deferred "move the chunk-ID badge to follow the dragged icon", serviced by
-- M.pump once the icon's drag has settled (see createIconBrowser / M.pump)
local iconMovePending = false
local pumpIconX, pumpIconY
-- forward declarations: onPanelMessage rebuilds these when the scale changes
local createIconBrowser, createReadoutBrowser, openTextEditor, iconPos

-- push the current settings values to the open panel (if any)
function M.refreshPanelValues()
    if panelBrowser then
        panelBrowser:sendmessage(jsonEncode({ type = "values", values = settings.valuesPayload() }))
    end
end

-- Tell the open settings panel whether the external text editor is currently
-- open, so it can show/hide a warning banner. The editor is a real OS window
-- that can open behind the game (Bolt has no API to foreground it), so the
-- banner points the user to it.
local function notifyEditorOpen(open)
    if panelBrowser then
        panelBrowser:sendmessage(jsonEncode({ type = "editorOpen", open = open }))
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
            -- if the editor is already open, re-show the banner on this (re)opened panel
            if textEditorBrowser then notifyEditorOpen(true) end
        end
    elseif msg == "tasks" then
        -- the tasks panel is useless without a chunk-picker map id, so if none is
        -- set yet, open the text editor to add one instead of opening the panel.
        -- Defer it like editext below: opening the external window inside this
        -- browser message callback hard-freezes the client (M.pump opens it).
        local mid = tostring(cfg.chunkPickerMapId or ""):gsub("[^%w]", "")
        if mid == "" then
            pendingEdit = "chunkPickerMapId"
        else
            tasks.toggle()
        end
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
        -- drop the cached task list before rebuilding so a reopened panel sees an
        -- empty cache and re-fetches (and re-imports the unlocked set)
        tasks.clearCache()
        tasks.rebuildIfOpen()
        M.refreshPanelValues()
    else
        local key, val = msg:match("^set\n([^\n]*)\n(.*)$")
        if key then
            settings.applySet(key, val)
            if key == "unlockedChunkIds" then chunks.rebuildGreyChunks() end
            -- create/destroy the readout browser so it stops capturing clicks
            -- over its area when the badge is turned off (and comes back when on)
            if key == "showChunkId" then createReadoutBrowser() end
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
    notifyEditorOpen(false)
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
    notifyEditorOpen(true)
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
                -- entering a map id opens the tasks panel so its fetch imports
                -- the unlocked chunks; a cleared id just refreshes any open panel
                if key == "chunkPickerMapId" then
                    local mid = tostring(cfg.chunkPickerMapId or ""):gsub("[^%w]", "")
                    if mid ~= "" then tasks.openForCurrentMap() else tasks.rebuildIfOpen() end
                end
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
    -- Move the chunk-ID badge to follow the icon, but only once the icon drag has
    -- settled: while dragging, onreposition keeps changing iconX/iconY each frame,
    -- so we wait for a frame where it didn't change before recreating the badge.
    if iconMovePending then
        if cfg.iconX == pumpIconX and cfg.iconY == pumpIconY then
            iconMovePending = false
            createReadoutBrowser()
        else
            pumpIconX, pumpIconY = cfg.iconX, cfg.iconY
        end
    end
end

local function openPanel()
    if panelBrowser then return end
    local s = uiScale()
    -- open just below the gear icon, wherever it currently sits
    local ix, iy, sz = iconPos()
    local px = ix
    local py = iy + sz + 8
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
-- The gear icon's saved top-left (cfg.iconX/iconY) clamped so it stays fully
-- on-screen, so a position saved at a larger resolution can't strand it offscreen.
iconPos = function()
    local sz = math.floor(ICON_BASE * uiScale())
    local okw, w, h = pcall(bolt.gamewindowsize)
    local sw = (okw and w and w > 0) and w or ((world.lastWinW and world.lastWinW > 0) and world.lastWinW or 1280)
    local sh = (okw and h and h > 0) and h or ((world.lastWinH and world.lastWinH > 0) and world.lastWinH or 720)
    local x = math.max(0, math.min(cfg.iconX or UI_MARGIN, sw - sz))
    local y = math.max(0, math.min(cfg.iconY or UI_MARGIN, sh - sz))
    return x, y, sz
end

-- Dragging the icon fires onreposition every frame; recreating the badge each of
-- those frames would blink it, so the badge move is deferred to M.pump (via the
-- iconMovePending flag) and only applied once the position has settled.
-- (re)create the gear icon at the current UI scale and saved position
createIconBrowser = function()
    if iconBrowser then iconBrowser:close(); iconBrowser = nil end
    local ix, iy, sz = iconPos()
    local ok, err = pcall(function()
        iconBrowser = bolt.createembeddedbrowser(ix, iy, sz, sz, pageUrl("icon.html"))
        iconBrowser:onmessage(function(msg)
            if msg == "toggle" then togglePanel() end
        end)
        -- The icon page begins a move (start-reposition) when dragged; Bolt moves
        -- the browser live and reports the new geometry here. Persist it and flag
        -- the badge to follow once the drag settles (handled in M.pump).
        iconBrowser:onreposition(function(event)
            local x, y = event:xywh()
            if not x or not y then return end
            cfg.iconX, cfg.iconY = util.round(x), util.round(y)
            settings.saveSettings()
            iconMovePending = true
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

-- (re)create the badge at the current UI scale, to the right of the gear icon.
-- When the readout is turned off we destroy the browser entirely rather than
-- just hiding the badge in CSS: an embedded browser keeps capturing mouse clicks
-- over its rectangle even while transparent, so leaving it up would swallow
-- clicks in that area of the game view.
createReadoutBrowser = function()
    if readoutBrowser then readoutBrowser:close(); readoutBrowser = nil end
    if not cfg.showChunkId then return end
    local s = uiScale()
    -- sit just to the right of the gear icon, wherever the user has dragged it
    local ix, iy, sz = iconPos()
    local rx = ix + sz + 6
    local rw = math.floor(READOUT_BASE_W * s)
    local rh = math.floor(ICON_BASE * s)
    local ok, err = pcall(function()
        readoutBrowser = bolt.createembeddedbrowser(rx, iy, rw, rh, pageUrl("readout.html"))
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

-- ---- popups ----
-- A popup is a big, temporary card shown centred near the top of the game view.
-- It's an on-demand embedded browser loading the generic shell (ui/popup.html)
-- with a named variant (?p=<name> -> ui/popups/<name>.*): we create it, push a
-- payload once the page reports ready, and the page plays its animation then asks
-- us to close it again via oncloserequest. Only one popup is on screen at a time.
M.lastPopupGeom = "none"   -- diagnostics: last popup window/size/pos

local function closePopup()
    if popupBrowser then
        popupBrowser:close()
        popupBrowser = nil
    end
end
M.closePopup = closePopup

-- Open the named popup variant centred near the top of the game view and push it
-- the given message table (JSON-encoded here) once its page reports ready. The
-- variant name selects which ui/popups/<name>.* files render the card; the
-- payload's own `type` field selects the handler within that variant. opts.w /
-- opts.h give the card's base (unscaled) size, defaulting to POPUP_BASE_W/H;
-- every popup shares the same centred-near-top position.
local function openPopup(name, msg, opts)
    if not cfg.showPopups then return end   -- master toggle: all popups off
    closePopup()   -- replace any popup still on screen
    opts = opts or {}
    local payload = jsonEncode(msg)
    local s = uiScale()
    local cw = math.floor((opts.w or POPUP_BASE_W) * s)
    local ch = math.floor((opts.h or POPUP_BASE_H) * s)
    -- prefer a fresh read of the window size; fall back to the cached value
    local okw, w, h = pcall(bolt.gamewindowsize)
    local sw = (okw and w and w > 0) and w or ((world.lastWinW and world.lastWinW > 0) and world.lastWinW or 1280)
    local sh = (okw and h and h > 0) and h or ((world.lastWinH and world.lastWinH > 0) and world.lastWinH or 720)
    local x = math.floor((sw - cw) / 2)
    -- horizontally centred, but raised toward the top quarter of the screen
    local y = math.floor(sh * 0.18)
    M.lastPopupGeom = string.format("win=%dx%d size=%dx%d pos=%d,%d", sw, sh, cw, ch, x, y)
    local ok, b = pcall(bolt.createembeddedbrowser, x, y, cw, ch, pageUrl("popup.html") .. "&p=" .. name)
    if not ok or not b then
        print("[chunk-man] could not open " .. name .. " popup: " .. tostring(b))
        return
    end
    popupBrowser = b
    popupBrowser:onmessage(function(m)
        if m == "ready" and popupBrowser then popupBrowser:sendmessage(payload) end
    end)
    popupBrowser:oncloserequest(closePopup)
end
M.openPopup = openPopup

-- chunk celebration popups, both rendered by the "congrats" variant
-- (ui/popups/congrats.*); they differ only in the message `type`.
function M.showCongrats(rx, rz, chunkId)
    openPopup("congrats", { type = "congrats", id = chunkId, rx = rx, rz = rz })
end

-- "Chunk Complete!" card, shown when the last active task on the chunk is ticked.
function M.showTasksComplete(done, total)
    openPopup("congrats", { type = "complete", done = done, total = total })
end

-- "Task Complete!" card, shown when a single task is ticked off in the tasks
-- panel. Rendered by the smaller, sparkle-free "task" variant (ui/popups/task.*),
-- so it's given a shorter height than the chunk cards.
function M.showTaskComplete(name)
    openPopup("task", { type = "task", name = name }, { h = 130 })
end

-- build the always-on UI (gear icon + chunk readout)
function M.init()
    createIconBrowser()
    createReadoutBrowser()
end

return M

-- Local sticker editor. Ctrl+left-click on a chunk on the in-game world map
-- (detected in src/worldmap.lua, which owns the map library) opens a small
-- embedded browser (ui/stickers.html) for that chunk: a palette of the Chunk
-- Picker's sticker artwork plus a colour row, the chunk's picker sticker
-- shown read-only, and the locally added stickers with remove buttons.
--
-- Local stickers live in cfg.localStickerData, the same "id:type:#rrggbb"
-- comma-separated triple format the picker sync uses, except a chunk id may
-- repeat (a chunk can hold any number of local stickers; order = display
-- order). They are plugin-side only: nothing is written back to the picker.
-- The world map draws them stacked below the chunk's picker sticker.
--
-- The page is mouse-only by design (embedded browsers get no keyboard), so
-- every interaction is a click: pick a colour swatch, click an icon to add,
-- click x to remove.

local bolt     = require("bolt")
local util     = require("util")
local settings = require("settings")
local chunks   = require("chunks")

local cfg = settings.cfg
local CHUNKS_PER_AXIS = 256

local M = {}

local browser          -- the editor browser, nil when closed
local curRx, curRz     -- the chunk the open editor is editing

-- the chunk's local stickers as a plain array (localStickers holds rx/rz
-- fields on the same table, which must not leak into JSON or saves)
local function listFor(rx, rz)
    local out = {}
    local l = chunks.localStickers[rx .. "," .. rz]
    if l then
        for i, st in ipairs(l) do out[i] = { type = st.type, color = st.color } end
    end
    return out
end

-- Replace one chunk's local stickers inside cfg.localStickerData, keeping
-- every other chunk's entries in stored order, then persist and reparse.
local function saveList(rx, rz, list)
    local id = rx * CHUNKS_PER_AXIS + rz
    local parts = {}
    for tok, typ, col in tostring(cfg.localStickerData or ""):gmatch("(%d+):([%w%-_]*):(#%x%x%x%x%x%x)") do
        if tonumber(tok) ~= id then parts[#parts + 1] = tok .. ":" .. typ .. ":" .. col end
    end
    for _, st in ipairs(list) do
        parts[#parts + 1] = id .. ":" .. st.type .. ":" .. st.color
    end
    cfg.localStickerData = table.concat(parts, ",")
    chunks.rebuildGreyChunks()
    settings.saveSettings()
end

-- current editor state -> the page (chunk id, read-only picker sticker if
-- any, and the local sticker list)
local function sendState()
    if not browser then return end
    local up = chunks.stickerMap[curRx .. "," .. curRz]
    browser:sendmessage(util.jsonEncode({
        type = "state",
        chunk = curRx * CHUNKS_PER_AXIS + curRz,
        upstream = up and { type = up.type, color = up.color } or nil,
        stickers = listFor(curRx, curRz),
    }))
end

local function onMessage(m)
    if m == "ready" then
        sendState()
        return
    end
    local typ, col = m:match("^add\n([%w%-_]+)\n(#%x%x%x%x%x%x)$")
    if typ then
        local list = listFor(curRx, curRz)
        list[#list + 1] = { type = typ, color = col }
        saveList(curRx, curRz, list)
        sendState()
        return
    end
    local idx = tonumber(m:match("^remove\n(%d+)$"))
    if idx then
        local list = listFor(curRx, curRz)
        if list[idx] then
            table.remove(list, idx)
            saveList(curRx, curRz, list)
        end
        sendState()
        return
    end
end

local function closeEditor()
    if browser then
        browser:close()
        browser = nil
    end
end
M.close = closeEditor

-- base (unscaled) editor panel size; the page scrolls beyond it
local PANEL_W, PANEL_H = 300, 440

-- Open the editor for chunk (rx, rz), near the clicked point (mx, my) but
-- clamped fully on-screen. Reopens fresh when already open (possibly for a
-- different chunk).
function M.open(rx, rz, mx, my)
    closeEditor()
    curRx, curRz = rx, rz
    local s = util.clampUiScale(cfg.uiScale)
    local pw = math.floor(PANEL_W * s)
    local ph = math.floor(PANEL_H * s)
    local okw, w, h = pcall(bolt.gamewindowsize)
    local sw = (okw and w and w > 0) and w or 1280
    local sh = (okw and h and h > 0) and h or 720
    local px = math.max(0, math.min(math.floor(mx + 12), sw - pw))
    local py = math.max(0, math.min(math.floor(my - 40), sh - ph))
    local url = string.format("plugin://ui/stickers.html?s=%s&chunk=%d",
        tostring(s), rx * CHUNKS_PER_AXIS + rz)
    local ok, b = pcall(bolt.createembeddedbrowser, px, py, pw, ph, url)
    if not ok or not b then
        print("[chunk-man] could not open sticker editor: " .. tostring(b))
        return
    end
    browser = b
    browser:onmessage(onMessage)
    browser:oncloserequest(closeEditor)
end

return M

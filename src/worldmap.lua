-- World-map integration. Imports the worldmap/ detection library, vendored at
-- modules/worldmap/ from the World Map Plugin (its API is documented in
-- modules/worldmap/init.lua), and uses it to grey out every locked chunk on
-- the in-game world map, mirroring the 3D grey-out. The grey is painted through the library's
-- per-visible-cell region visitor, so the per-frame cost is bounded by the
-- viewport, not by how many chunks are locked. The unlocked area additionally
-- gets a green outline along every border with a locked chunk, and while the
-- map is open but unanchored the whole view is painted the same grey. The
-- library's chunk grid lines and chunk-ID labels are also enabled, always on
-- (no settings toggle).
--
-- Also shows a one-time notice popup the first time the world map is opened,
-- pointing the user at the settings toggle (cfg.mapGreyLocked); the
-- "already shown" flag persists per character (cfg.mapNoticeShown).
--
-- The library needs to see every onrender2d batch and run once per
-- onswapbuffers; main.lua pumps M.onRender2d / M.onSwap into it. Both library
-- pumps are pcall-contained, so a fault in there never kills the frame.

local bolt     = require("bolt")
local settings = require("settings")
local chunks   = require("chunks")
local ui       = require("ui")

local cfg = settings.cfg

local M = {}

local wm = nil   -- the library facade; nil when it failed to load

-- flat grey for locked map cells (RuneLite region-locker style); drawn on the
-- library's lowest layer, so anything more specific still shows on top
local greyFill = bolt.createsurfacefromrgba(1, 1, string.char(40, 40, 40, 150))
-- solid green for the unlocked-frontier outline (drawn over the grid lines)
local greenFill = bolt.createsurfacefromrgba(1, 1, string.char(0, 224, 64, 255))

function M.init()
    local loadCode = load or loadstring
    local ok, facade = pcall(function()
        return assert(loadCode(bolt.loadfile("modules/worldmap/init.lua"),
                                "@modules/worldmap/init.lua"))()
    end)
    if not ok or not facade then
        print("[chunk-man] worldmap library failed to load: " .. tostring(facade))
        return
    end
    if not facade.init({ base = "modules/worldmap" }) then
        print("[chunk-man] worldmap reference data missing; map grey-out disabled")
        return
    end
    wm = facade

    -- chunk grid lines + chunk-ID labels, always on (RuneLite region-locker
    -- style; both are off by default in the library)
    wm.grid.configure({ enabled = true, thickness = 3 })
    wm.labels.configure({ enabled = true })

    -- Grey every visible map cell whose chunk isn't unlocked. The visitor gives
    -- in-game (bolt) region coords, the same space chunks.keepSet uses (the
    -- picker remap is applied inside the library), so membership is a direct
    -- lookup. keepSet is read through the chunks table because rebuilds replace
    -- the table wholesale. greyLocked is the master grey-out switch; the map
    -- painting additionally has its own toggle.
    wm.regions.onVisible("chunkman-greyout", function(rx, rz, x, y, cw, clip)
        if not (cfg.greyLocked and cfg.mapGreyLocked) then return end
        if not chunks.keepSet[rx .. "," .. rz] then
            wm.regions.fillRect(greyFill, x, y, cw, cw, clip)
        end
    end)

    -- Top-layer pass over the map view, two jobs:
    --
    -- 1. While the map is open but NOT anchored (initial acquisition, or the
    --    anchor was lost after an overview-click jump), the per-cell grey-out
    --    can't run yet, so the ENTIRE view is painted in the same grey rather
    --    than letting locked content show ungreyed until the anchor lands.
    --    This is safe to do unconditionally: the library only reports the map
    --    open while the ACTIVE title is the RuneScape surface, so other map
    --    surfaces are never blanked.
    --
    -- 2. Once anchored: a green outline around the outside of the unlocked
    --    area, on every region border where an unlocked chunk meets a locked
    --    one. Drawn from this hook because it must sit ON TOP of the grid
    --    lines (the grid paints a black line on every chunk boundary, which
    --    would cover a boundary-centred outline drawn on any lower layer).
    --    Each visible unlocked cell paints a bar on each of its frontier
    --    edges; neighbours are taken in map (picker) space, so an edge
    --    against a remapped area (Arc, Anachronia, ...) tests the region
    --    actually drawn next to it. Picker +x is screen right, +z is screen
    --    up. Bars are centred on the boundary and extended half a thickness
    --    at both ends so corners join cleanly.
    local T = 3   -- outline thickness, window px (matches the grid lines)
    wm.onViewDraw("chunkman-overlay", function(view, mapping)
        if not (cfg.greyLocked and cfg.mapGreyLocked) then return end
        if not mapping then
            wm.regions.fillRect(greyFill, view.x, view.y, view.w, view.h, view)
            return
        end
        wm.regions.forEachVisible(function(rx, rz, x, y, cw, clip)
            if not chunks.keepSet[rx .. "," .. rz] then return end
            local prx, prz = wm.boltToPicker(rx, rz)
            local function locked(px, pz)
                local nx, nz = wm.pickerToBolt(px, pz)
                return not chunks.keepSet[nx .. "," .. nz]
            end
            if locked(prx - 1, prz) then   -- west: left edge
                wm.regions.fillRect(greenFill, x - T / 2, y - T / 2, T, cw + T, clip)
            end
            if locked(prx + 1, prz) then   -- east: right edge
                wm.regions.fillRect(greenFill, x + cw - T / 2, y - T / 2, T, cw + T, clip)
            end
            if locked(prx, prz + 1) then   -- north: top edge
                wm.regions.fillRect(greenFill, x - T / 2, y - T / 2, cw + T, T, clip)
            end
            if locked(prx, prz - 1) then   -- south: bottom edge
                wm.regions.fillRect(greenFill, x - T / 2, y + cw - T / 2, cw + T, T, clip)
            end
        end)
    end)

    -- One-time notice on the first world-map open. The flag is flipped and
    -- saved before the popup opens, so even a popup failure can't re-show it
    -- forever.
    wm.onEvent("chunkman-notice", function(ev)
        if ev == "open" and not cfg.mapNoticeShown then
            cfg.mapNoticeShown = true
            settings.saveSettings()
            ui.showMapNotice()
        end
    end)
end

-- ---- per-frame pumps (wired in main.lua; no-ops until init succeeds) ----

function M.onRender2d(event)
    if wm then wm.handleRender2d(event) end
end

function M.onSwap()
    if wm then wm.handleSwap() end
end

return M

-- World-map integration. Imports the worldmap/ detection library, vendored at
-- modules/worldmap/ from the World Map Plugin (its API is documented in
-- modules/worldmap/init.lua), and uses it to grey out every locked chunk on
-- the in-game world map, mirroring the 3D grey-out (roll-candidate chunks
-- synced from the Chunk Picker are painted translucent green instead of
-- grey). The grey is painted through the library's
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

local bolt        = require("bolt")
local util        = require("util")
local config      = require("config")
local settings    = require("settings")
local chunks      = require("chunks")
local ui          = require("ui")
local icons       = require("stickericons")
local stickeredit = require("stickeredit")
local maphint     = require("maphint")

local cfg = settings.cfg

local M = {}

local wm = nil   -- the library facade; nil when it failed to load

-- flat grey for locked map cells (RuneLite region-locker style); drawn on the
-- library's lowest layer, so anything more specific still shows on top
local greyFill = bolt.createsurfacefromrgba(1, 1, string.char(40, 40, 40, 150))
-- solid green for the unlocked-frontier outline (drawn over the grid lines)
local greenFill = bolt.createsurfacefromrgba(1, 1, string.char(0, 224, 64, 255))
-- translucent green for roll-candidate cells (the picker's "next rollable"
-- chunks), painted where the grey would otherwise go so the map still reads
-- as locked-but-rollable underneath
local rollFill = bolt.createsurfacefromrgba(1, 1, string.char(0, 224, 64, 100))

-- Sticker markers (picker stickers synced into chunks.stickerMap), drawn with
-- the picker's real artwork (src/stickericons.lua): FontAwesome glyphs and
-- number/tier characters as alpha masks tinted with the sticker's colour,
-- and RS3 skill icons as full-colour bitmaps drawn untinted, exactly how the
-- picker itself renders each kind. A dark copy of the same shape is drawn
-- offset underneath as a drop shadow for contrast on any map background.
-- Surfaces are cached for the plugin's lifetime: tinted masks per
-- (type, colour), images and shadows per type. Types without artwork (new
-- picker stickers) fall back to a generic colour-fill flag.
local darkFill = bolt.createsurfacefromrgba(1, 1, string.char(25, 25, 25, 235))
local stickerFills = {}
local function stickerFill(hex)
    local s = stickerFills[hex]
    if s == nil then
        local r, g, b = util.hexToRgb(hex)
        local ok, surf = pcall(bolt.createsurfacefromrgba, 1, 1,
            string.char(util.round(r * 255), util.round(g * 255), util.round(b * 255), 255))
        s = ok and surf or false
        stickerFills[hex] = s
    end
    return s or nil
end

local ISZ = icons.size
local iconCache, shadowCache = {}, {}

-- a w x h alpha mask -> a surface of that shape in one flat colour
local function surfaceFromMask(mask, w, h, r, g, b)
    local px = {}
    for i = 1, #mask do px[i] = string.char(r, g, b, mask:byte(i)) end
    local ok, s = pcall(bolt.createsurfacefromrgba, w, h, table.concat(px))
    return ok and s or false
end

-- The icon + shadow surfaces for a sticker, built on first use. Returns
-- nil, nil when there is no artwork for the type (caller falls back).
local function iconSurfaces(typ, hex)
    local icon
    local shadow = shadowCache[typ]
    local img = icons.image(typ)
    if img then
        icon = iconCache[typ]
        if icon == nil then
            local ok, s = pcall(bolt.createsurfacefromrgba, ISZ, ISZ, img)
            icon = ok and s or false
            iconCache[typ] = icon
        end
        if shadow == nil then
            local px = {}
            for i = 1, #img / 4 do px[i] = string.char(20, 20, 20, img:byte(i * 4)) end
            local ok, s = pcall(bolt.createsurfacefromrgba, ISZ, ISZ, table.concat(px))
            shadow = ok and s or false
            shadowCache[typ] = shadow
        end
    else
        local mask = icons.mask(typ)
        if not mask then return nil, nil end
        local key = typ .. "|" .. hex
        icon = iconCache[key]
        if icon == nil then
            local r, g, b = util.hexToRgb(hex)
            icon = surfaceFromMask(mask, ISZ, ISZ,
                util.round(r * 255), util.round(g * 255), util.round(b * 255))
            iconCache[key] = icon
        end
        if shadow == nil then
            shadow = surfaceFromMask(mask, ISZ, ISZ, 20, 20, 20)
            shadowCache[typ] = shadow
        end
    end
    return icon or nil, shadow or nil
end

-- Draw a surface of native size (nw, nh) scaled into rect (x, y, w, h),
-- clamped to the clip rect by trimming the source rect proportionally
-- (drawtoscreen has no clipping of its own, and stickers sit at cell
-- corners, so they regularly straddle the map view's edges).
local function drawSurfClipped(surf, nw, nh, x, y, w, h, clip)
    local x0, y0 = math.max(x, clip.x), math.max(y, clip.y)
    local x1 = math.min(x + w, clip.x + clip.w)
    local y1 = math.min(y + h, clip.y + clip.h)
    if x1 <= x0 or y1 <= y0 then return end
    surf:drawtoscreen(
        util.round((x0 - x) / w * nw), util.round((y0 - y) / h * nh),
        math.max(1, util.round((x1 - x0) / w * nw)), math.max(1, util.round((y1 - y0) / h * nh)),
        x0, y0, x1 - x0, y1 - y0)
end

local function drawIconClipped(surf, x, y, s, clip)
    drawSurfClipped(surf, ISZ, ISZ, x, y, s, s, clip)
end

-- The bottom-right "Ctrl+Click a chunk to edit stickers" hint: baked text
-- (src/maphint.lua; bolt has no text-draw API) tinted white on first use,
-- over a translucent dark backing.
local hintBg = bolt.createsurfacefromrgba(1, 1, string.char(0, 0, 0, 140))
local hintSurf
local function hintSurface()
    if hintSurf == nil then
        hintSurf = surfaceFromMask(maphint.mask(), maphint.w, maphint.h, 236, 229, 212)
    end
    return hintSurf or nil
end

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

    -- Grey every visible map cell whose chunk isn't unlocked, except for the
    -- picker's current roll candidates (synced into chunks.rollableSet), which
    -- get a translucent green instead so the next rollable chunks stand out.
    -- The visitor gives in-game (bolt) region coords, the same space
    -- chunks.keepSet / rollableSet use (the picker remap is applied inside the
    -- library), so membership is a direct lookup. Both sets are read through
    -- the chunks table because rebuilds replace the tables wholesale.
    -- greyLocked is the master grey-out switch; the map painting additionally
    -- has its own toggle.
    wm.regions.onVisible("chunkman-greyout", function(rx, rz, x, y, cw, clip)
        if not (cfg.greyLocked and cfg.mapGreyLocked) then return end
        local key = rx .. "," .. rz
        if chunks.keepSet[key] then return end
        if chunks.rollableSet[key] then
            wm.regions.fillRect(rollFill, x, y, cw, cw, clip)
        else
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

    -- Sticker markers, drawn from their own top-layer hook so they show
    -- independently of the grey-out toggles (they are picker data, not part
    -- of the lock overlay). Each chunk draws a vertical stack in its
    -- upper-right corner (where the picker draws its stickers): the picker's
    -- own sticker first, then any locally added ones (ctrl+click editor)
    -- below it. Zoomed in: the sticker's actual icon with a drop shadow, or
    -- a generic flag (dark pole, colour pennant) for types without artwork.
    -- Zoomed far out (cells too small to read an icon): one colour dot per
    -- chunk on a dark underlay. Sticker count is tiny, so iterating the
    -- whole map per frame is fine; regionRect returns nil for off-grid
    -- cells and both painters clip to the view.

    -- one sticker at slot position (ix, iy), badge size s
    local function drawSticker(st, ix, iy, s, view)
        local icon, shadow = iconSurfaces(st.type, st.color)
        if icon then
            local off = math.max(1, util.round(s * 0.08))
            if shadow then drawIconClipped(shadow, ix + off, iy + off, s, view) end
            drawIconClipped(icon, ix, iy, s, view)
            return
        end
        local fill = stickerFill(st.color)
        if not fill then return end
        local pw = math.max(2, util.round(s * 0.14))   -- pole width
        wm.regions.fillRect(darkFill, ix + pw - 1, iy - 1, s * 0.55 + 2, s * 0.4 + 2, view)
        wm.regions.fillRect(fill, ix + pw, iy, s * 0.55, s * 0.4, view)
        wm.regions.fillRect(darkFill, ix, iy, pw, s * 0.9, view)
    end

    -- a chunk's whole stack: the picker sticker (may be nil), then the local
    -- list (may be nil), stacked downward from the cell's upper-right corner
    local function drawStack(rx, rz, up, loc, view)
        local x, y, cw = wm.regionRect(rx, rz)
        if not x then return end
        local first = up or loc[1]
        if cw < 14 then
            local d = math.max(3, util.round(cw * 0.3))
            local fill = stickerFill(first.color)
            if not fill then return end
            local cx, cy = x + (cw - d) / 2, y + (cw - d) / 2
            wm.regions.fillRect(darkFill, cx - 1, cy - 1, d + 2, d + 2, view)
            wm.regions.fillRect(fill, cx, cy, d, d, view)
            return
        end
        -- small badge per sticker: enough to identify, floored so it stays
        -- legible at low zoom
        local s = math.max(6, cw * 0.18)
        local ix = x + cw - s - cw * 0.04
        local iy = y + cw * 0.05
        local step = s + math.max(1, util.round(s * 0.15))
        if up then
            drawSticker(up, ix, iy, s, view)
            iy = iy + step
        end
        if loc then
            for _, st in ipairs(loc) do
                drawSticker(st, ix, iy, s, view)
                iy = iy + step
            end
        end
    end

    wm.onViewDraw("chunkman-stickers", function(view, mapping)
        if not mapping then return end
        for key, up in pairs(chunks.stickerMap) do
            drawStack(up.rx, up.rz, up, chunks.localStickers[key], view)
        end
        for key, loc in pairs(chunks.localStickers) do
            if not chunks.stickerMap[key] then
                drawStack(loc.rx, loc.rz, nil, loc, view)
            end
        end
    end)

    -- The sticker-editor command hint, bottom-right of the map view. Only
    -- while anchored: that is when ctrl+click actually works, and it keeps
    -- the hint off the grey "acquiring" screen. Baked at 2x, drawn at half
    -- size scaled by the UI scale (see maphint.lua).
    wm.onViewDraw("chunkman-hint", function(view, mapping)
        if not mapping then return end
        local surf = hintSurface()
        if not surf then return end
        local sc = util.clampUiScale(cfg.uiScale)
        local w, h = maphint.w / 2 * sc, maphint.h / 2 * sc
        local pad = util.round(5 * sc)
        local x = view.x + view.w - w - pad * 2 - util.round(8 * sc)
        local y = view.y + view.h - h - pad * 2 - util.round(8 * sc)
        wm.regions.fillRect(hintBg, x, y, w + pad * 2, h + pad * 2, view)
        drawSurfClipped(surf, maphint.w, maphint.h, x + pad, y + pad, w, h, view)
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

-- Ctrl+left-click a chunk on the open world map to edit its local stickers.
-- Only clicks inside the map view count, and only once the anchor is
-- established (mapToWorld needs it); the editor opens next to the click.
-- main.lua forwards every mouse-button event here.
local REGION_UNITS = config.UNITS_PER_TILE * config.TILES_PER_REGION
function M.onMouseButton(event)
    if not wm then return end
    if event:button() ~= 1 or not event:ctrl() then return end
    if not wm.isOpen() then return end
    local view = wm.view()
    if not view then return end
    local mx, my = event:xy()
    if mx < view.x or mx >= view.x + view.w or my < view.y or my >= view.y + view.h then return end
    local wx, wz = wm.mapToWorld(mx, my)
    if not wx then return end
    stickeredit.open(math.floor(wx / REGION_UNITS), math.floor(wz / REGION_UNITS), mx, my)
end

return M

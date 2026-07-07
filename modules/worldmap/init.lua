-- ============================================================
-- worldmap: RS3 world-map detection + overlay library for Bolt
-- ============================================================
-- Detects when the in-game world map is open, recovers its position/zoom by
-- matching the drawn map tiles against a reference of the world map, and
-- exposes a coordinate + drawing API over it. Import it by copying this whole
-- directory into your plugin (it is self-contained: modules, the vendored
-- chat-font OCR table and the map reference data all live here) and loading
-- this one file:
--
--   local loadCode = load or loadstring
--   local wm = assert(loadCode(bolt.loadfile("worldmap/init.lua"),
--                              "@worldmap/init.lua"))()
--   wm.init({ base = "worldmap" })   -- base = where you put the directory
--
-- WIRING. The library needs to see every onrender2d batch and run once per
-- onswapbuffers. Bolt keeps ONE callback per event per plugin, so if your
-- plugin uses those hooks itself, pump the library from your own handlers
-- (both are pcall-contained; a library fault never kills your frame):
--
--   bolt.onrender2d(function(e) wm.handleRender2d(e) ... your work ... end)
--   bolt.onswapbuffers(function() ... draw under ... wm.handleSwap() ... end)
--
-- or, if you don't need those hooks, let the library take them:
--
--   wm.attach()
--
-- Everything the library draws happens inside handleSwap, in this fixed
-- order: region visitors (lowest), region fills, grid lines + chunk-ID
-- labels, region draw callbacks, point markers, view draw hooks (topmost).
-- Where you call handleSwap() inside your own swap handler decides how your
-- own drawing layers against all of it.
--
-- DETECTION QUERIES (valid after the last pumped frame):
--   wm.isOpen()   -> true while the world map is open
--   wm.mapping()  -> { x0, y0, cw } window px of chunk (0,0)'s top-left corner
--                    + px per chunk, or nil until anchored. Read-only.
--   wm.view()     -> the map-view clip rect { x, y, w, h }, or nil
--   wm.zoom()     -> the OCR'd zoom readout (percent), or nil
--   wm.onEvent(name, fn)   fn(ev) on detection transitions, ev is one of
--                          "open" | "close" | "anchor" | "anchor-lost"
--   wm.removeEvent(name)
--
-- COORDINATES (all nil until anchored; world units = bolt world units, 512
-- per game tile, e.g. from onminimapterrain):
--   wm.worldToMap(wx, wz)  -> window px of a world position on the map
--   wm.mapToWorld(sx, sy)  -> world units under a window px (click handling);
--                             floor(wx / (512*64)) gives the bolt region
--   wm.regionRect(rx, rz)  -> x, y, cw window px rect of an in-game region
--   wm.boltToPicker(rx, rz) / wm.pickerToBolt(prx, prz)
--                             in-game <-> world-map region ID remap (Arc,
--                             Anachronia, Havenhythe, Lost Grove boxes)
--
-- DRAWING (see points.lua / regions.lua headers for the full contracts):
--   wm.points   .set(name, wx, wz [, drawFn]) / .remove / .makeDot / .drawDot
--   wm.regions  .set(name, rx, rz, colourOrDrawFn) / .remove
--               .onVisible(name, fn) / .removeVisitor  per-visible-cell visitor
--               .forEachVisible(fn) / .fillRect / .strokeRect
--   wm.grid     .configure{ enabled, color = {r,g,b,a}, minPitch,
--                           thickness }   line width in window px, default 3
--   wm.labels   .configure{ enabled, minPitch, maxDrawn }
--               (both OFF by default: nothing is drawn unless you enable it
--                or register points/regions)
--   wm.onViewDraw(name, fn) / wm.removeViewDraw(name)
--               fn(view, mapping) once per frame while the map view is
--               resolved, drawn ON TOP of every other layer. view = the clip
--               rect {x,y,w,h} (keep your drawing inside it), mapping =
--               {x0,y0,cw} or nil until anchored. For free-form drawing over
--               the whole view (HUDs, cursors, selections); errors are
--               contained and logged.
--
-- init(opts):
--   base   directory the library was copied to, default "worldmap"
--   debug  true writes debug.log/tiles.txt diagnostics via bolt.saveconfig
-- Returns true when the map reference data loaded (detection possible).

local bolt = require("bolt")

local M = {}
local D = nil   -- internal modules after init: state, scan, driver, ...

-- internal module loader: bolt has no filesystem require() for plugin-local
-- files, and the host plugin's own loader (if any) is none of our business.
-- Each sibling module receives this loader as its chunk argument and pulls
-- its dependencies through it; the cache makes state.lua one shared instance.
local function mkloader(base)
    local loadCode = load or loadstring
    local cache = { bolt = bolt }
    local function mreq(name)
        local m = cache[name]
        if m then return m end
        local path = base .. "/" .. tostring(name) .. ".lua"
        local src = bolt.loadfile(path)
        if not src then error("worldmap: cannot load " .. path, 2) end
        local chunk = assert(loadCode(src, "@" .. path))
        m = chunk(mreq)
        assert(m ~= nil, path .. " must return a table")
        cache[name] = m
        return m
    end
    return mreq
end

function M.init(opts)
    opts = opts or {}
    local mreq = mkloader(opts.base or "worldmap")
    local state = mreq("state")
    -- DEBUG must be set before the other modules load (they localise it)
    if opts.debug ~= nil then state.DEBUG = opts.debug and true or false end
    local find = mreq("chunkfind")
    D = {
        state = state, find = find,
        scan = mreq("scan"), driver = mreq("driver"),
        points = mreq("points"), regions = mreq("regions"),
        overlay = mreq("overlay"), dbg = mreq("debuglog"),
    }
    -- re-exports (see the header): stable references, safe to localise
    M.points, M.regions = D.points, D.regions
    M.grid, M.labels = D.overlay.grid, D.overlay.labels
    M.worldToMap, M.mapToWorld = D.points.worldToMap, D.points.mapToWorld
    M.boltToPicker, M.pickerToBolt = D.points.boltToPicker, D.points.pickerToBolt
    M.regionRect = D.regions.regionRect
    M.onViewDraw, M.removeViewDraw = D.overlay.onViewDraw, D.overlay.removeViewDraw
    M._require = mreq   -- internal access for the offline test harness only
    local ok = find.load()
    if ok then
        state.log(string.format("chunkfind refs loaded: ref2=%dx%d ref4=%s",
            find.ref2.w, find.ref2.h,
            find.ref4.ok and (find.ref4.w .. "x" .. find.ref4.h) or "MISSING"))
    else
        state.log("chunkfind reference FAILED to load, chunk identification disabled")
    end
    D.dbg.flush()
    return ok
end

-- ---- event pumps (pcall-contained, errors logged and capped) ----

function M.handleRender2d(event)
    local d = D
    if not d then return end
    local S, perf = d.state.S, d.state.perf
    local t0 = bolt.time()
    local ok, err = pcall(d.scan.scan2d, event)
    perf.scan = perf.scan + (bolt.time() - t0)
    if not ok and S.err < 10 then
        S.err = S.err + 1
        d.state.log("[f" .. S.frame .. "] ERROR scan2d: " .. tostring(err))
    end
end

function M.handleSwap()
    local d = D
    if not d then return end
    local ok, err = pcall(d.driver.onswap)
    if not ok and d.state.S.err < 10 then
        d.state.S.err = d.state.S.err + 1
        d.state.log("[f" .. d.state.S.frame .. "] ERROR onswap: " .. tostring(err))
    end
end

-- convenience wiring for hosts that don't use these hooks themselves
function M.attach()
    bolt.onrender2d(M.handleRender2d)
    bolt.onswapbuffers(function() M.handleSwap() end)
end

-- ---- detection queries ----

function M.isOpen() return D ~= nil and D.state.S.ttl > 0 end
function M.mapping() return D and D.state.anc.draw or nil end
function M.view()
    if not D then return nil end
    return D.state.S.mapView or D.state.anc.bbox
end
function M.zoom() return D and D.state.S.zoom or nil end

-- ---- detection transition callbacks ----

function M.onEvent(name, fn)
    assert(D, "worldmap: call init() before onEvent()")
    D.state.events[name] = fn
end
function M.removeEvent(name)
    if D then D.state.events[name] = nil end
end

return M

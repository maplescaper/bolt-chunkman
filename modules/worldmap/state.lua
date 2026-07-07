-- Shared config + state. Required by every module; the internal loader in
-- init.lua caches modules, so everything here is ONE instance and
-- cross-module state lives in table fields. Modules localise the hot fields
-- at load time, which also keeps each file well inside LuaJIT's
-- 60-upvalue-per-function budget.

local M = {}

-- ---- config ----
-- debug logging master switch: the diagnostic writers (debug.log + tiles.txt)
-- are SYNCHRONOUS disk writes, so they only run when this is true. Set it via
-- init{ debug = true } (it must be set before the other modules load; they
-- localise it). The in-memory event ring (M.log) always accumulates
-- regardless; it is cheap.
M.DEBUG = false

M.TARGET        = "runescapesurface"  -- map title, lower-cased, spaces removed
M.FRAGMENTS     = { "surf", "urfac", "scape", "rune", "unesc" }
M.DUP_PX        = 2      -- glyph copies within this many px are outline dupes
M.MAX_IMAGES    = 6000   -- per-batch scan cap
M.OPEN_TTL      = 3      -- frames the "open" state lingers after the title vanishes
M.SAMPLE_EVERY  = 15     -- heavier work (panel capture, diagnostics) every N frames
M.FLUSH_EVERY   = 30     -- debug.log write cadence
M.MAX_DUMP_LINES = 60

-- map tiles (see legacy notes: LODs draw square atlas tiles 32..2048 px; UI
-- icons overlap the small end, so candidates are gated on drawn size and
-- reduced to the dominant same-size group)
M.TILE_MIN_ATLAS = 24
M.TILE_MAX_ATLAS = 2048
M.TILE_MIN_DRAWN = 40
M.TILE_MAX_LIST  = 400
M.MAP_MIN_TILES  = 4   -- at 200% zoom only ~6 tiles are visible (3x2, most
                       --  of them edge-clipped); false groups this small
                       --  are harmless since they can't win the content match

-- interface panels framing the map view (right/bottom = window corner)
M.MAP_MIN_SCR         = 200
M.MAP_BR_FRAC         = 0.80
M.MAP_PANEL_LEFT_FRAC = 0.15
M.MAP_PANEL_MAXW_FRAC = 0.50
M.MAP_PANEL_MINH_FRAC = 0.40
M.MAP_TOP_MINW_FRAC   = 0.85
M.MAP_TOP_MAXY_FRAC   = 0.15
M.MAP_TOP_MAXH_FRAC   = 0.40

-- content matcher gates
M.SAMPLE_CAP   = 96    -- texel sample points per frame PER atlas size: the
                       --  map layer is the MINORITY group at 100/200% zoom
                       --  (few big tiles among many underlay candidates),
                       --  so sampling budgets and strides are per-group or
                       --  the map layer starves and can never be matched
M.MIN_PTS      = 24    -- matcher needs at least this many points
M.ACQ_NCC      = 0.70  -- fresh (global) acquisition: minimum peak
M.ACQ_MARGIN   = 0.05  --  ... and lead over the runner-up
M.CONF_NCC     = 0.50  -- verify agreeing with the mapping: enough to refresh
M.DIS_NCC      = 0.75  -- verify disagreeing: must be this strong to count
M.DIS_MARGIN   = 0.05
M.DIS_BAD      = 2     -- confident disagreements before the cache is wiped
M.VERIFY_EVERY = 45    -- frames between verify matches while anchored
M.SLOT_CAP     = 800   -- atlas-slot identity cache size bound

-- chunk grid: the world map spans exactly 43x50 chunks, top-left chunk =
-- region (29,71), chunk ID = regionX*256 + regionZ (calibrated against the
-- Chunk Picker over the same resources/runescape_world_map.png)
M.GRID_COLS, M.GRID_ROWS = 43, 50
M.REGION_X0, M.REGION_Z0 = 29, 71

-- ---- state ----
-- S: general per-session/per-frame state (one table, not many locals, to
-- respect LuaJIT's 60-upvalue-per-function budget)
M.S = {
    frame = 0, swaps = 0, batches = 0, err = 0,
    images = 0, glyphs = 0, shownImages = 0, shownGlyphs = 0,
    seen = false, ttl = 0, wasOpen = false, lastLine = "",
    lines = {}, cands = {}, shownLines = {}, shownCands = {},
    mapView = nil, wasMapView = false, wasAnchored = false,
    zoom = nil, zoomCand = nil, zoomN = 0, zoomF = -1e9,
}
-- tile: per-frame render-geometry collection (reset each swap).
-- samples/smSeen/smStride are keyed by atlas size (one bucket per layer).
M.tile = {
    list = {}, big = {}, dump = {}, hist = {}, histN = 0,
    scale = 1, winW = 0, winH = 0, rawW = 0, rawH = 0,
    samples = {}, smSeen = {}, smStride = {}, needSamples = false,
}
-- anc: the chunk anchor for atlas-slot identity cache + this frame's mapping.
--   slots[awKey] = { cx, cy } chunk coords of that tile's top-left corner
--   draw = { x0, y0, cw }: window px of chunk (0,0)'s TL + px per chunk
M.anc = {
    slots = {}, slotN = 0, cw = nil, ok = false, badN = 0,
    draw = nil, bbox = nil, frame = -1, lastTryF = -1e9,
    mlog = {}, votesN = 0, keptN = 0, elect = nil, e2 = nil,
}

-- events: named consumer callbacks fn(ev) fired by the driver on detection
-- transitions, ev in "open" | "close" | "anchor" | "anchor-lost" (registered
-- through the facade's onEvent/removeEvent)
M.events = {}

-- perf: throwaway per-frame timing (µs via bolt.time()) to pin down pan
-- hitches, dumped under "--- perf ---" in debug.log
M.perf = { scan = 0, anchor = 0, draw = 0, flush = 0,
           ring = {}, n = 0, sum = 0, max = 0, maxF = -1 }

-- ---- file logger (event ring; debuglog.lua writes it out) ----
M.logBuf = {}
local LOG_MAX = 250
function M.log(msg)
    local logBuf = M.logBuf
    logBuf[#logBuf + 1] = msg
    if #logBuf > LOG_MAX then table.remove(logBuf, 1) end
end

return M

-- ---- overlay drawing: chunk grid lines + chunk-ID labels + view hooks ----
-- Both features are OFF by default: an importing plugin that only wants the
-- detection/coordinate APIs pays nothing here. Enable and style them through
-- the facade (init.lua re-exports M.grid / M.labels):
--
--   grid.configure{ enabled = true,          -- draw the chunk grid lines
--                   color = {r, g, b, a},    -- 0-255 each, default opaque black
--                   minPitch = 12,           -- draw only at >= this px/chunk
--                   thickness = 3 }          -- line width in window px (does
--                                            --  not scale with zoom), centred
--                                            --  on the chunk boundary
--   labels.configure{ enabled = true,        -- draw the chunk-ID labels
--                     minPitch = 60,         -- label cells at least this wide
--                                            --  (below it the label barely
--                                            --  fits, and at low zoom ~900
--                                            --  cells would hit the draw list)
--                     maxDrawn = 640 }       -- per-frame label cap
--
-- configure merges only the fields present; call it again any time. The label
-- atlas (a ~1806x700 surface baking all 43x50 IDs) is built lazily on the
-- first enable, so consumers that never turn labels on never allocate it.

local mreq = ...
local bolt = mreq("bolt")
local state = mreq("state")

local S, anc, log = state.S, state.anc, state.log
local GRID_COLS, GRID_ROWS = state.GRID_COLS, state.GRID_ROWS
local REGION_X0, REGION_Z0 = state.REGION_X0, state.REGION_Z0

local M = {}

-- ---- feature config ----
M.gridCfg  = { enabled = false, minPitch = 12, thickness = 3, key = nil, surf = nil }
M.labelCfg = { enabled = false, minPitch = 60, maxDrawn = 640 }

-- 1x1 fill surface in the grid colour, rebuilt only when the colour changes
local function gridSurface(c)
    local r, g, b = c[1] or 0, c[2] or 0, c[3] or 0
    local a = c[4] or 255
    local key = r .. "," .. g .. "," .. b .. "," .. a
    local cfg = M.gridCfg
    if cfg.key == key and cfg.surf then return end
    local ok, s = pcall(bolt.createsurfacefromrgba, 1, 1, string.char(r, g, b, a))
    if ok then
        cfg.surf, cfg.key = s, key
    else
        log("grid colour surface FAILED: " .. tostring(s))
    end
end

M.grid = {}
function M.grid.configure(opts)
    local cfg = M.gridCfg
    if opts.enabled ~= nil then cfg.enabled = opts.enabled and true or false end
    if opts.minPitch then cfg.minPitch = opts.minPitch end
    if opts.thickness then cfg.thickness = opts.thickness end
    if opts.color then gridSurface(opts.color) end
    if cfg.enabled and not cfg.surf then gridSurface({ 0, 0, 0, 255 }) end
end

-- ---- pre-baked chunk-ID label atlas (built on first labels enable) ----
-- 3x5 bitmap digits (no text-draw API in bolt); per row bit 4 = left pixel,
-- bit 2 = middle, bit 1 = right.
local DIGIT_FONT = {
    [0] = {7,5,5,5,7}, [1] = {2,6,2,2,7}, [2] = {7,1,7,4,7}, [3] = {7,1,7,1,7},
    [4] = {5,5,7,1,1}, [5] = {7,4,7,1,7}, [6] = {7,4,7,5,7}, [7] = {7,1,1,2,2},
    [8] = {7,5,7,5,7}, [9] = {7,5,7,1,7},
}
-- All 43x50 chunk IDs are baked ONCE into a single 1806x700 surface (digits
-- at 2px per font pixel on a translucent backing); a label is then ONE
-- drawtoscreen call, scaled on the GPU.
local LBL_W, LBL_H = 42, 14
local labelAtlas, labelTried

local function bakeLabelAtlas()
    labelTried = true
    local BK = string.char(0, 0, 0, 0xB4)       -- backing (translucent black)
    local WH = string.char(255, 255, 255, 255)  -- digit pixels
    -- per digit, per font row: an 8px-wide pixel segment (3 cols x 2px + gap)
    local seg = {}
    for d = 0, 9 do
        seg[d] = {}
        for fr = 1, 5 do
            local b = DIGIT_FONT[d][fr]
            local p = {}
            local m = 4
            for _ = 1, 3 do
                local px = b >= m and WH or BK
                if b >= m then b = b - m end
                m = m / 2
                p[#p + 1] = px .. px
            end
            p[#p + 1] = BK .. BK
            seg[d][fr] = table.concat(p)
        end
    end
    local padRow = string.rep(BK, LBL_W)
    local out = {}
    for r = 0, GRID_ROWS - 1 do
        local rowParts = {}
        for pr = 1, LBL_H do rowParts[pr] = {} end
        for c = 0, GRID_COLS - 1 do
            local id = tostring((REGION_X0 + c) * 256 + (REGION_Z0 - r))
            local lpad = math.floor((LBL_W - #id * 8) / 2)
            local left = string.rep(BK, lpad)
            local right = string.rep(BK, LBL_W - lpad - #id * 8)
            rowParts[1][c + 1] = padRow
            rowParts[2][c + 1] = padRow
            for fr = 1, 5 do
                local mid = {}
                for k = 1, #id do
                    mid[k] = seg[tonumber(id:sub(k, k))][fr]
                end
                local line = left .. table.concat(mid) .. right
                rowParts[1 + fr * 2][c + 1] = line   -- each font row is 2px tall
                rowParts[2 + fr * 2][c + 1] = line
            end
            rowParts[13][c + 1] = padRow
            rowParts[14][c + 1] = padRow
        end
        for pr = 1, LBL_H do out[#out + 1] = table.concat(rowParts[pr]) end
    end
    local okA, surf = pcall(bolt.createsurfacefromrgba,
        GRID_COLS * LBL_W, GRID_ROWS * LBL_H, table.concat(out))
    if okA then labelAtlas = surf else log("label atlas FAILED: " .. tostring(surf)) end
end

M.labels = {}
function M.labels.configure(opts)
    local cfg = M.labelCfg
    if opts.enabled ~= nil then cfg.enabled = opts.enabled and true or false end
    if opts.minPitch then cfg.minPitch = opts.minPitch end
    if opts.maxDrawn then cfg.maxDrawn = opts.maxDrawn end
    if cfg.enabled and not labelTried then bakeLabelAtlas() end
end

-- ---- top-layer view draw hooks ----
-- Consumers that want to paint arbitrary content over the map view register
-- a named callback: fn(view, mapping) runs once per frame while the map is
-- open and the view rect is resolved, AFTER every built-in layer (region
-- visitors, region fills, grid, labels, region callbacks, point markers), so
-- it overlays all of them. `view` is the map-view clip rect {x,y,w,h} in
-- window px (read-only; keep your drawing inside it or it paints over the
-- framing interface); `mapping` is {x0,y0,cw} or nil until the chunk anchor
-- is established (the view rect resolves from the interface panels before
-- the content match lands). Errors are contained, logged and capped like
-- every other consumer callback.
M.viewHooks = {}
function M.onViewDraw(name, fn) M.viewHooks[name] = fn end
function M.removeViewDraw(name) M.viewHooks[name] = nil end

local vhErrN = 0
function M.drawViewHooks(open)
    if not open or next(M.viewHooks) == nil then return end
    local clip = S.mapView or anc.bbox
    if not clip then return end
    local mp = anc.draw
    for name, fn in pairs(M.viewHooks) do
        local ok, err = pcall(fn, clip, mp)
        if not ok and vhErrN < 10 then
            vhErrN = vhErrN + 1
            log("view-draw '" .. tostring(name) .. "' callback ERROR: "
                .. tostring(err))
        end
    end
end

function M.drawOverlays(open)
    local mp = anc.draw
    if not open or not mp then return end
    local cw = mp.cw
    local g, l = M.gridCfg, M.labelCfg
    local wantGrid = g.enabled and g.surf and cw >= g.minPitch
    local wantLabels = l.enabled and labelAtlas and cw >= l.minPitch
    if not (wantGrid or wantLabels) then return end
    local clip = S.mapView or anc.bbox
    if not clip then return end
    local x0, y0 = mp.x0, mp.y0
    local cx0, cy0 = clip.x, clip.y
    local cx1, cy1 = clip.x + clip.w, clip.y + clip.h
    -- world edges clamp the drawn area: nothing outside chunk (0,0)..(42,49)
    if x0 > cx0 then cx0 = x0 end
    if y0 > cy0 then cy0 = y0 end
    if x0 + GRID_COLS * cw < cx1 then cx1 = x0 + GRID_COLS * cw end
    if y0 + GRID_ROWS * cw < cy1 then cy1 = y0 + GRID_ROWS * cw end
    if cx1 - cx0 < 4 or cy1 - cy0 < 4 then return end
    local c0 = math.max(0, math.floor((cx0 - x0) / cw))
    local c1 = math.min(GRID_COLS - 1, math.floor((cx1 - x0) / cw))
    local r0 = math.max(0, math.floor((cy0 - y0) / cw))
    local r1 = math.min(GRID_ROWS - 1, math.floor((cy1 - y0) / cw))
    -- grid lines on the chunk boundaries: thickness-px bars centred on the
    -- boundary, clamped to the clip rect so thick edge lines cannot spill
    -- onto the framing interface
    if wantGrid then
        local gridSurf, t = g.surf, g.thickness
        for c = c0, c1 + 1 do
            local x = x0 + c * cw - t / 2
            local lx0 = math.max(x, cx0)
            local lx1 = math.min(x + t, cx1)
            if lx1 > lx0 then
                gridSurf:drawtoscreen(0, 0, 1, 1, lx0, cy0, lx1 - lx0, cy1 - cy0)
            end
        end
        for r = r0, r1 + 1 do
            local y = y0 + r * cw - t / 2
            local ly0 = math.max(y, cy0)
            local ly1 = math.min(y + t, cy1)
            if ly1 > ly0 then
                gridSurf:drawtoscreen(0, 0, 1, 1, cx0, ly0, cx1 - cx0, ly1 - ly0)
            end
        end
    end
    -- chunk-ID labels at each visible cell's top-left: one atlas call per cell
    if wantLabels then
        local ps = math.max(1, math.min(4, math.floor(cw / 64)))
        local dw, dh = LBL_W * ps / 2, LBL_H * ps / 2   -- atlas is baked at ps=2
        local pad = 2 * ps
        local maxDrawn = l.maxDrawn
        local drawn = 0
        for c = c0, c1 do
            for r = r0, r1 do
                local lx = math.max(x0 + c * cw, cx0) + pad
                local ly = math.max(y0 + r * cw, cy0) + pad
                if lx + dw <= cx1 and ly + dh <= cy1 and drawn < maxDrawn then
                    labelAtlas:drawtoscreen(c * LBL_W, r * LBL_H, LBL_W, LBL_H,
                        lx, ly, dw, dh)
                    drawn = drawn + 1
                end
            end
        end
    end
end

return M

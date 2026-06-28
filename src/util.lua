-- Small pure helpers shared across the plugin: table deep-copy, rounding,
-- panel sizing / UI-scale clamps (shared by the settings and tasks panels),
-- colour <-> hex conversion, a minimal JSON encoder (for the browser bridge),
-- and a 4x4 matrix inverse (for the grey shader's depth reconstruction).
-- Nothing here touches plugin state or the bolt API.

local M = {}

M.unpack = table.unpack or unpack

function M.deepcopy(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = M.deepcopy(v) end
    return r
end

function M.round(x) return math.floor(x + 0.5) end

-- ---- panel sizing / UI scale (shared by the settings and tasks panels) ----
-- Base (unscaled) panel width and default height; everything is multiplied by
-- the UI scale at render time.
M.PANEL_BASE_W, M.PANEL_BASE_H = 360, 560
local PANEL_MIN_H, PANEL_MAX_H = 220, 1400

-- clamp a (base, unscaled) panel height to sane bounds
function M.clampPanelHeight(v)
    v = tonumber(v) or M.PANEL_BASE_H
    if v < PANEL_MIN_H then v = PANEL_MIN_H elseif v > PANEL_MAX_H then v = PANEL_MAX_H end
    return v
end

-- clamp a UI scale factor to a sane minimum
function M.clampUiScale(v)
    local s = tonumber(v) or 1
    if s < 0.1 then s = 0.1 end
    return s
end

-- ---- colour <-> hex ----
local function clampChannel(x)
    local n = math.floor(x * 255 + 0.5)
    if n < 0 then n = 0 elseif n > 255 then n = 255 end
    return n
end
M.clampChannel = clampChannel

function M.rgbToHex(c)
    return string.format("#%02x%02x%02x", clampChannel(c.r), clampChannel(c.g), clampChannel(c.b))
end

function M.hexToRgb(hex)
    -- accepts "#rrggbb"
    local r = (tonumber(hex:sub(2, 3), 16) or 0) / 255
    local g = (tonumber(hex:sub(4, 5), 16) or 0) / 255
    local b = (tonumber(hex:sub(6, 7), 16) or 0) / 255
    return r, g, b
end

-- ---- minimal JSON encoder (encode only; the browser does the decoding) ----
local function jsonString(s)
    local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
    s = s:gsub('[%z\1-\31\\"]', function(c)
        return map[c] or string.format('\\u%04x', string.byte(c))
    end)
    return '"' .. s .. '"'
end

local function jsonEncode(v)
    local t = type(v)
    if t == "nil" then return "null"
    elseif t == "boolean" then return tostring(v)
    elseif t == "number" then return tostring(v)
    elseif t == "string" then return jsonString(v)
    elseif t == "table" then
        local n = 0
        for _ in pairs(v) do n = n + 1 end
        if n == #v then -- array (also handles empty -> [])
            local parts = {}
            for i = 1, #v do parts[i] = jsonEncode(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local parts = {}
        for k, val in pairs(v) do
            parts[#parts + 1] = jsonString(tostring(k)) .. ":" .. jsonEncode(val)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end
M.jsonEncode = jsonEncode

-- ---- 4x4 matrix inverse (column-major, as bolt's viewprojmatrix:get() gives) --
-- Used to turn screen + depth back into a world position in the grey shader.
-- Standard cofactor inverse (MESA gluInvertMatrix), 1-based Lua arrays. Returns
-- the inverse as a 16-element column-major table, or nil if singular.
function M.invertMat4(m)
    local inv = {}
    inv[1]  =  m[6]*m[11]*m[16] - m[6]*m[12]*m[15] - m[10]*m[7]*m[16] + m[10]*m[8]*m[15] + m[14]*m[7]*m[12] - m[14]*m[8]*m[11]
    inv[5]  = -m[5]*m[11]*m[16] + m[5]*m[12]*m[15] + m[9]*m[7]*m[16]  - m[9]*m[8]*m[15]  - m[13]*m[7]*m[12] + m[13]*m[8]*m[11]
    inv[9]  =  m[5]*m[10]*m[16] - m[5]*m[12]*m[14] - m[9]*m[6]*m[16]  + m[9]*m[8]*m[14]  + m[13]*m[6]*m[12] - m[13]*m[8]*m[10]
    inv[13] = -m[5]*m[10]*m[15] + m[5]*m[11]*m[14] + m[9]*m[6]*m[15]  - m[9]*m[7]*m[14]  - m[13]*m[6]*m[11] + m[13]*m[7]*m[10]
    inv[2]  = -m[2]*m[11]*m[16] + m[2]*m[12]*m[15] + m[10]*m[3]*m[16] - m[10]*m[4]*m[15] - m[14]*m[3]*m[12] + m[14]*m[4]*m[11]
    inv[6]  =  m[1]*m[11]*m[16] - m[1]*m[12]*m[15] - m[9]*m[3]*m[16]  + m[9]*m[4]*m[15]  + m[13]*m[3]*m[12] - m[13]*m[4]*m[11]
    inv[10] = -m[1]*m[10]*m[16] + m[1]*m[12]*m[14] + m[9]*m[2]*m[16]  - m[9]*m[4]*m[14]  - m[13]*m[2]*m[12] + m[13]*m[4]*m[10]
    inv[14] =  m[1]*m[10]*m[15] - m[1]*m[11]*m[14] - m[9]*m[2]*m[15]  + m[9]*m[3]*m[14]  + m[13]*m[2]*m[11] - m[13]*m[3]*m[10]
    inv[3]  =  m[2]*m[7]*m[16]  - m[2]*m[8]*m[15]  - m[6]*m[3]*m[16]  + m[6]*m[4]*m[15]  + m[14]*m[3]*m[8]  - m[14]*m[4]*m[7]
    inv[7]  = -m[1]*m[7]*m[16]  + m[1]*m[8]*m[15]  + m[5]*m[3]*m[16]  - m[5]*m[4]*m[15]  - m[13]*m[3]*m[8]  + m[13]*m[4]*m[7]
    inv[11] =  m[1]*m[6]*m[16]  - m[1]*m[8]*m[14]  - m[5]*m[2]*m[16]  + m[5]*m[4]*m[14]  + m[13]*m[2]*m[8]  - m[13]*m[4]*m[6]
    inv[15] = -m[1]*m[6]*m[15]  + m[1]*m[7]*m[14]  + m[5]*m[2]*m[15]  - m[5]*m[3]*m[14]  - m[13]*m[2]*m[7]  + m[13]*m[3]*m[6]
    inv[4]  = -m[2]*m[7]*m[12]  + m[2]*m[8]*m[11]  + m[6]*m[3]*m[12]  - m[6]*m[4]*m[11]  - m[10]*m[3]*m[8]  + m[10]*m[4]*m[7]
    inv[8]  =  m[1]*m[7]*m[12]  - m[1]*m[8]*m[11]  - m[5]*m[3]*m[12]  + m[5]*m[4]*m[11]  + m[9]*m[3]*m[8]   - m[9]*m[4]*m[7]
    inv[12] = -m[1]*m[6]*m[12]  + m[1]*m[8]*m[10]  + m[5]*m[2]*m[12]  - m[5]*m[4]*m[10]  - m[9]*m[2]*m[8]   + m[9]*m[4]*m[6]
    inv[16] =  m[1]*m[6]*m[11]  - m[1]*m[7]*m[10]  - m[5]*m[2]*m[11]  + m[5]*m[3]*m[10]  + m[9]*m[2]*m[7]   - m[9]*m[3]*m[6]

    local det = m[1]*inv[1] + m[2]*inv[5] + m[3]*inv[9] + m[4]*inv[13]
    if det == 0 then return nil end
    det = 1.0 / det
    for i = 1, 16 do inv[i] = inv[i] * det end
    return inv
end

return M

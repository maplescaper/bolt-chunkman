-- Live settings: holds the working copy (`cfg`) of the configuration, converts
-- values to/from their string and browser-JSON forms, and persists them to the
-- plugin config dir. Settings are kept per-character: the active file is resolved
-- from bolt.characterid() once a character logs in, migrating from the old shared
-- file the first time.
--
-- `cfg` is reset in place (never reassigned), so other modules may safely capture
-- a reference to `settings.cfg`.

local bolt   = require("bolt")
local util   = require("util")
local config = require("config")

local SCHEMA        = config.SCHEMA
local SCHEMA_BY_KEY = config.SCHEMA_BY_KEY

local M = {}

M.cfg = util.deepcopy(config.DEFAULTS)
local cfg = M.cfg

-- The active settings file. Resolved per-character (see resolveSettingsFile);
-- until a character is known it points at the legacy shared file.
M.SETTINGS_FILE = config.LEGACY_SETTINGS_FILE

function M.resetDefaults()
    -- reset in place so settings.cfg keeps its identity for other modules
    for k in pairs(cfg) do cfg[k] = nil end
    for k, v in pairs(util.deepcopy(config.DEFAULTS)) do cfg[k] = v end
end

-- ---- value (de)serialisation, shared by persistence and the browser bridge ----

-- the string form of a setting's value (used for saving to disk)
local function valueString(e)
    local k, t = e.key, e.type
    if t == "bool" then
        return cfg[k] and "true" or "false"
    elseif t == "int" or t == "float" then
        return tostring(cfg[k])
    elseif t == "text" then
        return tostring(cfg[k])
    elseif t == "rgb" then
        return util.rgbToHex(cfg[k])
    elseif t == "rgba" then
        return util.rgbToHex(cfg[k]) .. "," .. tostring(cfg[k].a)
    end
    return ""
end

-- apply a value (given as a string) to cfg, dispatching on the schema type
function M.applySet(key, valueStr)
    local e = SCHEMA_BY_KEY[key]
    if not e then return false end
    local t = e.type
    if t == "bool" then
        cfg[key] = (valueStr == "true")
    elseif t == "int" then
        local n = tonumber(valueStr); if n then cfg[key] = util.round(n) end
    elseif t == "float" then
        local n = tonumber(valueStr); if n then cfg[key] = n end
    elseif t == "text" then
        cfg[key] = valueStr or ""
    elseif t == "rgb" then
        local r, g, b = util.hexToRgb(valueStr)
        cfg[key] = { r = r, g = g, b = b }
    elseif t == "rgba" then
        local hex, a = valueStr:match("^([^,]+),(.+)$")
        if hex then
            local r, g, b = util.hexToRgb(hex)
            cfg[key] = { r = r, g = g, b = b, a = tonumber(a) or 1 }
        end
    end
    return true
end

-- the value of a setting in the shape the browser form expects (for JSON)
local function valueForBrowser(e)
    local k, t = e.key, e.type
    if t == "bool" then
        return cfg[k] and true or false
    elseif t == "int" or t == "float" then
        return cfg[k]
    elseif t == "text" then
        return cfg[k]
    elseif t == "rgb" then
        return util.rgbToHex(cfg[k])
    elseif t == "rgba" then
        return { c = util.rgbToHex(cfg[k]), a = cfg[k].a }
    end
end

function M.valuesPayload()
    local vals = {}
    for _, e in ipairs(SCHEMA) do vals[e.key] = valueForBrowser(e) end
    return vals
end

-- ---- persistence ----
function M.saveSettings()
    local out = {}
    for _, e in ipairs(SCHEMA) do
        out[#out + 1] = e.key .. "=" .. valueString(e)
    end
    bolt.saveconfig(M.SETTINGS_FILE, table.concat(out, "\n") .. "\n")
end

-- legacy config keys -> current keys, so older saved files still load. The
-- old write (greyOutside) was dropped; the rest were renamed to lock/unlock.
local LEGACY_KEYS = {
    greyChunks     = "greyLocked",
    greyChunkIds   = "unlockedChunkIds",
    greyColour     = "lockedColour",
    greyWallHeight = "lockedWallHeight",
}

local function applySettingsData(data)
    if not data then return false end
    for line in data:gmatch("[^\r\n]+") do
        local k, v = line:match("^([^=]+)=(.*)$")
        if k then M.applySet(LEGACY_KEYS[k] or k, v) end
    end
    return true
end

function M.loadSettings()
    -- Per-character file first; if the character has none yet, seed (migrate)
    -- from the old shared file so existing setups carry over. From then on each
    -- character saves to its own file, so settings no longer leak across
    -- accounts.
    if applySettingsData(bolt.loadconfig(M.SETTINGS_FILE)) then return end
    if M.SETTINGS_FILE ~= config.LEGACY_SETTINGS_FILE then
        applySettingsData(bolt.loadconfig(config.LEGACY_SETTINGS_FILE))
    end
end

-- Resolve SETTINGS_FILE to the current character's file. bolt.characterid() is
-- a stable, unique, alphanumeric id that isn't available until a character is
-- logged in, so this is re-checked each frame until it resolves. Returns true
-- when the active file changed (i.e. caller should (re)load).
local loadedCharId = nil
function M.resolveSettingsFile()
    local ok, id = pcall(bolt.characterid)
    if not ok or not id or id == "" then return false end
    id = tostring(id):gsub("[^%w]", "")
    if id == "" or id == loadedCharId then return false end
    loadedCharId = id
    M.SETTINGS_FILE = "chunkman-settings-" .. id .. ".cfg"
    return true
end

return M

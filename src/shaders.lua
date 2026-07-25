-- GPU shader setup. Compiles the shader programs the renderer uses and their
-- vertex buffers, from the .vert/.frag files in resources/. Each is wrapped in
-- pcall so a failure prints and leaves that field nil (the renderer skips a
-- pass whose shader is missing).
--
--   line  : boundary segments, expanded to thickness in screen space and
--           depth-occluded by terrain. Shader + buffer vendored verbatim from
--           JasperSurmont's bolt-questhelper (AGPL).
--   grey  : full-screen pass that reconstructs each pixel's world position from
--           the depth buffer and greys it by the chunk it belongs to. Draws a
--           unit-square quad (fillBuffer).

local bolt   = require("bolt")
local config = require("config")

local M = {}

-- ---- line shader ----
do
    local ok, err = pcall(function()
        local vs = bolt.createvertexshader(bolt.loadfile("resources/lineshader.vert"))
        local fs = bolt.createfragmentshader(bolt.loadfile("resources/lineshader.frag"))
        M.line = bolt.createshaderprogram(vs, fs)
        M.line:setattribute(0, 1, true, false, 2, 0, 2)
        M.lineBuffer = bolt.createshaderbuffer("\xFF\x00\x01\x00\x01\x01\xFF\x00\x01\x01\xFF\x01")
    end)
    if not ok then print("[chunk-man] shader init failed: " .. tostring(err)) end
end

-- ---- grey shader (per-pixel world-position grey-out of locked chunks) ----
do
    local ok, err = pcall(function()
        local vs = bolt.createvertexshader(bolt.loadfile("resources/greyshader.vert"))
        local fs = bolt.createfragmentshader(bolt.loadfile("resources/greyshader.frag"))
        M.grey = bolt.createshaderprogram(vs, fs)
        M.grey:setattribute(0, 1, true, false, 2, 0, 2)
        -- unit-square corners: two triangles (0,0)(1,0)(1,1) and (0,0)(1,1)(0,1)
        M.fillBuffer = bolt.createshaderbuffer("\x00\x00\x01\x00\x01\x01\x00\x00\x01\x01\x00\x01")
    end)
    if not ok then print("[chunk-man] grey shader init failed: " .. tostring(err)) end
end

-- ---- keep lookup texture (one texel per chunk: opaque => unlocked) ----
-- A 256x256 (CHUNKS_PER_AXIS) RGBA surface the grey shader samples with
-- texelFetch(rx, rz) to answer "is this chunk unlocked?" in O(1). Surfaces are
-- created GL_NEAREST / CLAMP_TO_EDGE and start fully transparent (all locked);
-- render.refreshKeepTex paints the unlocked chunks white when the set changes.
do
    local ok, err = pcall(function()
        M.keepTex = bolt.createsurface(config.CHUNKS_PER_AXIS, config.CHUNKS_PER_AXIS)
    end)
    if not ok then print("[chunk-man] keep texture init failed: " .. tostring(err)) end
end

return M

// Companion to greyshader.vert. For each screen pixel: read the scene depth,
// reconstruct the world position via the inverse view-projection matrix, work
// out which chunk that world point sits in, and paint the grey tint unless that
// chunk is unlocked. Sky / far-plane pixels belong to no chunk, so they are
// greyed too (subject to uGreySky).
//
// Whether a chunk is unlocked is answered by a single texel read from uKeepTex,
// a 256x256 lookup texture where texel (regionX, regionZ) is opaque iff that
// chunk is unlocked. This is O(1) per pixel and it replaces the old per-pixel
// linear scan of a uniform array, and removes any ceiling on the unlock count.
//
// Reconstruction mirrors the depth-sampling convention the other shaders use:
// the depth buffer is indexed by the UNFLIPPED clip-space UV (vScreenPos), so we
// reconstruct from that same unflipped NDC. ndc.z = depth*2-1 (GL window depth
// [0,1] -> NDC [-1,1]); multiplying by inverse(viewproj) and doing the
// homogeneous divide recovers the world point regardless of its w.
in highp vec4 vScreenPos;
layout(location=1) uniform highp vec4 uColor;          // grey tint (rgb + alpha)
layout(location=3) uniform highp mat4 uInvViewproj;    // inverse of the camera viewproj
layout(location=5) uniform highp vec4 uGreyWindow;     // grey window around the player: rxMin, rzMin, rxMax, rzMax
layout(location=6) uniform highp sampler2D uKeepTex;   // 256x256: texel (rx,rz).r > 0.5 => unlocked
layout(location=7) uniform highp sampler2D uDepthBuffer;
layout(location=9) uniform highp float uGreySky;       // 1 = grey the sky too, 0 = leave it
out highp vec4 fragColor;

// world units per region edge = UNITS_PER_TILE(512) * TILES_PER_REGION(64)
const highp float REGION_UNITS = 32768.0;
const highp float CHUNKS_PER_AXIS = 256.0;

void main() {
  // "leave this pixel untouched" outputs all-zero rather than discarding: it's a
  // no-op under both alpha blending (src.a == 0) and additive blending (adds 0),
  // and it keeps control flow uniform (no discard to defeat early-fragment opts).
  highp vec2 uv = (vScreenPos.xy / vScreenPos.w) * 0.5 + 0.5;
  highp float sceneDepth = texture(uDepthBuffer, uv).r;
  if (sceneDepth >= 0.9999) {               // sky / far plane: belongs to no
    if (uGreySky > 0.5) {                   // unlocked chunk -- grey it if asked,
      fragColor = uColor;                   // otherwise leave it untouched
    } else {
      fragColor = vec4(0.0);
    }
    return;
  }

  highp vec3 ndc = vec3(vScreenPos.xy / vScreenPos.w, sceneDepth * 2.0 - 1.0);
  highp vec4 wh = uInvViewproj * vec4(ndc, 1.0);
  if (abs(wh.w) < 1e-6) { fragColor = vec4(0.0); return; }
  highp vec3 world = wh.xyz / wh.w;

  // chunk id = regionX * 256 + regionZ
  highp float rx = floor(world.x / REGION_UNITS);
  highp float rz = floor(world.z / REGION_UNITS);

  // Grey window: only chunks within the grid centred on the player's region are
  // ever greyed; anything further out is left untouched, regardless of lock state.
  if (rx < uGreyWindow.x || rx > uGreyWindow.z || rz < uGreyWindow.y || rz > uGreyWindow.w) {
    fragColor = vec4(0.0);
    return;
  }

  // Outside valid region space there is no chunk to look up; it can't be
  // unlocked, so grey it (and keep the texelFetch coords in range).
  if (rx < 0.0 || rx >= CHUNKS_PER_AXIS || rz < 0.0 || rz >= CHUNKS_PER_AXIS) {
    fragColor = uColor;
    return;
  }

  // O(1) keep lookup: one texel per chunk, NEAREST-filtered so the fetch is exact.
  bool keep = texelFetch(uKeepTex, ivec2(int(rx), int(rz)), 0).r > 0.5;
  fragColor = keep ? vec4(0.0) : uColor;
}

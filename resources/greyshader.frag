// Companion to greyshader.vert. For each screen pixel: read the scene depth,
// reconstruct the world position via the inverse view-projection matrix, work
// out which chunk that world point sits in, and paint the grey tint unless that
// chunk is in the "unlocked" list. Sky / far-plane pixels belong to no chunk, so
// they are greyed too.
//
// Reconstruction mirrors the depth-sampling convention the other shaders use:
// the depth buffer is indexed by the UNFLIPPED clip-space UV (vScreenPos), so we
// reconstruct from that same unflipped NDC. ndc.z = depth*2-1 (GL window depth
// [0,1] -> NDC [-1,1]); multiplying by inverse(viewproj) and doing the
// homogeneous divide recovers the world point regardless of its w.
in highp vec4 vScreenPos;
layout(location=1) uniform highp vec4 uColor;          // grey tint (rgb + alpha)
layout(location=2) uniform highp vec2 uScreenSize;
layout(location=3) uniform highp mat4 uInvViewproj;    // inverse of the camera viewproj
layout(location=7) uniform highp sampler2D uDepthBuffer;
layout(location=8) uniform highp float uKeepCount;     // number of unlocked chunk IDs
layout(location=9) uniform highp float uGreySky;       // 1 = grey the sky too, 0 = leave it
layout(location=10) uniform highp vec4 uKeep[64];      // unlocked chunk IDs, packed 4 per vec4
out highp vec4 fragColor;

// world units per region edge = UNITS_PER_TILE(512) * TILES_PER_REGION(64)
const highp float REGION_UNITS = 32768.0;
const highp float CHUNKS_PER_AXIS = 256.0;

void main() {
  highp vec2 uv = (vScreenPos.xy / vScreenPos.w) * 0.5 + 0.5;
  highp float sceneDepth = texture(uDepthBuffer, uv).r;
  if (sceneDepth >= 0.9999) {               // sky / far plane: belongs to no
    if (uGreySky > 0.5) {                   // unlocked chunk -- grey it if asked,
      fragColor = uColor;                   // otherwise leave it untouched
      return;
    }
    discard;
  }

  highp vec3 ndc = vec3(vScreenPos.xy / vScreenPos.w, sceneDepth * 2.0 - 1.0);
  highp vec4 wh = uInvViewproj * vec4(ndc, 1.0);
  if (abs(wh.w) < 1e-6) discard;
  highp vec3 world = wh.xyz / wh.w;

  // chunk id = regionX * 256 + regionZ
  highp float rx = floor(world.x / REGION_UNITS);
  highp float rz = floor(world.z / REGION_UNITS);
  highp float id = rx * CHUNKS_PER_AXIS + rz;

  // keep (leave un-greyed) if this chunk is in the unlocked list
  int n = int(uKeepCount + 0.5);
  int idx = 0;
  for (int j = 0; j < 64; j++) {
    if (idx >= n) break;
    highp vec4 k = uKeep[j];
    if (abs(k.x - id) < 0.5) discard; idx++;
    if (idx >= n) break;
    if (abs(k.y - id) < 0.5) discard; idx++;
    if (idx >= n) break;
    if (abs(k.z - id) < 0.5) discard; idx++;
    if (idx >= n) break;
    if (abs(k.w - id) < 0.5) discard; idx++;
  }

  fragColor = uColor;
}

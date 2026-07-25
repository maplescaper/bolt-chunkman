// Companion to greyshader.vert (the same full-screen quad feeds both passes).
// Per-pixel region boundary grid: for each screen pixel, reconstruct its world
// position from the depth buffer (exactly like greyshader.frag) and paint it as
// a boundary line if it lies close enough to a region edge. Because every pixel
// is judged by where it actually is, the lines hug the terrain and climb over
// hills, and they need no placement height.
//
// Line thickness is screen-constant. Rather than screen-space derivatives
// (undefined in non-uniform control flow, and noisy across depth
// discontinuities), the world point is re-projected with its x (or z) snapped
// onto the nearest boundary plane; the screen-space distance between the two
// projections is the pixel distance to that boundary.
//
// Terrain-only mode estimates the surface normal at line pixels by
// reconstructing the world position of neighbouring pixels and suppresses the
// line on steep surfaces (walls, trunks, fences). It is a slope test, not a
// true terrain test: flat roofs and bridge decks still count as "terrain".
in highp vec4 vScreenPos;
layout(location=1)  uniform highp vec4 uGridColor;     // boundary line colour (alpha = line opacity)
layout(location=2)  uniform highp vec4 uCurrentColor;  // current-region boundary colour (alpha = line opacity)
layout(location=3)  uniform highp mat4 uInvViewproj;   // inverse camera viewproj (locations 3-6)
layout(location=7)  uniform highp sampler2D uDepthBuffer;
layout(location=8)  uniform highp mat4 uViewproj;      // camera viewproj (locations 8-11)
layout(location=12) uniform highp vec4 uWindow;        // grid extent in region coords: xMin, zMin, xMax, zMax
layout(location=13) uniform highp vec2 uPlayerRegion;  // (rx, rz) the player stands in
layout(location=14) uniform highp vec2 uLine;          // x: half thickness (px); y: outline extra (px, 0 = off)
layout(location=15) uniform highp vec2 uViewport;      // game view size (px)
layout(location=16) uniform highp vec2 uTerrain;       // x: 1 = terrain-only on; y: min normal.y = cos(max slope)
out highp vec4 fragColor;

// world units per region edge = UNITS_PER_TILE(512) * TILES_PER_REGION(64)
const highp float REGION_UNITS = 32768.0;

// screen-px distance from the projected pixel p0 to `snapped`, this pixel's
// world point moved onto a boundary plane (huge if it lands behind the camera)
highp float boundaryDistPx(highp vec4 p0, highp vec3 snapped) {
  highp vec4 h = uViewproj * vec4(snapped, 1.0);
  if (h.w < 1e-6) { return 1e9; }
  return length((h.xy / h.w - p0.xy / p0.w) * 0.5 * uViewport);
}

// reconstruct the world position of the pixel at depth-buffer uv (ok = false
// for sky / degenerate pixels, whose position is meaningless)
highp vec3 worldAtUV(highp vec2 uv, out bool ok) {
  highp float d = texture(uDepthBuffer, uv).r;
  highp vec3 ndc = vec3(uv * 2.0 - 1.0, d * 2.0 - 1.0);
  highp vec4 wh = uInvViewproj * vec4(ndc, 1.0);
  ok = d < 0.9999 && abs(wh.w) > 1e-6;
  return ok ? wh.xyz / wh.w : vec3(0.0);
}

// pick the screen-space tangent along one screen axis: of the two neighbours
// (one each side of the centre pixel), use the one whose world point is closer
// to the centre, so a depth discontinuity on one side (an object silhouette)
// doesn't corrupt the normal. ok = false if both sides are unusable.
highp vec3 tangentAxis(highp vec3 centre, highp vec2 uv, highp vec2 step, out bool ok) {
  bool okA, okB;
  highp vec3 wA = worldAtUV(uv + step, okA);
  highp vec3 wB = worldAtUV(uv - step, okB);
  ok = okA || okB;
  if (okA && okB) {
    highp vec3 dA = wA - centre;
    highp vec3 dB = centre - wB;
    return dot(dA, dA) <= dot(dB, dB) ? dA : dB;
  }
  return okA ? (wA - centre) : (centre - wB);
}

// 0..1 factor for how "terrain-like" the surface under this pixel is: 1 on
// flat-enough ground, 0 on surfaces steeper than the configured max slope,
// with a small smoothstep band between so the cutoff doesn't shimmer
highp float terrainFactor(highp vec3 centre, highp vec2 uv) {
  bool okX, okY;
  highp vec3 tx = tangentAxis(centre, uv, vec2(1.0 / uViewport.x, 0.0), okX);
  highp vec3 ty = tangentAxis(centre, uv, vec2(0.0, 1.0 / uViewport.y), okY);
  if (!okX || !okY) { return 0.0; }   // neighbours are sky: isolated sliver, not ground
  highp vec3 n = cross(tx, ty);
  highp float len = length(n);
  if (len < 1e-9) { return 0.0; }
  // abs: winding/flip conventions don't matter, only how far from horizontal-
  // facing the surface is
  highp float ny = abs(n.y) / len;
  return smoothstep(uTerrain.y - 0.06, min(uTerrain.y + 0.06, 1.0), ny);
}

void main() {
  // "leave this pixel untouched" outputs all-zero rather than discarding (a
  // no-op under alpha blending, and control flow stays uniform).
  highp vec2 uv = (vScreenPos.xy / vScreenPos.w) * 0.5 + 0.5;
  highp float sceneDepth = texture(uDepthBuffer, uv).r;
  if (sceneDepth >= 0.9999) { fragColor = vec4(0.0); return; }   // sky: no grid

  highp vec3 ndc = vec3(vScreenPos.xy / vScreenPos.w, sceneDepth * 2.0 - 1.0);
  highp vec4 wh = uInvViewproj * vec4(ndc, 1.0);
  if (abs(wh.w) < 1e-6) { fragColor = vec4(0.0); return; }
  highp vec3 world = wh.xyz / wh.w;

  // continuous region coordinates, and the nearest boundary on each axis
  highp vec2 rc = world.xz / REGION_UNITS;
  highp vec2 nearest = floor(rc + 0.5);

  // Window gate, applied per boundary rather than per pixel so lines on the
  // window's edge keep their full thickness (mirrors the old geometry: x
  // boundaries at [xMin..xMax] spanning z in [zMin..zMax], and vice versa).
  bool validX = nearest.x >= uWindow.x && nearest.x <= uWindow.z
             && rc.y >= uWindow.y && rc.y <= uWindow.w;
  bool validZ = nearest.y >= uWindow.y && nearest.y <= uWindow.w
             && rc.x >= uWindow.x && rc.x <= uWindow.z;
  if (!validX && !validZ) { fragColor = vec4(0.0); return; }

  // the pixel's distance to each boundary in screen px. p0 re-projects the
  // reconstructed point through the forward matrix so both ends of the
  // distance measurement share the same round trip.
  highp vec4 p0 = uViewproj * vec4(world, 1.0);
  if (p0.w < 1e-6) { fragColor = vec4(0.0); return; }
  highp float dx = validX ? boundaryDistPx(p0, vec3(nearest.x * REGION_UNITS, world.y, world.z)) : 1e9;
  highp float dz = validZ ? boundaryDistPx(p0, vec3(world.x, world.y, nearest.y * REGION_UNITS)) : 1e9;

  bool hitX = dx <= uLine.x;
  bool hitZ = dz <= uLine.x;
  bool hitOutline = min(dx, dz) <= uLine.x + uLine.y;
  if (!hitX && !hitZ && !hitOutline) { fragColor = vec4(0.0); return; }

  // terrain-only: fade the line out on steep surfaces (walls, trunks). Only
  // evaluated for pixels that would actually be painted, so the extra depth
  // samples cost nothing along the rest of the boundary window.
  highp float t = 1.0;
  if (uTerrain.x > 0.5) {
    t = terrainFactor(world, uv);
    if (t <= 0.0) { fragColor = vec4(0.0); return; }
  }

  // a boundary is drawn in the current-region colour where it forms the border
  // of the region the player stands in (matching the old cyan box overlay)
  highp vec2 cell = floor(rc);
  bool cyanX = hitX && (nearest.x == uPlayerRegion.x || nearest.x == uPlayerRegion.x + 1.0)
                    && cell.y == uPlayerRegion.y;
  bool cyanZ = hitZ && (nearest.y == uPlayerRegion.y || nearest.y == uPlayerRegion.y + 1.0)
                    && cell.x == uPlayerRegion.x;

  if (cyanX || cyanZ) {
    fragColor = vec4(uCurrentColor.rgb, uCurrentColor.a * t);
  } else if (hitX || hitZ) {
    fragColor = vec4(uGridColor.rgb, uGridColor.a * t);
  } else {
    // black outline ring for contrast, fading in step with the line opacity
    fragColor = vec4(0.0, 0.0, 0.0, 0.6 * uGridColor.a * t);
  }
}

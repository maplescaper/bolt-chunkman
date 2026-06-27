// Vertical "curtain" wall shader (companion to lineshader.vert/frag).
// Draws one vertical quad per draw call: a wall rising from a ground base-line
// (uBase: x0,z0 -> x1,z1) up through a Y range (uYrange: bottom, top). The
// per-vertex attribute vCorner selects the corner via {0,1}x{0,1}: .x runs
// along the base line, .y runs from bottom to top. Used to grey out the world
// beyond the region the player is standing in, extending up toward the sky.
layout(location=0) in highp vec2 vCorner;       // (s along base, t bottom->top)
layout(location=1) uniform highp vec4 uBase;     // x0, z0, x1, z1 (world units)
layout(location=2) uniform highp vec2 uYrange;   // yBottom, yTop (world units)
layout(location=3) uniform highp mat4 viewproj;
out highp vec4 vScreenPos;
void main() {
  highp float wx = mix(uBase.x, uBase.z, vCorner.x);
  highp float wz = mix(uBase.y, uBase.w, vCorner.x);
  highp float wy = mix(uYrange.x, uYrange.y, vCorner.y);
  highp vec4 clip = viewproj * vec4(wx, wy, wz, 1.0);
  vScreenPos = clip;
  // bolt convention: flip y (matches lineshader.vert)
  gl_Position = clip * vec4(1.0, -1.0, 1.0, 1.0);
}

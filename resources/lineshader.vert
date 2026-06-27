layout(location=0) in highp vec2 vXZ;
layout(location=1) uniform highp vec3 vP1;
layout(location=2) uniform highp vec3 vP2;
layout(location=3) uniform highp mat4 viewproj;
layout(location=4) uniform highp float halfThickness;
layout(location=5) uniform highp vec4 uColor;
layout(location=6) uniform highp vec2 screenSize;
layout(location=7) uniform highp float uSegStart;
layout(location=8) uniform highp float uSegFrac;
layout(location=16) uniform highp float uRoundedCaps;
out highp vec4 vColor;
out highp float vEdgeCoord;
out highp float vGlobalPos;
out highp vec4 vScreenPos;
out highp vec2 vP1Screen;
out highp vec2 vP2Screen;
void main() {
  highp vec3 dir = vP2 - vP1;
  highp float len = length(dir);
  highp vec3 dirN = dir / max(len, 0.001);
  vec4 clip0 = viewproj * vec4(vP1, 1.0);
  vec4 clip1 = viewproj * vec4(vP2, 1.0);
  vec2 ndc0 = clip0.xy / clip0.w;
  vec2 ndc1 = clip1.xy / clip1.w;
  vec2 lineDir = normalize(ndc1 - ndc0);
  vec2 perp = vec2(-lineDir.y, lineDir.x) * halfThickness * vXZ.x / screenSize * 2.0;
  // Screen-space endpoint positions (bolt convention: y=0 at top)
  vP1Screen = (ndc0 + 1.0) * screenSize * 0.5;
  vP2Screen = (ndc1 + 1.0) * screenSize * 0.5;
  // Extend the quad past both endpoints by halfThickness pixels for round caps
  highp float screenLen = length(vP2Screen - vP1Screen);
  highp float capFrac = (uRoundedCaps > 0.5 && screenLen > 0.001) ? halfThickness / screenLen : 0.0;
  highp float t = vXZ.y * (1.0 + 2.0 * capFrac) - capFrac;
  highp vec3 wpos = vP1 + dirN * len * t;
  vec4 clip = viewproj * vec4(wpos, 1.0);
  clip.xy += perp * clip.w;
  gl_Position = clip * vec4(1.0, -1.0, 1.0, 1.0);
  vScreenPos = clip;
  vColor = uColor;
  vEdgeCoord = vXZ.x;
  vGlobalPos = uSegStart + clamp(t, 0.0, 1.0) * uSegFrac;
}

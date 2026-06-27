// Companion fragment shader for fillshader.vert. Paints a flat translucent
// colour onto the wall, discarding fragments that sit behind scene geometry so
// the tint only covers what's actually beyond the wall (distant terrain, sky)
// and lets things in front of it (your own region) show through normally.
// The wall is real, fixed world geometry, so this depth test is stable under
// camera zoom (unlike a flat ground plane at a guessed height).
in highp vec4 vScreenPos;
layout(location=4) uniform highp vec4 uColor;
layout(location=5) uniform highp sampler2D uDepthBuffer;
layout(location=6) uniform highp vec2 uScreenSize;
out highp vec4 fragColor;
void main() {
  vec2 depthUV = (vScreenPos.q > 0.0)
    ? ((vScreenPos.st / vScreenPos.q) + vec2(1.0, 1.0)) / 2.0
    : gl_FragCoord.xy / uScreenSize; // fallback
  float sceneDepth = texture(uDepthBuffer, depthUV).r;
  float atFarPlane = step(0.99, sceneDepth);
  float occluded = (1.0 - atFarPlane) * step(sceneDepth + 0.001, gl_FragCoord.z);
  if (occluded > 0.5) discard;       // something is in front of the wall here
  fragColor = uColor;
}

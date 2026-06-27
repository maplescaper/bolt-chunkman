in highp vec4 vColor;
in highp float vEdgeCoord;
in highp float vGlobalPos;
in  highp vec4 vScreenPos;
in highp vec2 vP1Screen;
in highp vec2 vP2Screen;
layout(location=9) uniform highp float halfThicknessFs;
layout(location=10) uniform highp float uTime;
layout(location=11) uniform highp float uNumPulses;
layout(location=12) uniform highp float uSpeed;
layout(location=13) uniform highp float uRainbow;
layout(location=14) uniform highp sampler2D uDepthBuffer;
layout(location=15) uniform highp vec2 uScreenSize;
layout(location=16) uniform highp float uRoundedCaps;
out highp vec4 fragColor;
void main() {
  if (uRoundedCaps > 0.5) {
    // Capsule SDF in screen space.
    // gl_FragCoord.y=0 is bottom; vP1Screen.y=0 is top, so flip y.
    highp vec2 fragPos = vec2(gl_FragCoord.x, uScreenSize.y - gl_FragCoord.y);
    highp vec2 pa = fragPos - vP1Screen;
    highp vec2 ba = vP2Screen - vP1Screen;
    highp float h = clamp(dot(pa, ba) / max(dot(ba, ba), 0.001), 0.0, 1.0);
    highp float dist = length(pa - ba * h) - halfThicknessFs;
    if (dist > 0.5) discard;
  }

  // color
  highp float hue = fract(vGlobalPos + uTime * 0.0000001) * 6.0;
  highp float r = clamp(abs(hue - 3.0) - 1.0, 0.0, 1.0);
  highp float g = clamp(2.0 - abs(hue - 2.0), 0.0, 1.0);
  highp float b = clamp(2.0 - abs(hue - 4.0), 0.0, 1.0);
  highp vec3 rainbow = vec3(r, g, b);
  highp float phase = fract(vGlobalPos * uNumPulses - uTime * uSpeed) * 3.14159 * 2.0;
  highp float glow = max(0.0, sin(phase));
  highp vec3 color = mix(vColor.rgb, rainbow, uRainbow) + glow * 0.1;

  // depth: is something in front of us?
  vec2 depthUV = (vScreenPos.q > 0.0)
    ? ((vScreenPos.st / vScreenPos.q) + vec2(1.0, 1.0)) / 2.0
    : gl_FragCoord.xy / uScreenSize; // fallback
  float sceneDepth = texture(uDepthBuffer, depthUV).r;
  float atFarPlane = step(0.99, sceneDepth);
  float occluded = (1.0 - atFarPlane) * step(sceneDepth + 0.001, gl_FragCoord.z);

  // Make colour darker
  vec3 finalColor = mix(color, color * 0.3, occluded);
  float finalAlpha = mix(vColor.a, vColor.a * 0.1, occluded);
  fragColor = vec4(finalColor, finalAlpha);
}

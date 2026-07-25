// Full-screen world-position grey-out.
// Draws one screen-filling quad; the fragment shader reconstructs each pixel's
// real world position from the depth buffer and greys it based on the chunk it
// actually belongs to. Because every pixel is judged by where it *is*, the grey
// boundary hugs the terrain exactly and is completely camera-independent, so it
// can't float or smear the way a camera-projected overlay would.
layout(location=0) in highp vec2 vCorner;   // unit square {0,1}x{0,1}
out highp vec4 vScreenPos;                  // unflipped clip (for depth UV + reconstruction)
void main() {
  highp vec2 ndc = vCorner * 2.0 - 1.0;
  vScreenPos = vec4(ndc, 0.0, 1.0);
  // bolt convention: flip y (matches lineshader.vert)
  gl_Position = vScreenPos * vec4(1.0, -1.0, 1.0, 1.0);
}

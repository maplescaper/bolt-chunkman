// Full-screen world-position vertex stage, shared by greyshader.frag (the
// locked-chunk grey-out) and gridshader.frag (the region boundary lines).
// Draws one screen-filling quad; the fragment shader reconstructs each pixel's
// real world position from the depth buffer and paints it based on where that
// point actually lies. Because every pixel is judged by where it *is*, the
// result hugs the terrain exactly and is completely camera-independent, so it
// can't float or smear the way a camera-projected overlay would.
layout(location=0) in highp vec2 vCorner;   // unit square {0,1}x{0,1}
out highp vec4 vScreenPos;                  // unflipped clip (for depth UV + reconstruction)
void main() {
  highp vec2 ndc = vCorner * 2.0 - 1.0;
  vScreenPos = vec4(ndc, 0.0, 1.0);
  // bolt convention: flip y
  gl_Position = vScreenPos * vec4(1.0, -1.0, 1.0, 1.0);
}

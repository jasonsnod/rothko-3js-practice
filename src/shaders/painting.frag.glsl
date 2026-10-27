// MAX_LAYERS and MAX_SHAPES are injected as defines by Painting.js.

uniform float uTime;
uniform float uAspect; // canvas width / height

uniform vec3 uCanvas;  // bare canvas color, linear RGB
uniform float uGrain;

uniform int uLayerCount;
uniform vec3 uLayerColor[MAX_LAYERS];      // pigment body color, linear RGB
uniform vec4 uLayerPigment[MAX_LAYERS];    // x = hiding, y = glaze
uniform vec4 uLayerThickness[MAX_LAYERS];  // x = base, y = variation, z = scale
uniform vec4 uLayerEdge[MAX_LAYERS];       // x = width, y = breath, z = warp, w = breakup
uniform vec4 uLayerStrokes[MAX_LAYERS];    // x = patch size, y = angle, z = spread, w = interior
uniform vec4 uLayerStreaks[MAX_LAYERS];    // xy = streak frequency (along, across)
uniform vec4 uLayerShapes[MAX_LAYERS];     // x = first shape, y = shape count, z = seed

uniform vec4 uShapes[MAX_SHAPES];          // xy = center, zw = half-size (normalized)

uniform int uDebugView;   // 0 = final, 1 = thickness, 2 = coverage, 3 = strokes
uniform int uDebugLayer;

varying vec2 vUv;

// --- noise -----------------------------------------------------------------

float hash12(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

float hash13(vec3 p) {
  p = fract(p * 0.1031);
  p += dot(p, p.zyx + 31.32);
  return fract((p.x + p.y) * p.z);
}

float valueNoise2(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);

  return mix(
    mix(hash12(i + vec2(0, 0)), hash12(i + vec2(1, 0)), u.x),
    mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), u.x), u.y);
}

float valueNoise(vec3 p) {
  vec3 i = floor(p);
  vec3 f = fract(p);
  vec3 u = f * f * (3.0 - 2.0 * f);

  return mix(
    mix(mix(hash13(i + vec3(0, 0, 0)), hash13(i + vec3(1, 0, 0)), u.x),
        mix(hash13(i + vec3(0, 1, 0)), hash13(i + vec3(1, 1, 0)), u.x), u.y),
    mix(mix(hash13(i + vec3(0, 0, 1)), hash13(i + vec3(1, 0, 1)), u.x),
        mix(hash13(i + vec3(0, 1, 1)), hash13(i + vec3(1, 1, 1)), u.x), u.y),
    u.z);
}

// Fractal noise in roughly [0, 1].
float fbm(vec3 p) {
  float sum = 0.0;
  float amp = 0.5;
  for (int i = 0; i < 5; i++) {
    sum += amp * valueNoise(p);
    p = p * 2.03 + 17.1;
    amp *= 0.5;
  }
  return sum;
}

// Cheaper 2D fractal noise (3 octaves), normalized to roughly [0, 1].
float fbm2(vec2 p) {
  float sum = 0.0;
  float amp = 0.5;
  for (int i = 0; i < 3; i++) {
    sum += amp * valueNoise2(p);
    p = p * 2.03 + 17.1;
    amp *= 0.5;
  }
  return sum / 0.875;
}

// --- brush strokes ---------------------------------------------------------
//
// All stroke functions are static (no time input): strokes are anchored to the
// canvas. See docs/README.md, section 7.5.

// Bristle streaks in a stroke's own frame, where x runs along the stroke.
// Stretched noise: low frequency along the stroke, high frequency across it.
// The shear offsets each lattice row along the stroke, so the noise grid's
// cell boundaries don't line up across neighbouring streaks (which would show
// as "ladder rungs" across the stroke).
float streaks(vec2 q, vec2 freq, float seed) {
  vec2 s = q * freq + seed * 13.7;
  s.x += s.y * 1.618;
  return 0.65 * valueNoise2(s) + 0.35 * valueNoise2(s * vec2(1.7, 2.3) + 4.1);
}

// One set of strokes. The canvas is divided into patches; each patch has its
// own stroke angle, length and pressure. The four nearest patches are blended
// with smooth weights, so directions change gradually and overlap where
// patches meet.
float strokeSet(vec2 p, vec4 strokes, vec2 freq, float angleOffset, float seed, float minPressure) {
  float size = strokes.x;
  vec2 g = p / size - 0.5;
  vec2 cell = floor(g);
  vec2 w = smoothstep(0.0, 1.0, fract(g));

  float sum = 0.0;
  for (int k = 0; k < 4; k++) {
    vec2 o = vec2(mod(float(k), 2.0), floor(float(k) / 2.0));
    vec2 c = cell + o;
    float salt = seed * 17.0 + angleOffset * 3.0;
    float hAngle = hash13(vec3(c, salt));
    float hPressure = hash13(vec3(c, salt + 7.0));
    float hLength = hash13(vec3(c, salt + 13.0));

    float angle = strokes.y + angleOffset + (hAngle - 0.5) * 2.0 * strokes.z;
    float cs = cos(angle);
    float sn = sin(angle);
    vec2 q = mat2(cs, -sn, sn, cs) * (p - (c + 0.5) * size);

    float v = streaks(q, freq * vec2(mix(0.6, 1.5, hLength), 1.0), seed + hAngle * 31.0);
    // Light pressure leaves a fainter mark: pull toward the neutral 0.5.
    v = mix(0.5, v, mix(minPressure, 1.0, hPressure * hPressure));

    float weight = mix(1.0 - w.x, w.x, o.x) * mix(1.0 - w.y, w.y, o.y);
    sum += weight * v;
  }
  return sum;
}

// Two crossing stroke sets, combined so that whichever is stronger shows,
// blending softly where they're similar. Returns roughly [0, 1].
//
// The crossing set is applied with lighter pressure, so it dominates only in
// some patches. Two equally strong sets everywhere read as woven fabric
// rather than loose crisscrossing.
float strokeField(vec2 p, vec4 strokes, vec2 freq, float seed) {
  float a = strokeSet(p, strokes, freq, 0.0, seed, 0.35);
  float b = strokeSet(p, strokes, freq, 1.5708, seed + 0.5, 0.0);
  float s = 0.5 * (a + b + sqrt((a - b) * (a - b) + 0.002));
  // Blending patches and sets compresses the range; stretch it back out.
  return clamp((s - 0.56) * 2.4 + 0.5, 0.0, 1.0);
}

// --- shapes ----------------------------------------------------------------

// Signed distance to an axis-aligned box: negative inside, positive outside.
float sdBox(vec2 p, vec2 center, vec2 halfSize) {
  vec2 d = abs(p - center) - halfSize;
  return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

// Distance to the union of a layer's shapes (nearest shape wins).
float layerDistance(vec2 p, vec2 scale, vec4 shapes) {
  int first = int(shapes.x + 0.5);
  int count = int(shapes.y + 0.5);
  float d = 1e5;
  for (int j = 0; j < MAX_SHAPES; j++) {
    if (j < first) continue;
    if (j >= first + count) break;
    vec4 s = uShapes[j];
    d = min(d, sdBox(p, s.xy * scale, s.zw * scale));
  }
  return d;
}

void main() {
  float t = uTime;

  // Work in aspect-corrected space so widths and noise are isotropic.
  vec2 scale = vec2(uAspect, 1.0);
  vec2 p = vUv * scale;

  vec3 color = uCanvas;
  float debugValue = 0.0;

  for (int i = 0; i < MAX_LAYERS; i++) {
    if (i >= uLayerCount) break;

    vec4 pigment = uLayerPigment[i];
    vec4 thick = uLayerThickness[i];
    vec4 edge = uLayerEdge[i];
    vec4 strokeParams = uLayerStrokes[i];
    vec4 shapes = uLayerShapes[i];
    float seed = shapes.z;

    float strokes = strokeField(p, strokeParams, uLayerStreaks[i].xy, seed);

    // Domain warping: measure distance from a distorted position, so outlines
    // wander irregularly at large scale. Static.
    vec2 warped = p;
    if (edge.z > 0.0) {
      vec2 q = p * 3.0 + seed * 5.1;
      warped += edge.z * 2.0 * (vec2(fbm2(q), fbm2(q + vec2(5.2, 1.3))) - 0.5);
    }

    // Borders grow and recede around their rest position. Fine-grained, so
    // individual strokes reach further or pull back independently. The noise
    // evolves through time rather than scrolling, and averages to zero.
    float breath = (fbm(vec3(p * 12.0 + seed * 11.0, t * 0.5)) - 0.5) * 2.0;
    float d = layerDistance(warped, scale, shapes) + breath * edge.y;

    // Position across the border band: -1 at its inner side, +1 at its outer.
    float u = d / max(edge.x, 1e-4);

    // Smooth falloff (as before), and a dry-brush falloff where paint
    // survives only where strokes are strong enough. The bar rises toward
    // the outside, so the border breaks into fingers along the strokes.
    float smoothExtent = 1.0 - smoothstep(-1.0, 1.0, u);
    float bar = mix(-0.15, 1.15, clamp(u * 0.5 + 0.5, 0.0, 1.0));
    // A wide transition keeps the fingers feathered rather than splintered.
    float brushExtent = smoothstep(bar - 0.25, bar + 0.25, strokes);
    float extent = mix(smoothExtent, brushExtent, edge.w);

    // Uneven application: broad patches plus brush streaks. Static.
    float patches = (fbm(vec3(p * thick.z + seed * 7.0, seed * 3.0)) - 0.5) * 2.0;
    float thickness = thick.x * extent
      * max(1.0 + thick.y * patches, 0.0)
      * max(1.0 + strokeParams.w * (strokes * 2.0 - 1.0), 0.0);

    // Glaze model: thin paint tints what lies beneath (transmission), thick
    // paint hides it (coverage). See docs/README.md, section 7.4.
    vec3 body = uLayerColor[i];
    vec3 transmission = pow(max(body, vec3(1e-4)), vec3(pigment.y * thickness));
    float coverage = 1.0 - exp(-pigment.x * thickness);
    color = mix(color * transmission, body, coverage);

    if (i == uDebugLayer) {
      // Thickness 1 shows as mid-grey; 2 or more as white.
      if (uDebugView == 1) debugValue = thickness * 0.5;
      else if (uDebugView == 2) debugValue = coverage;
      else if (uDebugView == 3) debugValue = strokes;
    }
  }

  if (uDebugView != 0) {
    // Raw values, deliberately not color-managed.
    gl_FragColor = vec4(vec3(clamp(debugValue, 0.0, 1.0)), 1.0);
    return;
  }

  // Static canvas grain, tied to the painting rather than the screen.
  float grain = hash13(vec3(floor(vUv * vec2(2048.0 * uAspect, 2048.0)), 0.0)) - 0.5;
  color *= 1.0 + grain * uGrain;

  gl_FragColor = vec4(max(color, 0.0), 1.0);

  #include <colorspace_fragment>
}

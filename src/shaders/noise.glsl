// Noise and brush stroke functions, shared by fields.frag.glsl (which bakes
// the static fields) and painting.frag.glsl (which needs fbm for breathing).
// Painting.js prepends this file to both shaders.

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
// canvas. See docs/README.md, section 7.7.

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

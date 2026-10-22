// MAX_RECTS is injected as a define by Painting.js.

uniform float uTime;
uniform float uAspect; // canvas width / height

uniform vec3 uGround;

uniform int uRectCount;
uniform vec4 uRects[MAX_RECTS];       // xy = center, zw = half-size (normalized)
uniform vec3 uRectColors[MAX_RECTS];  // linear RGB
uniform vec4 uRectParams[MAX_RECTS];  // x = softness, y = opacity, z = seed

uniform float uDrift;
uniform float uEdgeNoise;
uniform float uWashNoise;
uniform float uGrain;

varying vec2 vUv;

// --- noise -----------------------------------------------------------------

float hash13(vec3 p) {
  p = fract(p * 0.1031);
  p += dot(p, p.zyx + 31.32);
  return fract((p.x + p.y) * p.z);
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

// --- shapes ----------------------------------------------------------------

// Signed distance to an axis-aligned box: negative inside, positive outside.
float sdBox(vec2 p, vec2 center, vec2 halfSize) {
  vec2 d = abs(p - center) - halfSize;
  return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

void main() {
  float t = uTime;

  // Work in aspect-corrected space so softness and noise are isotropic.
  vec2 scale = vec2(uAspect, 1.0);
  vec2 p = vUv * scale;

  vec3 color = uGround;
  color *= 1.0 + uWashNoise * (fbm(vec3(p * 2.5, t * 0.3)) - 0.5) * 2.0;

  for (int i = 0; i < MAX_RECTS; i++) {
    if (i >= uRectCount) break;

    vec4 rect = uRects[i];
    vec4 params = uRectParams[i];
    float softness = params.x;
    float opacity = params.y;
    float seed = params.z;

    // Slow, independent wandering of each rectangle's position and size.
    vec2 center = rect.xy * scale + uDrift * vec2(
      sin(t * 0.71 + seed * 3.1),
      cos(t * 0.53 + seed * 1.7)
    );
    vec2 halfSize = rect.zw * scale + uDrift * 0.6 * vec2(
      sin(t * 0.37 + seed * 2.3),
      cos(t * 0.29 + seed * 4.1)
    );

    // Roughen the edge with evolving noise so it breathes rather than slides.
    float edge = (fbm(vec3(p * 6.0 + seed * 11.0, t * 0.5)) - 0.5) * 2.0;
    float d = sdBox(p, center, halfSize) + edge * uEdgeNoise;

    float mask = 1.0 - smoothstep(-softness, softness, d);

    // Uneven, layered-wash density inside the field.
    vec3 fill = uRectColors[i];
    fill *= 1.0 + uWashNoise * (fbm(vec3(p * 3.0 + seed * 7.0, t * 0.4)) - 0.5) * 2.0;

    color = mix(color, fill, mask * opacity);
  }

  // Static canvas grain, tied to the painting rather than the screen.
  float grain = hash13(vec3(floor(vUv * vec2(2048.0 * uAspect, 2048.0)), 0.0)) - 0.5;
  color *= 1.0 + grain * uGrain;

  gl_FragColor = vec4(max(color, 0.0), 1.0);

  #include <colorspace_fragment>
}

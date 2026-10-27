// MAX_LAYERS and MAX_SHAPES are injected as defines by Painting.js.

uniform float uTime;
uniform float uAspect; // canvas width / height

uniform vec3 uCanvas;  // bare canvas color, linear RGB
uniform float uGrain;

uniform int uLayerCount;
uniform vec3 uLayerColor[MAX_LAYERS];      // pigment body color, linear RGB
uniform vec4 uLayerPigment[MAX_LAYERS];    // x = hiding, y = glaze
uniform vec4 uLayerThickness[MAX_LAYERS];  // x = base, y = variation, z = scale
uniform vec4 uLayerEdge[MAX_LAYERS];       // x = width, y = breath
uniform vec4 uLayerShapes[MAX_LAYERS];     // x = first shape, y = shape count, z = seed

uniform vec4 uShapes[MAX_SHAPES];          // xy = center, zw = half-size (normalized)

uniform int uDebugView;   // 0 = final color, 1 = thickness, 2 = coverage
uniform int uDebugLayer;

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
    vec4 shapes = uLayerShapes[i];
    float seed = shapes.z;

    // Borders grow and recede around their rest position. The noise evolves
    // through time rather than scrolling, so edges breathe instead of slide.
    float breath = (fbm(vec3(p * 6.0 + seed * 11.0, t * 0.5)) - 0.5) * 2.0;
    float d = layerDistance(p, scale, shapes) + breath * edge.y;

    // 1 inside the shape, thinning to 0 across the border.
    float extent = 1.0 - smoothstep(-edge.x, edge.x, d);

    // Uneven application. Static and anchored to the canvas: paint that has
    // been laid down doesn't move.
    float patches = (fbm(vec3(p * thick.z + seed * 7.0, seed * 3.0)) - 0.5) * 2.0;
    float thickness = max(thick.x * extent * (1.0 + thick.y * patches), 0.0);

    // Glaze model: thin paint tints what lies beneath (transmission), thick
    // paint hides it (coverage). See docs/README.md, section 7.4.
    vec3 body = uLayerColor[i];
    vec3 transmission = pow(max(body, vec3(1e-4)), vec3(pigment.y * thickness));
    float coverage = 1.0 - exp(-pigment.x * thickness);
    color = mix(color * transmission, body, coverage);

    if (i == uDebugLayer) {
      // Thickness 1 shows as mid-grey; 2 or more as white.
      debugValue = uDebugView == 1 ? thickness * 0.5 : coverage;
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

// Bakes the static (time-independent) fields into one slice of a texture
// array. This runs once at startup, and again whenever settings change, rather
// than every frame. See docs/README.md, section 7.10.
//
// MAX_LAYERS is injected as a define, and noise.glsl is prepended, by
// Painting.js.
//
// Each layer's slice holds, in 8-bit channels:
//   R = brush stroke field, 0 to 1
//   G = thickness patches, as raw fBm (about 0 to 1; decoded as (g - 0.5) * 2)
//   B, A = shaped layers: warp offset x, y, as raw fBm (decoded the same way)
//   B    = band layers:   presence (patchiness), 0 to 1
// Slice MAX_LAYERS holds exposure / 2 in R (so exposures up to 2 fit).

uniform float uAspect;
uniform int uLayer;  // which slice to bake; MAX_LAYERS = exposure

uniform vec4 uLayerThickness[MAX_LAYERS];
uniform vec4 uLayerStrokes[MAX_LAYERS];
uniform vec4 uLayerStreaks[MAX_LAYERS];
uniform vec4 uLayerShapes[MAX_LAYERS];
uniform vec4 uLayerBand[MAX_LAYERS];
uniform vec4 uLight;

varying vec2 vUv;

void main() {
  vec2 p = vUv * vec2(uAspect, 1.0);

  if (uLayer == MAX_LAYERS) {
    // How much light has fallen on this point over the years, around 1: more
    // on the side the light comes from, and never perfectly even.
    float side = dot(vUv - 0.5, uLight.xy) * 2.0;  // about -1 (away) to +1 (toward)
    float uneven = (fbm2(p * 1.5 + 41.0) - 0.5) * 2.0;
    float exposure = max(1.0 + uLight.z * side + uLight.w * uneven, 0.0);
    gl_FragColor = vec4(exposure * 0.5, 0.0, 0.0, 1.0);
    return;
  }

  vec4 shapes = uLayerShapes[uLayer];
  float seed = shapes.z;

  float strokes = strokeField(p, uLayerStrokes[uLayer], uLayerStreaks[uLayer].xy, seed);
  float patches = fbm(vec3(p * uLayerThickness[uLayer].z + seed * 7.0, seed * 3.0));

  if (shapes.w < -0.5) {
    // Shaped layer: domain-warp offset (scaled by edge.warp at draw time, so
    // changing the warp amount doesn't need a re-bake).
    vec2 q = p * 3.0 + seed * 5.1;
    vec2 warp = vec2(fbm2(q), fbm2(q + vec2(5.2, 1.3)));
    gl_FragColor = vec4(strokes, patches, warp);
  } else {
    // Band layer: present along some stretches of the border, nearly absent
    // along others. fBm values cluster around 0.5, so a narrow window around
    // it splits the border into roughly half present, half absent.
    vec4 band = uLayerBand[uLayer];
    float presence = smoothstep(0.4, 0.6, fbm2(p * band.w + seed * 9.3));
    gl_FragColor = vec4(strokes, patches, presence, 0.0);
  }
}

// Paints the canvas every frame.
//
// MAX_LAYERS and MAX_SHAPES are injected as defines, and noise.glsl is
// prepended, by Painting.js. Everything that doesn't change over time (brush
// strokes, thickness patches, warp, band patchiness, light exposure) is baked
// into uFields by fields.frag.glsl and only looked up here; see
// docs/README.md, section 7.10. The breathing borders are the only noise
// still computed per frame.

uniform float uTime;
uniform float uAspect; // canvas width / height

uniform vec3 uCanvas;  // bare canvas color, linear RGB
uniform float uGrain;

uniform int uLayerCount;
uniform vec3 uLayerColor[MAX_LAYERS];      // pigment body color, linear RGB
uniform vec4 uLayerPigment[MAX_LAYERS];    // x = hiding, y = glaze
uniform vec4 uLayerThickness[MAX_LAYERS];  // x = base, y = variation
uniform vec4 uLayerEdge[MAX_LAYERS];       // x = width, y = breath, z = warp, w = breakup
uniform vec4 uLayerStrokes[MAX_LAYERS];    // w = interior
uniform vec4 uLayerShapes[MAX_LAYERS];     // x = first shape, y = shape count, z = seed,
                                           // w = outlined layer (band layers), else -1
uniform vec4 uLayerBand[MAX_LAYERS];       // x = width, y = offset, z = patchiness

uniform vec4 uShapes[MAX_SHAPES];          // xy = center, zw = half-size (normalized)

// Baked static fields: one slice per layer, plus slice MAX_LAYERS for exposure.
// Channel layout is documented in fields.frag.glsl.
uniform sampler2DArray uFields;

uniform vec4 uFade;   // x = progress (0 to strength), y = washout, z = thin paint

uniform int uDebugView;   // 0 = final, 1 = thickness, 2 = coverage, 3 = strokes,
                          // 4 = exposure, 5 = fade
uniform int uDebugLayer;

varying vec2 vUv;

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

// Distance to a layer's border as it actually appears: measured from a
// warped position, and shifted over time by the breathing noise.
float borderDistance(vec2 p, vec2 scale, vec4 shapes, vec4 edge, vec2 warp, float t) {
  // Domain warping: measure distance from a distorted position, so outlines
  // wander irregularly at large scale. The offset is baked; only its amount
  // (edge.z) is applied here.
  vec2 warped = p + edge.z * 2.0 * (warp - 0.5);
  float d = layerDistance(warped, scale, shapes);

  // Borders grow and recede around their rest position. Fine-grained, so
  // individual strokes reach further or pull back independently. The noise
  // evolves through time rather than scrolling, and averages to zero.
  // Skipped for layers that don't breathe: this is the costliest per-frame
  // work left in the shader.
  if (edge.y > 0.0) {
    float breath = (fbm(vec3(p * 12.0 + shapes.z * 11.0, t * 0.5)) - 0.5) * 2.0;
    d += breath * edge.y;
  }
  return d;
}

// Dry-brush falloff: paint survives only where strokes clear the bar. As the
// bar rises, only the strongest strokes reach, so the paint breaks into
// fingers along the brushwork. A wide transition keeps the fingers feathered
// rather than splintered.
//
// `amount` runs 0 (no paint) to 1 (full paint). The bar runs from -0.25 to
// 1.25 so that, with the 0.25 transition, amount 0 and 1 give exactly 0 and 1
// for every stroke value in [0, 1]. A narrower range let the strongest
// strokes leak faint stray streaks far from any border.
float brushed(float amount, float strokes) {
  float bar = mix(1.25, -0.25, amount);
  return smoothstep(bar - 0.25, bar + 0.25, strokes);
}

void main() {
  float t = uTime;

  // Work in aspect-corrected space so widths and noise are isotropic.
  vec2 scale = vec2(uAspect, 1.0);
  vec2 p = vUv * scale;

  vec3 color = uCanvas;
  float debugValue = 0.0;
  float light = texture(uFields, vec3(vUv, float(MAX_LAYERS))).r * 2.0;

  // First pass: look up each layer's baked fields, and compute the border
  // distance for every shaped layer. Band layers outline another layer's
  // border, and may sit beneath it, so distances are computed up front and
  // shared rather than recomputed per band.
  vec4 fields[MAX_LAYERS];
  float borders[MAX_LAYERS];
  for (int i = 0; i < MAX_LAYERS; i++) {
    if (i >= uLayerCount) break;
    vec4 shapes = uLayerShapes[i];
    fields[i] = texture(uFields, vec3(vUv, float(i)));
    borders[i] = shapes.w < -0.5
      ? borderDistance(p, scale, shapes, uLayerEdge[i], fields[i].ba, t)
      : 1e5;
  }

  for (int i = 0; i < MAX_LAYERS; i++) {
    if (i >= uLayerCount) break;

    vec4 pigment = uLayerPigment[i];
    vec4 thick = uLayerThickness[i];
    vec4 edge = uLayerEdge[i];
    vec4 shapes = uLayerShapes[i];
    float strokes = fields[i].r;

    float extent;
    if (shapes.w < -0.5) {
      // Shaped layer: full inside, thinning to nothing across the border.
      // u is the position across the border band: -1 inner side, +1 outer.
      float u = borders[i] / max(edge.x, 1e-4);
      float smoothExtent = 1.0 - smoothstep(-1.0, 1.0, u);
      float across = clamp(0.5 - 0.5 * u, 0.0, 1.0);
      extent = mix(smoothExtent, brushed(across, strokes), edge.w);
    } else {
      // Band layer: paint concentrated along another layer's border, so it
      // follows that border's warping and breathing exactly.
      vec4 band = uLayerBand[i];
      float d = borders[int(shapes.w + 0.5)];
      float profile = exp(-pow((d - band.y) / max(band.x, 1e-4), 2.0));
      extent = mix(profile, brushed(profile, strokes), edge.w);

      // Patchiness: present along some stretches, nearly absent along others.
      extent *= mix(1.0, fields[i].b, band.z);
    }

    // Uneven application: broad patches plus brush streaks. Both baked.
    float patches = (fields[i].g - 0.5) * 2.0;
    float thickness = thick.x * extent
      * max(1.0 + thick.y * patches, 0.0)
      * max(1.0 + uLayerStrokes[i].w * (strokes * 2.0 - 1.0), 0.0);

    // Fading, part 1: pigment lost to light. Thin paint has less pigment to
    // lose, so it fades sooner (thickness 1 fades at the normal rate).
    float thinFactor = mix(1.0, 2.0 / (1.0 + thickness), uFade.z);
    float fade = clamp(uFade.x * light * thinFactor, 0.0, 0.95);

    // Less pigment means less absorption. With absorption = -ln(color), scaling
    // absorption by (1 - fade) is the same as raising the color to that power:
    // it lightens each channel in proportion to how strongly it absorbed.
    // Faded paint also hides a little less of what's beneath.
    vec3 body = pow(max(uLayerColor[i], vec3(1e-4)), vec3(1.0 - fade));
    float hiding = pigment.x * (1.0 - 0.3 * fade);

    // Glaze model: thin paint tints what lies beneath (transmission), thick
    // paint hides it (coverage). See docs/README.md, section 7.4.
    vec3 transmission = pow(body, vec3(pigment.y * thickness));
    float coverage = 1.0 - exp(-hiding * thickness);
    color = mix(color * transmission, body, coverage);

    if (i == uDebugLayer) {
      // Thickness 1 shows as mid-grey; 2 or more as white.
      if (uDebugView == 1) debugValue = thickness * 0.5;
      else if (uDebugView == 2) debugValue = coverage;
      else if (uDebugView == 3) debugValue = strokes;
      // Fade 0.5 shows as white.
      else if (uDebugView == 5) debugValue = fade * 2.0;
    }
  }

  // Exposure 1 shows as mid-grey.
  if (uDebugView == 4) debugValue = light * 0.5;

  if (uDebugView != 0) {
    // Raw values, deliberately not color-managed.
    gl_FragColor = vec4(vec3(clamp(debugValue, 0.0, 1.0)), 1.0);
    return;
  }

  // Fading, part 2: washing out. An aged paint surface scatters light
  // chalkily, so the color loses saturation and gains a faint pale veil.
  // This is a surface effect, so it applies once, over all the layers.
  float wash = clamp(uFade.x * light, 0.0, 1.0) * uFade.y;
  float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
  color = mix(color, vec3(luma), wash * 0.6) + wash * vec3(0.03, 0.026, 0.025);

  // Static canvas grain, tied to the painting rather than the screen.
  float grain = hash13(vec3(floor(vUv * vec2(2048.0 * uAspect, 2048.0)), 0.0)) - 0.5;
  color *= 1.0 + grain * uGrain;

  gl_FragColor = vec4(max(color, 0.0), 1.0);

  #include <colorspace_fragment>
}

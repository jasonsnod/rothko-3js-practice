# Design notes

This document explains what exists in the project so far and why it was built
this way. The top-level [README](../README.md) covers how to run the project.
This one covers the reasoning behind it.

Many choices here had several reasonable options. Where that was the case, the
alternatives and the reason for the pick are written down, so they can be
revisited deliberately rather than by accident.

---

## 1. Goal and guiding principle

The target is Mark Rothko's *Black on Maroon* (1958), one of the Seagram murals
([Tate, T01163](https://www.tate.org.uk/art/artworks/rothko-black-on-maroon-t01163)).
It should be "constantly slightly shifting".

Rothko's paintings are not crisp geometry. They are thin, layered washes of
pigment with soft, uneven edges that seem to hover. So the guiding principle
throughout is:

> **The motion should be felt, not seen.** Every animated quantity is small and
> slow, and edges should *breathe* rather than *slide*.

That principle drives most of the decisions below.

---

## 2. What exists

```
rothko-practice/
├── index.html                      Page shell; loads CSS and main.js
├── package.json                    three + lil-gui + vite
├── src/
│   ├── main.js                     Renderer, camera, resize, animation loop
│   ├── Painting.js                 Builds the plane + ShaderMaterial from config
│   ├── FadeClock.js                Counts viewing time across visits (fading)
│   ├── config.js                   Layers, paint, motion, fading (tuning lives here)
│   ├── debug.js                    Live tuning panel, loaded only with ?debug
│   ├── style.css                   Fullscreen layout, wall color
│   └── shaders/
│       ├── noise.glsl              Noise + brush stroke functions (shared)
│       ├── fields.vert.glsl        Full-screen pass for baking
│       ├── fields.frag.glsl        Bakes the static fields into a texture array
│       ├── painting.vert.glsl      Passes UVs through
│       └── painting.frag.glsl      Paints the canvas every frame
└── docs/
    ├── README.md                   This file
    └── PLAN.md                     Roadmap for the paint-realism work
```

Data flows in one direction:

```
config.js ──► Painting.js ──(uniforms)──► painting.frag.glsl
    ▲             ▲
debug.js ─────────┤  (edits config, then calls painting.sync())
                  │
main.js ──(time since last frame)
                  │
FadeClock.js ◄────┘  (viewing time, saved in the browser)
```

---

## 3. Tooling

### Vite as the dev server and bundler

**Options considered:** plain `<script type="module">` with an import map,
Vite, webpack, Parcel.

**Chosen: Vite.** It is what the three.js
[installation guide](https://threejs.org/manual/pages/installation.html) recommends.
It starts with no configuration, and hot reloading makes tuning shader values
quick. It also gives us `?raw` imports (see [§6.1](#61-glsl-in-separate-files-imported-with-raw)),
which an import-map setup can't do.

### Vite is pinned to v6

The machine this was built on runs Node 21.5. Vite 7 and later require Node
`^20.19.0 || >=22.12.0` ([Vite: getting started](https://vite.dev/guide/#scaffolding-your-first-vite-project)),
and Node 21 falls outside that range. Vite 6 runs on it. This is a pin about
the environment, not about features: after upgrading to Node 22 LTS, bumping
Vite to the latest major should need no code changes.

### No TypeScript, no framework

This is a single-canvas project with a few hundred lines of JavaScript. A
framework (React Three Fiber and similar) or a TypeScript build step would add
more structure than code. Either can be added later if the project grows.

---

## 4. Rendering approach: a shader-painted plane

This is the most important decision in the project.

**Options considered:**

1. **Multiple meshes**: one `PlaneGeometry` per rectangle, stacked with
   transparency.
2. **Canvas 2D drawn into a texture**: paint with the 2D canvas API and upload
   it as a [`CanvasTexture`](https://threejs.org/docs/pages/CanvasTexture.html).
3. **One plane whose fragment shader computes every pixel.**

**Chosen: option 3.** Every visual quality we want is a per-pixel function:

| Quality wanted | Why a shader does it well |
| --- | --- |
| Feathered, irregular edges | A distance field plus `smoothstep` gives soft edges of any width, and noise can perturb the distance. Meshes have hard polygon edges. |
| Edges that "breathe" | Noise evaluated with time as a third dimension makes edges change continuously, which is very hard to do with geometry. |
| Uneven paint thickness and layering | Each pixel can see every layer's color and thickness at once and combine them with any formula (§7.4). Mesh blending is limited to a few fixed formulas, and Canvas 2D blends in the wrong color space. |
| Continuous animation | Changing one uniform per frame re-paints everything on the GPU. Option 2 would re-draw and re-upload a texture every frame. |

The trade-off is that the composition lives in GLSL rather than in the
three.js scene graph, so scene-level tools such as raycasting and per-object
transforms don't apply to individual rectangles. For a flat painting that is
acceptable.

Relevant docs: [`ShaderMaterial`](https://threejs.org/docs/pages/ShaderMaterial.html),
[`PlaneGeometry`](https://threejs.org/docs/pages/PlaneGeometry.html),
[`Mesh`](https://threejs.org/docs/pages/Mesh.html).

### `ShaderMaterial` rather than `RawShaderMaterial`

[`RawShaderMaterial`](https://threejs.org/docs/pages/RawShaderMaterial.html)
gives no built-in uniforms or chunks. `ShaderMaterial` automatically provides
`projectionMatrix`, `modelViewMatrix`, `position`, and `uv`, plus access to
three.js shader chunks via `#include`. We rely on two of those:

- the matrices and attributes in the vertex shader;
- `#include <colorspace_fragment>` for correct output color (see
  [§7.6](#76-color-management)).

---

## 5. Scene setup ([`src/main.js`](../src/main.js))

### Orthographic camera

**Options considered:** `PerspectiveCamera` or `OrthographicCamera`.

**Chosen: [`OrthographicCamera`](https://threejs.org/docs/pages/OrthographicCamera.html).**
A painting is flat and seen face-on. Orthographic projection has no
foreshortening, so one unit of world space covers the same number of pixels
everywhere. That makes letterboxing exact (see below). If we later want a
"standing in the gallery" view, that would be the time to switch to a
perspective camera.

The near and far planes (`0.1` to `10`) with the camera at `z = 1` just need to
contain the plane at `z = 0`. Their exact values don't matter.

### Letterboxing: fitting the painting in any window

The plane is built at a size of `aspect × 1` world units, with
`aspect = 381.2 / 266.7 ≈ 1.43` taken from the painting's real dimensions. On
resize, we work out how many world units tall the view must be so the painting
fits in **both** directions:

```js
const fitHeight = Math.max(1, canvas.aspect / viewAspect) / painting.viewportFill;
```

- In a wide window, height is the constraint, so the view is `1` unit tall.
- In a narrow window, width is the constraint, so the view must be
  `aspect / viewAspect` units tall.
- Dividing by `viewportFill` (0.86) leaves a margin of "wall".

Then the camera's `left`, `right`, `top`, and `bottom` are set from that, and
[`updateProjectionMatrix()`](https://threejs.org/docs/pages/OrthographicCamera.html)
is called. That call is required whenever frustum values change. For more on
resize handling, see the manual's
[Responsive Design](https://threejs.org/manual/pages/responsive.html) chapter.

**Why scale the camera instead of the mesh:** the shader works in the plane's
UV space (0 to 1), so the painting's internal coordinates never change. Only
the "view onto the wall" changes.

### Renderer settings

- **`setPixelRatio(Math.min(devicePixelRatio, 2))`**: high-DPI screens can
  report 3 or more. The fragment shader runs once per physical pixel, and a 3×
  ratio costs about 2.25× more than 2×, with no visible gain for a soft painting.
  This cap is common three.js practice; see
  [Responsive Design: handling HD-DPI displays](https://threejs.org/manual/pages/responsive.html#handling-hd-dpi-displays).
- **`antialias: false`**: MSAA smooths *geometry* edges. The only geometry edge
  here is the plane's border, which is axis-aligned. Every soft edge inside the
  painting is computed by the shader, so MSAA would cost memory and fill rate
  for nothing.
- **Clear color read from CSS**: `setClearColor(getComputedStyle(body).backgroundColor)`.
  The wall color is defined once, in [`style.css`](../src/style.css), and the
  WebGL canvas matches it. Changing it in one place updates both.

See [`WebGLRenderer`](https://threejs.org/docs/pages/WebGLRenderer.html).

### Animation loop: `setAnimationLoop` + `Timer`

- [`renderer.setAnimationLoop`](https://threejs.org/docs/pages/WebGLRenderer.html)
  is used instead of a hand-written `requestAnimationFrame` loop. It's the
  three.js-recommended form and is required if WebXR is ever added.
- [`Timer`](https://threejs.org/docs/pages/Timer.html) is used instead of the
  older `Clock`. `Timer` was designed to fix `Clock`'s conceptual problems, and
  `timer.connect(document)` uses the
  [Page Visibility API](https://developer.mozilla.org/en-US/docs/Web/API/Page_Visibility_API)
  so time doesn't jump forward after the tab has been hidden. For a piece meant
  to drift slowly, a sudden jump would be the most noticeable kind of glitch.

---

## 6. The `Painting` class ([`src/Painting.js`](../src/Painting.js))

`Painting` turns the human-friendly config into shader uniforms. It exposes
`mesh`, `aspect`, `timeScale`, `fadeClock`, `sync()`, `setDebugView()`,
`fadeProgress()`, `bakeFields()`, `update(deltaSeconds)`, and `dispose()`.
It's constructed with the config, a `FadeClock` (§7.9), and the renderer,
which it needs to bake the static fields (§7.10).

It keeps the config objects **by reference**. The debug panel edits those
objects directly and then calls `sync()`, which rewrites every uniform value
from the config. Rewriting everything on each change is simpler than tracking
which value changed, and costs microseconds for a few dozen numbers.
Uniform values are sent to the GPU each frame anyway, as the
[`ShaderMaterial`](https://threejs.org/docs/pages/ShaderMaterial.html) docs
note, so a changed value appears on the next frame.

### 6.1 GLSL in separate files, imported with `?raw`

**Options considered:** inline template strings in JS, or separate `.glsl` files.

**Chosen: separate files**, loaded with Vite's
[`?raw` suffix](https://vite.dev/guide/assets#importing-asset-as-string), which
imports a file's contents as a string. Separate files get GLSL syntax
highlighting and linting in editors, and they keep JS and GLSL diffs apart.
No plugin (such as `vite-plugin-glsl`) is needed. The one piece of code
shared between shaders, `noise.glsl`, is simply prepended to both fragment
shaders as a string in `Painting.js` (`noise + paintingFragment`). A plugin
providing `#include` between our own files would only be worth it with
several shared files.

### 6.2 Fixed-size uniform arrays with `MAX_LAYERS` and `MAX_SHAPES`

GLSL uniform arrays must have a size known at compile time, so the shader
declares arrays such as `uLayerColor[MAX_LAYERS]` and loops like this:

```glsl
for (int i = 0; i < MAX_LAYERS; i++) {
  if (i >= uLayerCount) break;
  ...
}
```

The loop bound is a **constant** and the real count is checked with `break`.
GLSL ES 1.00 (WebGL 1) requires constant loop bounds
([GLSL ES 1.00 spec, Appendix A](https://registry.khronos.org/OpenGL/specs/es/2.0/GLSL_ES_Specification_1.00.pdf)).
WebGL 2 relaxes this, but the constant-bound pattern works everywhere and lets
drivers unroll the loop.

`MAX_LAYERS` and `MAX_SHAPES` are passed in through `ShaderMaterial.defines`,
so JS and GLSL share a single source for each value. Unused slots are padded with zero vectors.
Plain JS arrays of `Vector4` and `Color` can be assigned directly to `vec4[]`
and `vec3[]` uniforms. The [`Uniform`](https://threejs.org/docs/pages/Uniform.html)
docs don't cover arrays. The behavior lives in the renderer's uniform upload
code ([`WebGLUniforms.js`](https://github.com/mrdoob/three.js/blob/dev/src/renderers/webgl/WebGLUniforms.js)),
which flattens such arrays into one typed array before sending them to the GPU.
Limits of 6 layers and 12 shapes are generous for a Rothko; raising either is
a one-line change.

### 6.3 Packing the per-layer data

A layer can own several shapes (the maroon layer has two windows), so shapes
and layers are stored separately:

| Uniform | Contents | Why packed this way |
| --- | --- | --- |
| `uShapes[j]` (`vec4`) | center.xy, half-size.xy | All shapes from all layers in one flat array. This is exactly what the box distance function needs (§7.2). |
| `uLayerShapes[i]` (`vec4`) | first shape index, shape count, seed, outlined layer | Which slice of `uShapes` the layer owns. For a band layer, `w` is the index of the layer it outlines; otherwise −1. |
| `uLayerBand[i]` (`vec4`) | width, offset, patchiness, patch scale | Band layers only (§7.8). |
| `uFade` (`vec4`) | progress, washout, thin paint | Fading (§7.9). Progress is updated every frame; the rest on `sync()`. |
| `uLight` (`vec4`) | light direction xy, gradient, variation | Where the fading light came from (§7.9). The direction is converted from degrees to a unit vector in JS. |
| `uLayerColor[i]` (`vec3`) | linear RGB | `THREE.Color` converts it automatically (§7.6). |
| `uLayerPigment[i]` (`vec4`) | hiding, glaze | Paint properties (§7.4). |
| `uLayerThickness[i]` (`vec4`) | base, variation, scale | How the paint was applied (§7.4). |
| `uLayerEdge[i]` (`vec4`) | width, breath, warp, breakup | Border shape and motion (§7.5). |
| `uLayerStrokes[i]` (`vec4`) | patch size, angle, spread, interior | Brush stroke layout (§7.7). Angles are converted to radians in JS. |
| `uLayerStreaks[i]` (`vec4`) | 1 / length, 1 / width | Streak size, converted to noise frequencies in JS so the shader multiplies instead of divides. |

The two shader materials, painting and baking, share the same uniform
**objects**, so one `sync()` updates both.

Grouping scalars into `vec4`s keeps the number of separate uniforms down and
leaves spare slots for later phases. Indices are stored as floats and rounded
back to `int` in the shader. Integer uniform arrays would also work, but
packing them alongside the seed is simpler.

The config is written as edges (`x0, y0, x1, y1`) because that's easiest to
read and adjust. The shader wants center plus half-size. That conversion
happens in JS, so the shader does no extra work per pixel.

The **seed** is a number from 1 to 100 derived from the layer's **name** with
an [FNV-1a hash](https://en.wikipedia.org/wiki/Fowler%E2%80%93Noll%E2%80%93Vo_hash_function).
It offsets the noise so layers don't share the same patches or breathe in
lockstep. The first version used the layer's position (`i + 1`). That meant
inserting the two red band layers would have silently changed the strokes of
every layer above them. Seeding by name keeps each layer's pattern stable
when layers are added or reordered. The trade-off is that renaming a layer
changes its pattern.

### 6.4 Time accumulates per frame

`update(deltaSeconds)` adds `deltaSeconds × motion.speed × timeScale` to
`uTime` each frame. The earlier version computed `elapsed × speed` instead,
which works until speed changes: then all of past time is rescaled at once
and the painting visibly jumps. Accumulating makes speed changes in the debug
panel smooth.

All shader frequencies are relative to `uTime`, so `motion.speed` alone sets
how fast the painting moves without changing the character of the motion.
`timeScale` is a separate preview multiplier that is deliberately **not** in
the config, so "copy config" can never save a sped-up value by accident.

`update()` also advances the fade clock by the same (preview-scaled) time and
sets the fade progress uniform. Scaling fading by the preview multiplier
means fading can be previewed too, at the cost that previewing advances the
saved progress in that browser. The debug panel's **reset fading** undoes
that.

---

## 7. The fragment shader ([`src/shaders/painting.frag.glsl`](../src/shaders/painting.frag.glsl))

The shader runs in this order for every pixel:

Before any of this, the static fields (brush strokes, thickness patches,
warp, band patchiness, light exposure) have been **baked** into a texture
array (§7.10). The per-frame shader looks them up rather than computing them.

1. Start with the color of bare canvas.
2. **First pass:** for each layer, look up its baked fields. For every shaped
   layer, measure the distance to its border from a **warped** position,
   shifted by the breathing noise. Store these in small arrays.
3. **Second pass**, for each layer bottom to top (ground, red-outer, black,
   red-windows, maroon):
   1. Read the layer's **brush stroke field** (§7.7).
   2. Work out how much of the layer is present at this pixel: inside its
      shapes for a shaped layer, or along another layer's border for a band
      layer (§7.8). Across borders, the strokes decide where paint survives
      (dry-brush breakup).
   3. Turn that into a **thickness** of paint.
   4. **Fade** the layer's pigment by how much light it has had, more where
      the paint is thin (§7.9).
   5. Composite the layer's paint over the color so far using the **glaze
      model**: thin paint tints what's beneath; thick paint hides it.
4. **Wash out** the surface: desaturate it slightly and add a faint pale veil,
   in proportion to fading (§7.9).
5. Apply canvas grain.
6. Convert to the output color space.

If a debug view is selected, step 3 also records the chosen layer's thickness
or coverage, and that value is shown in grayscale instead of the color.

### 7.1 Aspect-corrected coordinates

UVs run from 0 to 1 on both axes, but the canvas is about 1.43 times wider than
it is tall. Without correction, an edge width of `0.03` would be wider
horizontally than vertically, and noise blobs would be stretched sideways.
So the shader works in `p = vUv * vec2(uAspect, 1.0)` and scales shape
centers and sizes the same way. That keeps every edge width, breath, and noise
value isotropic (the same in all directions).

A consequence: these widths are measured as a fraction of the canvas
**height**. Across the width, an edge width of `0.025` covers about
`0.025 / 1.43 ≈ 0.0175` of the canvas.

### 7.2 Rectangles as signed distance fields

```glsl
float sdBox(vec2 p, vec2 center, vec2 halfSize) {
  vec2 d = abs(p - center) - halfSize;
  return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}
```

This is the standard exact 2D box distance function from Inigo Quilez's
[2D distance functions](https://iquilezles.org/articles/distfunctions2d/). It
returns how far a point is from the box edge: negative inside, positive
outside. A distance field, rather than a simple inside/outside test, is what
makes everything else possible:

- **Soft edges:** `1.0 - smoothstep(-width, width, d)` turns distance into a
  value (`extent`) that fades from 1 inside to 0 outside across a band
  `2 × width` wide, centered on the edge. See
  [`smoothstep`](https://registry.khronos.org/OpenGL-Refpages/gl4/html/smoothstep.xhtml).
- **Breathing edges:** adding noise to `d` before the `smoothstep` pushes the
  edge in and out by a noise-controlled amount (§7.5).
- **Several shapes per layer:** taking the `min` of the distances to each shape
  gives the distance to their union. That's how the maroon layer's two windows
  share one set of paint settings.

The exact box distance has a crease along each corner's diagonal, where the
nearest edge switches from horizontal to vertical. Through a wide soft edge,
that showed faintly as a mitred corner. Domain warping (§7.5) now breaks these
up.

### 7.3 Noise: value noise and fBm

**Options considered:** Perlin or simplex gradient noise, value noise, or a
precomputed noise texture.

**Chosen: 3D value noise, summed into fractal Brownian motion (fBm).**

- **Value noise** blends random values placed on a lattice. It's the simplest
  smooth noise to write and read, and it has no dependencies. Its known weakness
  is visible blockiness, which mostly comes from the grid. That disappears once
  several octaves are summed and everything is low-frequency and soft-edged, as
  it is here. Simplex noise would be the upgrade if artifacts ever show. See
  [The Book of Shaders: Noise](https://thebookofshaders.com/11/).
- **fBm** adds five octaves, each at about double the frequency and half the
  amplitude of the last. That gives large slow variation with finer detail on
  top, which reads as "natural". See
  [The Book of Shaders: Fractal Brownian Motion](https://thebookofshaders.com/13/)
  and [Inigo Quilez: fBm](https://iquilezles.org/articles/fbm/). The octave
  multiplier is `2.03` rather than exactly `2.0`, and each octave is offset by
  `17.1`. Both stop the octaves' lattices lining up, which would otherwise
  create visible grid artifacts.
- **Noise is 3D so time can be the third axis.** Sampling
  `fbm(vec3(p, t))` and moving slowly through `t` makes the 2D pattern
  *evolve* in place instead of *scrolling*. Scrolling is exactly the "sliding"
  look we want to avoid.
- **The hash** is `hash13`, from Dave Hoskins'
  [Hash without Sine](https://www.shadertoy.com/view/4djSRW). The common
  `fract(sin(x) * 43758.5)` hash gives different results on different GPUs
  because `sin` precision varies. Hoskins' version uses only arithmetic, so it
  looks the same everywhere.

### 7.4 Paint layers: thickness and the glaze model

Rothko built his colors from several thin layers of paint. How each layer looks
depends on **how much paint is at each point**, so every layer computes a
thickness value per pixel:

```glsl
float thickness = base × extent
  × (1 + variation × patches)
  × (1 + interior × (strokes × 2 − 1));
```

- `extent` is the shape mask: 1 inside, falling to 0 across the border, with
  the border broken up by brush strokes (§7.5).
- `patches` is low-frequency fBm in the range −1 to 1, with a per-layer seed.
  It models paint applied unevenly. It has **no time input**: paint that has
  been laid down doesn't move. `thickness.scale` sets the patch size.
- `strokes` is the brush stroke field (§7.7), 0 to 1. `strokes.interior`
  sets how much streaks of thicker and thinner paint show inside the shape.

Each variation factor is clamped at zero, so a large `variation` can't
produce negative paint.

**Options considered for combining layers:**

1. Plain alpha blending, `mix(below, color, opacity)`. This is what the first
   version used.
2. Multiply blending, `below × color`.
3. A two-property glaze model.

**Chosen: option 3.** Real paint does two things at once, and each simpler
option captures only one:

- It **tints** light passing through it, like colored glass. Multiplying alone
  does this, but can only ever darken: maroon over black would stay black.
- It **hides** what's beneath by scattering light back. Alpha blending alone
  does this, but thin paint just fades toward the color below instead of
  tinting it.

The model used:

```glsl
vec3  transmission = pow(body, vec3(glaze × thickness));  // tint, per channel
float coverage     = 1.0 - exp(-hiding × thickness);      // how opaque
color = mix(color × transmission, body, coverage);
```

- **Transmission** follows the
  [Beer–Lambert law](https://en.wikipedia.org/wiki/Beer%E2%80%93Lambert_law):
  light surviving a layer falls off exponentially with thickness, separately
  for each color channel. Writing it as `pow(body, k)` is the same as
  `exp(-absorption × k)` with `absorption = -ln(body)`. That lets the config
  give one ordinary color per layer instead of absorption numbers.
- **Coverage** uses the same exponential form: each extra unit of thickness
  hides a fixed fraction of what's still visible beneath it.
- The structure loosely follows the
  [Kubelka–Munk](https://en.wikipedia.org/wiki/Kubelka%E2%80%93Munk_theory)
  model painters' color science is built on. That model separates absorption
  and scattering in the same way, but is much more involved to compute.

What this gives the painting: thin black over maroon becomes a deep reddish
brown rather than grey, because the black tints the maroon instead of fading
toward it. Thick maroon over black still covers it. And thin patches anywhere
let the layers below show through more, which is what makes layered paint
look deep.

The **canvas** sits beneath everything as the starting color. The ground is
thick and opaque enough that it barely shows, but it's there for thin spots,
and for the fading planned in Phase 4.

### 7.5 Borders and surface

A border is built in four steps, each with its own config key:

| Step | Implementation | Config key |
| --- | --- | --- |
| **1. Warp** | Distance is measured from `p + warp × noise(p)` instead of `p`, using two channels of 2D fBm as an offset vector. This is [domain warping](https://iquilezles.org/articles/warp/): it bends the straight outline into an irregular, hand-drawn one at large scale. Static. | `edge.warp` |
| **2. Breathe** | 3D fBm at a fine spatial frequency (`p * 12.0`), with time as the third axis, is added to the distance. Borders grow and recede minutely around their rest position. This is the painting's only ongoing motion. | `edge.breath` |
| **3. Band** | The distance becomes a position across the border band, `u = d / width`: −1 at the inner side, +1 at the outer. | `edge.width` |
| **4. Break up** | Two falloffs are blended. **Smooth**: `1 − smoothstep(−1, 1, u)`, the plain soft edge. **Dry-brush**: paint survives only where `strokes > bar`, where the bar rises from −0.25 at the inner side to 1.25 at the outer side. Strong strokes reach furthest out, so the border breaks into fingers that follow the brushwork. | `edge.breakup` |

**Why the breathing works per stroke:** the stroke field is static, but the
breathing noise shifts `u`, which moves the bar. As the bar falls, a given
stroke's finger reaches further; as it rises, the finger pulls back. The
strokes themselves never move, only how far each one reaches. The breathing
frequency was raised from 6 to 12 so that neighbouring fingers breathe
independently rather than as one wave.

**Why the dry-brush transition is wide** (`smoothstep(bar − 0.25, bar + 0.25, strokes)`):
a narrow transition turned each finger into a hard, tapered splinter, which
read as fur or grass. Rothko's edges are ragged but feathered.

**Why the bar runs from −0.25 to 1.25:** with a ±0.25 transition, those limits
guarantee exactly no paint outside the band and full paint inside it, for any
stroke value from 0 to 1. The Phase 2 version used −0.15 to 1.15, which let
the very strongest strokes leak through everywhere as faint stray streaks,
far from any border. That was visible as stray red flecks on the black field.
The shader's `brushed()` function holds this logic, shared by shaped and
band layers.

The first version also slowly moved each rectangle's position and size. That
was removed: the shifting should come from the borders of the paint changing,
not from the shapes travelling. Breathing noise averages to zero, so borders
always return toward where they started.

**Canvas grain** (`surface.grain`) is a fixed per-texel hash (no time input)
that multiplies the final color.

**Grain is anchored to the painting**, not the screen. It's sampled from
`floor(vUv * 2048)` rather than `gl_FragCoord`, so it scales with the painting
like real canvas weave and doesn't shift when the window is resized. It's
**multiplicative** (`color *= 1.0 + n`) so near-black areas stay near-black. An
additive offset would lift the blacks and look washed out.

### 7.6 Color management

Colors in the config are ordinary sRGB hex values, the same as in a color
picker or CSS. Blending, however, must happen in **linear** space to be
physically correct. Two pieces handle this:

1. **Input:** with three.js color management enabled (the default since
   r152), `new THREE.Color('#79505c')` converts sRGB hex to linear RGB.
   So the uniforms arrive in the shader as linear values.
2. **Output:** `ShaderMaterial` doesn't convert its output automatically.
   The final line, `#include <colorspace_fragment>`, applies the conversion
   from linear to the renderer's `outputColorSpace` (sRGB by default).

Without step 2 the painting would look noticeably too dark. With both steps,
the on-screen color of a flat field matches its hex value in the config.

See the manual's [Color management](https://threejs.org/manual/pages/color-management.html)
chapter and the [`ColorManagement` source](https://github.com/mrdoob/three.js/blob/dev/src/math/ColorManagement.js).

With a `pigment.color` of exactly `#000000`, `pow(0, k)` would be undefined
for `k = 0`. Colors are clamped to at least `1e-4` before the `pow` to avoid
that. `max(color, 0.0)` before output guards against the grain multiplier
ever pushing a channel negative.

Debug views output their raw grayscale values and return **before**
`colorspace_fragment`, so a thickness of 1 (shown as 0.5) really is mid-grey
on screen rather than being brightened by the sRGB conversion.

### 7.7 Brush strokes

The stroke field is a value from 0 to 1 at every point, and is **static**:
strokes are anchored to the canvas. It feeds both the dry-brush borders
(§7.5) and the interior thickness (§7.4). The `strokes` debug view shows it.

**Options considered:**

1. **One direction of stretched noise everywhere.** Cheap, but reads as
   combed or brushed metal, with no crisscrossing.
2. **Stretched noise rotated by a smoothly varying angle field.** Rotating
   coordinates by an angle that changes across the canvas distorts distances
   far from the rotation origin, causing fanning and pinching artifacts.
3. **Patches with their own direction, blended together.** Each patch of
   canvas gets its own stroke angle, measured around the patch's own center so
   there's no distortion. Neighbouring patches are blended smoothly.

**Chosen: option 3**, applied twice: a main set of strokes and a crossing set
at about 90°. This gives loose crisscrossing.

How one set is computed (`strokeSet` in the shader):

- The canvas is divided into a grid of patches, `strokes.size` across.
- Each pixel looks at its **four nearest patch centers**. For each, a hash of
  the patch's grid position gives it an angle (`strokes.angle` ± up to
  `strokes.spread`), a pressure, and a length jitter.
- The pixel's position is rotated into each patch's stroke frame, and
  **streaks** are sampled there: value noise stretched along the stroke
  (frequency `1 / strokes.length`) and squeezed across it
  (frequency `1 / strokes.width`). This is anisotropic noise, the standard way
  to get streaky, directional texture from ordinary noise.
- The four results are blended with smooth bilinear weights. Where patches
  meet, both directions show partially, so strokes overlap rather than
  stopping at a seam.
- **Pressure** pulls a patch's streaks toward a neutral 0.5, so some patches
  are faint and others are bold, like varied brush pressure.

The two sets are combined with a **soft maximum**,
`0.5 × (a + b + sqrt((a − b)² + k))`: whichever set is stronger shows, with a
smooth blend where they're similar. The result is then contrast-stretched,
because averaging patches and sets compresses the range toward 0.5.

Two artifacts came up while tuning, with their fixes:

- **"Ladder rungs" across streaks.** Value noise has a lattice; stretched
  along the stroke, every streak changed value at the same lattice lines,
  forming rungs across the stroke. Shearing the noise coordinates
  (`s.x += s.y × 1.618`) offsets each lattice row along the stroke by an
  irrational amount, so the cell boundaries no longer line up.
- **Woven, plaid-like grids.** Where both sets were equally strong, they formed
  tight grids that read as fabric. The crossing set now uses lighter, more
  varied pressure (minimum 0 versus 0.35, with pressure squared to skew it
  lighter), so it dominates only in some patches.

**Cost:** per layer, the stroke field takes 2 sets × 4 patches × 2 noise
samples, plus 6 hashes per patch. It was the most expensive part of the
shader until it was moved into the baking pass (§7.10).

### 7.8 Band layers: the red along borders

In the original, a warmer red shows unevenly along the borders between
shapes, as if an extra layer of red was painted there. Band layers model
that paint.

**Options considered:**

1. **Tint the existing borders red** inside the black and maroon layers. This
   is simple, but the red would be part of those layers' paint rather than a
   layer of its own. It couldn't sit *beneath* the black and show through it.
2. **Ordinary shaped layers** with their own rectangles traced around the
   borders. Their outlines wouldn't follow the black's warping and breathing,
   and the coordinates would have to be kept in sync by hand.
3. **Band layers that name the layer they outline**, reusing that layer's
   actual border distance.

**Chosen: option 3.** A band layer has `band.outlines` instead of shapes. Its
paint follows the outlined border exactly, including the warping and the
breathing, and moving the black field automatically moves its red border too.

How the band's paint is placed:

- **Profile:** a Gaussian across the border,
  `exp(−((d − offset) / width)²)`, where `d` is the outlined layer's border
  distance. It peaks on the border (or `offset` outside it) and fades smoothly
  both ways.
- **Breakup:** the same dry-brush function as shaped borders, driven by the
  band's own stroke field, so the red's edges follow brushwork too.
- **Patchiness:** low-frequency noise splits the border into stretches where
  the red is present and stretches where it's almost absent. The window is
  narrow (`smoothstep(0.4, 0.6, …)`) because fBm values cluster around 0.5; a
  wider window left the "absent" stretches at about 40% strength.

**Two bands, at two depths.** Where a layer sits in the stack decides how its
red shows:

| Band | Outlines | Position | How it shows |
| --- | --- | --- | --- |
| `red-outer` | `black` | Under the black | As a halo past the black's edge, and through the black's thin, broken edge fingers. |
| `red-windows` | `maroon` | Between black and maroon | Over the black around the windows, and through the maroon's ragged edges. |

A band beneath the windows' border but under the black, like `red-outer`,
wouldn't show at all: the black there is at full thickness. That's why the
window band sits above the black.

**Why border distances are computed in a first pass:** `red-outer` sits
*below* the black, so when the shader reaches it, the black's border hasn't
been computed yet. Computing every shaped layer's border distance up front,
into a local array, lets any band read any layer's border, in any order, and
avoids computing the expensive warp and breathing noise twice. Indexing that
array with a value only known at runtime is allowed in GLSL ES 3.00, which
three.js uses for WebGL 2 (see the arrays section of the
[GLSL ES 3.00 spec](https://registry.khronos.org/OpenGL/specs/es/3.0/GLSL_ES_Specification_3.00.pdf)).
GLSL ES 1.00, used by WebGL 1, didn't allow this.

### 7.9 Fading

The painting's colors slowly get lighter and slightly washed out while it's
on view, as if from decades of light exposure. Alongside the breathing
borders, this is the second way the painting changes over time.

#### How time is counted ([`src/FadeClock.js`](../src/FadeClock.js))

**Decisions:**

- **Viewing time, not wall-clock time.** The clock advances by the same frame
  times as the animation. Browsers pause
  [`requestAnimationFrame`](https://developer.mozilla.org/en-US/docs/Web/API/Window/requestAnimationFrame)
  in hidden tabs, and `Timer` doesn't report the gap afterwards (§5), so
  fading only happens while someone could be looking.
- **Resumes exactly between visits.** The total is saved in
  [`localStorage`](https://developer.mozilla.org/en-US/docs/Web/API/Window/localStorage)
  under `rothko-practice:fade-seconds`. Other options considered were
  restarting on every load, or partially recovering while away; resuming
  exactly was chosen.
- **When it saves:** every 5 seconds of viewing, and when the page is hidden
  ([`visibilitychange`](https://developer.mozilla.org/en-US/docs/Web/API/Document/visibilitychange_event))
  or closed ([`pagehide`](https://developer.mozilla.org/en-US/docs/Web/API/Window/pagehide_event)).
  `pagehide` is used rather than `unload`, which is unreliable, especially on
  mobile. At most a few seconds are lost if the browser quits abruptly.
- **Storage can fail** (private windows, blocked site data), so every access
  is wrapped in `try`/`catch`. If it fails, fading just starts fresh on each
  visit.
- Progress is per browser. Two visitors, or two browsers, each have their own.

#### The progress curve

```js
progress = strength × (1 − e^(−3 × seconds / (hours × 3600)))
```

- An **exponential approach** rather than a straight line. It's fastest at
  first and keeps slowing, so the painting never reaches a final, frozen
  state. That keeps "constantly shifting" true indefinitely, while colors
  never recover.
- The **3** sets the meaning of `hours`: `e^−3 ≈ 0.05`, so after `hours` of
  viewing, fading is 95% of the way to `strength`. Changing `fading.hours` is
  the single control for how long fading takes.
- **`strength`** caps how far it can ever go. The default, 0.12, gives "lighter,
  slightly washed out". At 0.25 the black turned grey-brown and the maroon
  pink, because the pigment-loss maths lifts very dark colors strongly.

#### Where it fades more: exposure and thinness

Fading varies across the canvas, as it would on a real painting:

- **Exposure** (`exposure()` in the shader): around 1, higher on the side the
  light comes from (`fading.light.angle`, `gradient`), plus low-frequency
  noise so it's never perfectly even (`variation`). Static. The `exposure`
  debug view shows it.
- **Thin paint fades sooner**, since it has less pigment to lose. The factor
  is `mix(1, 2 / (1 + thickness), thinPaint)`: 1 at normal thickness, rising
  toward 2 where paint is very thin. This shows most at the ragged borders
  and in thin patches.

Each layer's fade amount is `progress × exposure × thinness`, capped at 0.95.
The `fade` debug view shows it for the selected layer.

#### Two parts to fading

**1. Pigment loss** (per layer, before compositing). Less pigment means less
light absorbed:

```glsl
vec3 body = pow(color, vec3(1.0 - fade));
```

With `absorption = −ln(color)` (as in §7.4), multiplying absorption by
`(1 − fade)` is the same as raising the color to that power. It lightens
each channel in proportion to how strongly it absorbed, which is how a
fading dye behaves. Faded paint also hides a little less
(`hiding × (1 − 0.3 × fade)`), so lower layers show through slightly more
over time. Because this changes the pigment rather than the finished image,
the layered structure stays intact: a faded black glaze over maroon is still
a glaze over maroon.

**2. Washing out** (once, over all layers). Aged paint surfaces scatter light
chalkily. The color is pulled toward its own grey (luminance, using the
[Rec. 709 weights](https://en.wikipedia.org/wiki/Rec._709#Luma_coefficients)
for linear RGB) and gets a faint warm-white veil, both in proportion to
`progress × exposure × washout`. This is a surface effect, so it's applied
after compositing rather than per layer.

**Options considered** for the look of fading: simply blending the final
image toward a lighter color, or the pigment-based model above. Blending the
final image is simpler, but it would fade everything uniformly. It also
couldn't make thin paint fade faster than thick, or let underlayers emerge.

### 7.10 Baking the static fields (performance)

With all four visual phases in place, the painting ran at about **44 fps** on
the development machine. Counting the shader's work per pixel showed that
almost all of it produced the same result every frame:

| Field | Changes over time? | Approx. cost per pixel, before |
| --- | --- | --- |
| Brush strokes (5 layers) | No | ~440 hashes |
| Thickness patches (5 layers) | No | ~200 |
| Warp offsets | No | ~50 |
| Band patchiness, exposure | No | ~35 |
| Breathing (3 shaped layers) | **Yes** | ~120 |

**Options considered:**

1. **Lower the render resolution** (cap the pixel ratio lower, or render to a
   smaller target and upscale). Simple, but blurs everything, including the
   fine canvas grain, to save work that didn't need doing in the first place.
2. **Fewer noise octaves or simpler noise.** Cheaper, but changes the look
   that was tuned in Phases 1–4.
3. **Compute the static fields once into textures**, and look them up each
   frame.

**Chosen: option 3.** It removes about 85% of the per-pixel work without
changing the look. On the development machine the frame rate rose from about
44 fps to **55–60 fps**, effectively the display's refresh limit. A pixel comparison of renders before and after showed a
mean difference of 0.3 on a 0–765 scale, no more than the breathing motion
changes between two frames.

#### How it works

- **Storage:** a three.js
  [`WebGLArrayRenderTarget`](https://threejs.org/docs/pages/WebGLArrayRenderTarget.html):
  one texture with several **slices**, one per layer, plus one for
  exposure. The main shader reads it as a `sampler2DArray`, with the layer
  index as the third texture coordinate.
- **Why an array texture, not separate textures:** GLSL ES 3.00 only allows
  indexing an array of *samplers* with a constant expression, so
  `uFields[i]` inside the layer loop isn't portable. An array texture takes
  the slice as an ordinary coordinate, so `texture(uFields, vec3(vUv, i))`
  works with a loop index.
- **Baking:** [`fields.frag.glsl`](../src/shaders/fields.frag.glsl) draws a
  full-screen quad into each slice in turn. In
  [`renderer.setRenderTarget(target, slice)`](https://threejs.org/docs/pages/WebGLRenderer.html),
  the second argument (named `activeCubeFace`) selects the slice for array
  targets. That behaviour isn't spelled out in the docs; it's in the
  [`WebGLRenderer` source](https://github.com/mrdoob/three.js/blob/dev/src/renderers/WebGLRenderer.js),
  where `activeCubeFace` is used as the layer for 3D and array targets.
- **When:** `sync()` marks the fields stale, and the next `update()` re-bakes
  them before rendering. Dragging a slider in the debug panel therefore costs
  one bake per frame at most, however many values change.
- **Channel layout** (per layer slice; documented at the top of
  `fields.frag.glsl`): R = strokes, G = thickness patches, B/A = warp offset
  (shaped layers) or B = band presence (band layers). The exposure slice holds
  exposure ÷ 2 in R.

#### Decisions

- **8-bit channels**, not floating point. Every stored value is in [0, 1]
  (signed values are stored as raw fBm and decoded with `(x − 0.5) × 2`),
  and they only feed soft transitions. The finest step, 1/255, moves a warped
  border by under 0.0002 of the canvas height. 8-bit also uses half the memory
  of half-float and is supported as a render target everywhere.
- **The warp amount is applied at draw time**, not baked. The texture stores
  the unit offset, and the main shader multiplies by `edge.warp`, so changing
  the warp amount needs no re-bake. (Re-baking happens on every `sync()`
  anyway, but this keeps the baked data independent of that setting.)
- **Resolution tied to the painting, not the screen:** `quality.fieldResolution`
  (1024 texels tall, about 1464 wide). The finest stroke detail is about 190
  cycles per canvas height, so 1024 gives over 5 texels per cycle, enough
  for bilinear filtering to reproduce it. On very large screens the strokes
  are magnified slightly; raise this setting if they ever look soft. Memory:
  7 slices × ~6 MB ≈ 42 MB of graphics memory.
- **Breathing stays live**, since it's the one field that changes over time.
  It's also now skipped for layers with `breath: 0` (the ground), a cheap
  uniform branch that saves one full 5-octave fBm per pixel.
- **Shared noise code:** both shaders need the noise and stroke functions, so
  they live in [`noise.glsl`](../src/shaders/noise.glsl), prepended to each
  (§6.1).

---

## 8. Configuration ([`src/config.js`](../src/config.js))

All tunable values live in one plain JS module, kept separate from rendering
code. Plain JS was chosen over JSON so the file can have comments explaining
each value. The comment block above `layers` explains every per-layer setting.

### Layers, bottom to top

| Layer | Shapes | Notes |
| --- | --- | --- |
| `ground` | One rectangle extending past the canvas on all sides | Extending past the edges means its border is never visible. Its high `hiding` (4.0) makes it almost fully opaque over the bare canvas. |
| `red-outer` | Band along `black`'s border | §7.8. |
| `black` | The large field, 3% from the left/right edges and 4% from top/bottom | |
| `red-windows` | Band along `maroon`'s border | §7.8. |
| `maroon` | The two windows, 0.16 wide with a 0.08 gap between them | Both windows share one set of paint settings. |

Layer names use hyphens rather than spaces so they can go in the debug URL
(`&layer=red-outer`).

**Options considered for how layers own shapes:** one layer per rectangle
(as the first version effectively did), or layers owning lists of shapes.
**Chosen: lists of shapes.** Paint settings belong to the paint, not to each
shape. In the original, both windows were painted with the same paint, so
they should be tuned together. It also matches the planned red border layer,
which will outline several shapes at once.

### The composition is a first pass

The layout is an **approximation from memory** of T01163: a black field over a
maroon ground, opened by two tall maroon "windows". There is no reference
image. Tuning is done from written descriptions, which is why the debug
panel (§9) exists.

### Palette

The maroon and black were chosen to sit close in value, as in the original.
The "window" maroon is slightly lighter than the ground so the two read as
separate layers. The bare canvas is a pale linen color (`#c9b99a`), like
unprimed cotton duck.

The palette is being tuned gradually from feedback, in small steps:

| Layer | Original | Step 1 | Step 2 | Step 3 | Step 4 |
| --- | --- | --- | --- | --- | --- |
| black | `#120a0b` | `#1a181e` | `#1a181e` | `#1a181e` | `#1a181e` |
| ground | `#4a1418` | `#4c1522` | `#795059` | `#795060` | `#79505c` |
| maroon | `#5a1a1f` | `#5d1b2b` | `#865460` | `#865468` | `#865464` |
| red bands | `#8a1f1d` | `#8c2236` | `#a95968` | `#a95975` | `#a9596e` |

- **Step 1:** the black made a little whiter and a little blue (lighter, with
  blue now the strongest channel, so it reads as a cool charcoal rather than a
  warm, reddish near-black). The reds pushed toward purple-pink: hue rotated
  about 10° toward magenta (e.g. maroon 355° → 346°), slightly lighter.
- **Step 2:** the non-black layers washed with white: each mixed 25% of the
  way to white (`c + 0.25 × (255 − c)` per sRGB channel), like adding white
  paint. The maroon windows become a dusty rose-mauve. A side effect: the
  uneven thickness and brushwork inside the windows shows much more against
  the lighter color.
- **Step 3:** the non-black layers pushed a little further toward a
  purple-y red: hue rotated another 10° toward purple (e.g. maroon
  346° → 336°), with lightness and saturation held fixed in
  [HSL](https://en.wikipedia.org/wiki/HSL_and_HSV), so only the hue moves.
  In practice this raises the blue channel slightly while red and green stay
  the same.
- **Step 4:** back a little toward red: hue rotated 5° back (half of step
  3), e.g. maroon 336° → 341°, again with lightness and saturation fixed.
  This sits between steps 2 and 3.

All the reds moved by the same hue angle and the same white mix, so they
stay related to each other. Because the colors are pigment body colors in the glaze model (§7.4),
a shift also changes how thin paint tints the layers beneath it, not just
the flat color.

### Paint values

- `hiding: 2.4` for black and maroon gives about 90% coverage at normal
  thickness. That's close to the 0.9–0.94 opacities of the first version, so
  switching models didn't change the overall look much.
- `variation: 0.35` means thickness varies by ±35% across a layer. This is a
  conservative starting point: the effect is subtle in the final view, and
  clearly visible in the thickness debug view.
- `glaze: 1.0` means thin paint tints with exactly its own color.

### Stroke and edge values

- **Different angles per layer** (ground 20°, black 35°, maroon −25°), so one
  layer's strokes don't line up with another's. Each layer also gets a
  different seed automatically.
- **Patch size** shrinks from ground (0.2) to black (0.16) to maroon (0.12),
  since the windows are smaller areas and would otherwise contain only a few
  patches.
- **Streak width** of 0.014–0.02 of the canvas height, about 4–5 cm on the real
  painting. Narrower values (first tried at 0.008–0.012) made the borders look
  splintered.
- **`breakup: 0.6`** keeps some of the smooth soft edge mixed in. At 1.0 the
  borders are entirely brush-driven and get noticeably harsher.
- **`warp`** of 0.02 (black) and 0.012 (maroon) wobbles the outlines by about
  1–2% of the canvas height, enough to lose the ruled-line look without
  changing the composition. The ground's warp and breakup are 0 because its
  border is off-canvas.

### Red band values

- **Color** (`#a9596e`, see the palette table above): brighter than the
  maroon, so it reads as a distinct red rather than more of the same paint.
- **`hiding`** of 1.4 (outer) and 1.0 (windows) makes the bands
  semi-translucent, so they tint what's beneath rather than covering it. The
  window band is lower because, over the black, it read as a neon outline.
- **`patchiness: 0.85`**: present along roughly half of each border.
- **Band widths** of 0.03 (outer) and 0.02 (windows), matching the scale of
  each border's own edge width.

### Motion values

All motion values were chosen to be just at the edge of noticeable:

- `speed: 0.04` means the shader's internal clock advances 1 unit about every
  25 seconds. Visible change takes tens of seconds.
- `edge.breath: 0.01–0.012` is about half the edge width, so stroke borders
  grow and recede minutely. The ground's breath is 0, since its edge is
  off-canvas.

When tuning, use the debug panel's **preview speed ×** slider to see what the
motion does, rather than editing `speed`.

### Quality

- `quality.fieldResolution: 1024`: the height of the baked-field textures
  (§7.10). It isn't in the debug panel because changing it means recreating
  the texture; edit `config.js` and reload.

### Fading values

- `hours: 4`: 95% faded after four hours of viewing. Change this one number to
  make fading faster or slower.
- `strength: 0.12`: see §7.9 for why it's this low.
- `washout: 0.5` and `thinPaint: 0.6`: moderate, so pigment loss does most of
  the work and thin areas fade visibly but not dramatically sooner.
- `light.angle: 120`: light from the upper left, a common gallery
  arrangement with no particular significance. `gradient: 0.35` makes that
  side fade about 35% faster than average, and `variation: 0.25` keeps it
  uneven.

---

## 9. Debug panel ([`src/debug.js`](../src/debug.js))

With no reference image, tuning happens by describing what looks wrong and
adjusting values. The panel makes that fast and gives things names to refer to.

- **Opening it:** add `?debug` to the URL. Press **H** to hide or show it.
  URL options:
  - `&view=thickness&layer=black`: start on a specific view (`final`,
    `thickness`, `coverage`, `strokes`, `exposure`, `fade`) and layer.
  - `&preview=50`: start with time (motion and fading) running 50× faster.
  - `&fade=4`: jump fading to 4 hours of viewing. This **changes the saved
    progress** in that browser.
- **Built with [lil-gui](https://lil-gui.georgealways.com/)**, the panel
  library used across the three.js examples. It's small, has no
  dependencies, and binds controls directly to properties of plain objects.
  That's why it can edit the config objects in place.
- **Loaded only on request** through a dynamic
  [`import()`](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Operators/import)
  in `main.js`. Vite's production bundler, Rollup, splits dynamically imported
  modules into their own file
  ([Rollup: code splitting](https://rollupjs.org/tutorial/#code-splitting)).
  The build output shows it as a separate `debug-*.js`, so the normal page
  never downloads the panel code.
- **Change handling:** `gui.onChange()` on the root panel fires for every
  control in every folder, and calls `painting.sync()`.

| Control | Purpose |
| --- | --- |
| View → show | `final`, `thickness` (thickness 1 = mid-grey), `coverage` (white = fully hidden beneath), `strokes` (the brush stroke field), `exposure` (exposure 1 = mid-grey), or `fade` (the selected layer's fade amount; 0.5 = white). |
| View → layer | Which layer the debug views show. |
| View → preview speed × | Multiplies the speed of time (up to 200×) without changing the config. |
| View → fps | Frames per second, averaged over half a second. |
| Motion, Surface, Layer folders | Every value in `config.js`, including each shape's coordinates. Band layers show a **Band** folder in place of Edge and Shapes. |
| Fading | The `fading` config values, plus **viewed (hours)** (the saved viewing time; drag to jump), a **progress** readout, and **reset fading**. The last three affect this browser's saved progress, not the config. |
| copy config | Copies the current values as JSON to the clipboard, and logs them to the console as a fallback. Paste back into `config.js` to keep them. |

---

## 10. Page shell ([`index.html`](../index.html), [`src/style.css`](../src/style.css))

- `#app` is `position: fixed; inset: 0`, and the body has `overflow: hidden`,
  so the canvas always fills the viewport exactly with no scrollbars.
- `canvas { display: block }` removes the few pixels of gap that inline
  elements leave below themselves.
- The wall is a dim warm gray (`#121010`), not pure black. Against pure black,
  the painting's near-black field would lose its edge with the wall.

---

## 11. Known limitations and next steps

The roadmap lives in [PLAN.md](PLAN.md). Beyond that:

- **Performance on slower machines:** 55–60 fps on the development machine
  after baking (§7.10). On weaker graphics hardware, the remaining per-frame
  cost is mostly the breathing noise (two shaped layers × 5-octave 3D fBm).
  The next levers would be fewer breathing octaves or a lower pixel-ratio cap
  (§5).
- **Occasional small grid patches** remain where both stroke sets cross at
  similar strength (§7.7).
- **No reduced-motion handling:** honoring
  [`prefers-reduced-motion`](https://developer.mozilla.org/en-US/docs/Web/CSS/@media/prefers-reduced-motion)
  by setting `speed` to 0 or near it would be a small, worthwhile addition.
- **Bundle size:** the build warns that the bundle is over 500 kB (about
  130 kB gzipped). Nearly all of it is three.js's WebGL renderer, which
  tree-shaking can't remove much of because its parts reference each other.
  That's harmless for an art piece. If it ever matters, setting
  `build.chunkSizeWarningLimit` in a `vite.config.js` silences the warning.

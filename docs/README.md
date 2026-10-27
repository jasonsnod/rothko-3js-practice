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
│   ├── config.js                   Layers, paint, motion (tuning lives here)
│   ├── debug.js                    Live tuning panel, loaded only with ?debug
│   ├── style.css                   Fullscreen layout, wall color
│   └── shaders/
│       ├── painting.vert.glsl      Passes UVs through
│       └── painting.frag.glsl      Paints the entire canvas
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
`mesh`, `aspect`, `timeScale`, `sync()`, `setDebugView()`, `update(deltaSeconds)`,
and `dispose()`.

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
No plugin (such as `vite-plugin-glsl`) is needed yet. One would only become
useful if we wanted `#include` between our own GLSL files.

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
| `uLayerShapes[i]` (`vec4`) | first shape index, shape count, seed | Which slice of `uShapes` the layer owns. |
| `uLayerColor[i]` (`vec3`) | linear RGB | `THREE.Color` converts it automatically (§7.6). |
| `uLayerPigment[i]` (`vec4`) | hiding, glaze | Paint properties (§7.4). |
| `uLayerThickness[i]` (`vec4`) | base, variation, scale | How the paint was applied (§7.4). |
| `uLayerEdge[i]` (`vec4`) | width, breath | Border shape and motion (§7.5). |

Grouping scalars into `vec4`s keeps the number of separate uniforms down and
leaves spare slots for later phases. Indices are stored as floats and rounded
back to `int` in the shader. Integer uniform arrays would also work, but
packing them alongside the seed is simpler.

The config is written as edges (`x0, y0, x1, y1`) because that's easiest to
read and adjust. The shader wants center plus half-size. That conversion
happens in JS, so the shader does no extra work per pixel.

The **seed** is just `i + 1`, a distinct number for each layer. It offsets the
noise so layers don't share the same patches or breathe in lockstep. Starting
from 1 is arbitrary.

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

---

## 7. The fragment shader ([`src/shaders/painting.frag.glsl`](../src/shaders/painting.frag.glsl))

The shader runs in this order for every pixel:

1. Start with the color of bare canvas.
2. For each layer, bottom to top (ground, black, maroon):
   1. Measure distance to the layer's shapes, shifted by the breathing noise.
   2. Turn that into a **thickness** of paint at this pixel.
   3. Composite the layer's paint over the color so far using the **glaze
      model**: thin paint tints what's beneath; thick paint hides it.
3. Apply canvas grain.
4. Convert to the output color space.

If a debug view is selected, step 2 also records the chosen layer's thickness
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
that shows faintly as a mitred corner, most visibly in the thickness debug
view. Domain warping (PLAN.md, Phase 2) will break these up.

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
float thickness = base × extent × (1 + variation × patches);
```

- `extent` is the soft shape mask from §7.2: 1 inside, falling to 0 across the
  border.
- `patches` is low-frequency fBm in the range −1 to 1, with a per-layer seed.
  It models paint applied unevenly. It has **no time input**: paint that has
  been laid down doesn't move. `thickness.scale` sets the patch size.

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

| Effect | Implementation | Config key |
| --- | --- | --- |
| **Breathing borders** | fBm sampled at a higher spatial frequency (`p * 6.0`), with time as the third axis, is added to the distance before `smoothstep`. Borders grow and recede minutely around their rest position. This is now the painting's only ongoing motion. | `edge.breath` per layer |
| **Canvas grain** | A fixed per-texel hash (no time input) multiplies the final color. | `surface.grain` |

The first version also slowly moved each rectangle's position and size. That
was removed: the shifting should come from the borders of the paint changing,
not from the shapes travelling. Breathing noise averages to zero, so borders
always return toward where they started.

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
   r152), `new THREE.Color('#4a1418')` converts sRGB hex to linear RGB.
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

---

## 8. Configuration ([`src/config.js`](../src/config.js))

All tunable values live in one plain JS module, kept separate from rendering
code. Plain JS was chosen over JSON so the file can have comments explaining
each value. The comment block above `layers` explains every per-layer setting.

### Layers, bottom to top

| Layer | Shapes | Notes |
| --- | --- | --- |
| `ground` | One rectangle extending past the canvas on all sides | Extending past the edges means its border is never visible. Its high `hiding` (4.0) makes it almost fully opaque over the bare canvas. |
| `black` | The large field, 3% from the left/right edges and 4% from top/bottom | |
| `maroon` | The two windows, 0.16 wide with a 0.08 gap between them | Both windows share one set of paint settings. |

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
Rothko's black is a deep, warm, reddish black rather than neutral `#000`, so
`black` is `#120a0b`. The "window" maroon is slightly lighter than the ground
so the two read as separate layers. The bare canvas is a pale linen color
(`#c9b99a`), like unprimed cotton duck.

### Paint values

- `hiding: 2.4` for black and maroon gives about 90% coverage at normal
  thickness. That's close to the 0.9–0.94 opacities of the first version, so
  switching models didn't change the overall look much.
- `variation: 0.35` means thickness varies by ±35% across a layer. This is a
  conservative starting point: the effect is subtle in the final view, and
  clearly visible in the thickness debug view.
- `glaze: 1.0` means thin paint tints with exactly its own color.

### Motion values

All motion values were chosen to be just at the edge of noticeable:

- `speed: 0.04` means the shader's internal clock advances 1 unit about every
  25 seconds. Visible change takes tens of seconds.
- `edge.breath: 0.012` is about half the edge width, so borders ripple but
  stay soft. The ground's breath is 0, since its edge is off-canvas.

When tuning, use the debug panel's **preview speed ×** slider to see what the
motion does, rather than editing `speed`.

---

## 9. Debug panel ([`src/debug.js`](../src/debug.js))

With no reference image, tuning happens by describing what looks wrong and
adjusting values. The panel makes that fast and gives things names to refer to.

- **Opening it:** add `?debug` to the URL. Press **H** to hide or show it.
  Add `&view=thickness&layer=black` (or `coverage`, or another layer name) to
  start on a specific view.
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
| View → show | `final`, `thickness` (thickness 1 = mid-grey), or `coverage` (white = fully hidden beneath). |
| View → layer | Which layer the debug views show. |
| View → preview speed × | Multiplies the speed of time (up to 200×) without changing the config. |
| Motion, Surface, Layer folders | Every value in `config.js`, including each shape's coordinates. |
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

- **No brush texture yet:** fBm gives cloudy patches but not directional brush
  strokes. That's PLAN.md Phase 2.
- **Mitred corners:** see the note at the end of [§7.2](#72-rectangles-as-signed-distance-fields).
- **No reduced-motion handling:** honoring
  [`prefers-reduced-motion`](https://developer.mozilla.org/en-US/docs/Web/CSS/@media/prefers-reduced-motion)
  by setting `speed` to 0 or near it would be a small, worthwhile addition.
- **Bundle size:** the build warns that the bundle is over 500 kB (about
  130 kB gzipped). Nearly all of it is three.js's WebGL renderer, which
  tree-shaking can't remove much of because its parts reference each other.
  That's harmless for an art piece. If it ever matters, setting
  `build.chunkSizeWarningLimit` in a `vite.config.js` silences the warning.

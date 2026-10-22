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
├── package.json                    three + vite
├── src/
│   ├── main.js                     Renderer, camera, resize, animation loop
│   ├── Painting.js                 Builds the plane + ShaderMaterial from config
│   ├── config.js                   Composition, palette, motion (tuning lives here)
│   ├── style.css                   Fullscreen layout, wall color
│   └── shaders/
│       ├── painting.vert.glsl      Passes UVs through
│       └── painting.frag.glsl      Paints the entire canvas
└── docs/README.md                  This file
```

Data flows in one direction:

```
config.js ──► Painting.js ──(uniforms)──► painting.frag.glsl
                  ▲
main.js ──(elapsed time each frame)──┘
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

This is a single-canvas project with roughly 200 lines of JavaScript. A
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
| Uneven wash density | Fractal noise modulates color inside each field at no extra cost. |
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
  [§7.5](#75-color-management)).

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
`mesh`, `aspect`, `update(seconds)`, and `dispose()`.

### 6.1 GLSL in separate files, imported with `?raw`

**Options considered:** inline template strings in JS, or separate `.glsl` files.

**Chosen: separate files**, loaded with Vite's
[`?raw` suffix](https://vite.dev/guide/assets#importing-asset-as-string), which
imports a file's contents as a string. Separate files get GLSL syntax
highlighting and linting in editors, and they keep JS and GLSL diffs apart.
No plugin (such as `vite-plugin-glsl`) is needed yet. One would only become
useful if we wanted `#include` between our own GLSL files.

### 6.2 Fixed-size uniform arrays with `MAX_RECTS`

GLSL uniform arrays must have a size known at compile time, so the shader
declares `uRects[MAX_RECTS]` and loops like this:

```glsl
for (int i = 0; i < MAX_RECTS; i++) {
  if (i >= uRectCount) break;
  ...
}
```

The loop bound is a **constant** and the real count is checked with `break`.
GLSL ES 1.00 (WebGL 1) requires constant loop bounds
([GLSL ES 1.00 spec, Appendix A](https://registry.khronos.org/OpenGL/specs/es/2.0/GLSL_ES_Specification_1.00.pdf)).
WebGL 2 relaxes this, but the constant-bound pattern works everywhere and lets
drivers unroll the loop.

`MAX_RECTS` is passed in through `ShaderMaterial.defines`, so JS and GLSL share
a single source for the value. Unused slots are padded with zero vectors.
Plain JS arrays of `Vector4` and `Color` can be assigned directly to `vec4[]`
and `vec3[]` uniforms. The [`Uniform`](https://threejs.org/docs/pages/Uniform.html)
docs don't cover arrays. The behavior lives in the renderer's uniform upload
code ([`WebGLUniforms.js`](https://github.com/mrdoob/three.js/blob/dev/src/renderers/webgl/WebGLUniforms.js)),
which flattens such arrays into one typed array before sending them to the GPU.
`8` is a generous ceiling for a Rothko; raising it is a one-line change.

### 6.3 Packing the per-rectangle data

Each rectangle becomes three uniforms:

| Uniform | Contents | Why packed this way |
| --- | --- | --- |
| `uRects[i]` (`vec4`) | center.xy, half-size.xy | This is exactly what the box distance function needs (§7.2). |
| `uRectColors[i]` (`vec3`) | linear RGB | `THREE.Color` converts it automatically (§7.5). |
| `uRectParams[i]` (`vec4`) | softness, opacity, seed, (unused) | Groups the scalars, with room for one more. |

The config is written as edges (`x0, y0, x1, y1`) because that's easiest to
read off a reference image. The shader wants center plus half-size. That
conversion happens once, in JS, so the shader does no extra work per pixel.

The **seed** is just `i + 1`, a distinct number for each rectangle. It offsets
the noise and phase of drift so rectangles don't move in lockstep. Starting
from 1 is arbitrary.

### 6.4 Time scaling in JS

`update()` sets `uTime = elapsedSeconds * motion.speed`. Doing the scaling in
JS keeps a single "speed" knob in the config. All the frequencies in the
shader stay relative to it, so making the painting faster or slower is a
single number that doesn't change the character of the motion.

---

## 7. The fragment shader ([`src/shaders/painting.frag.glsl`](../src/shaders/painting.frag.glsl))

The shader runs in this order for every pixel:

1. Start with the maroon ground, mottled by noise.
2. For each rectangle, in config order, compute a soft mask and blend its
   mottled color on top.
3. Apply canvas grain.
4. Convert to the output color space.

### 7.1 Aspect-corrected coordinates

UVs run from 0 to 1 on both axes, but the canvas is about 1.43 times wider than
it is tall. Without correction, a softness of `0.03` would be wider
horizontally than vertically, and noise blobs would be stretched sideways.
So the shader works in `p = vUv * vec2(uAspect, 1.0)` and scales rectangle
centers and sizes the same way. That keeps every softness, drift, and noise
value isotropic (the same in all directions).

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

- **Soft edges:** `1.0 - smoothstep(-softness, softness, d)` turns distance into
  a mask that fades smoothly across a band `2 × softness` wide, centered on
  the edge. See [`smoothstep`](https://registry.khronos.org/OpenGL-Refpages/gl4/html/smoothstep.xhtml).
- **Irregular edges:** adding noise to `d` before the `smoothstep` pushes the
  edge in and out by a noise-controlled amount (§7.4).

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

### 7.4 The four kinds of variation

All of these are controlled from `motion` in [`config.js`](../src/config.js).
Each is deliberately small.

| Effect | Implementation | Config key |
| --- | --- | --- |
| **Drift** | Each rectangle's center and half-size are offset by `sin`/`cos` of time. Each uses a different, unrelated frequency (0.71, 0.53, 0.37, 0.29) and a per-rect seed phase, so the overall pattern takes a very long time to repeat and rectangles never move in sync. | `drift` |
| **Breathing edges** | fBm sampled at a higher spatial frequency (`p * 6.0`) is added to the distance before `smoothstep`, so the edge locally swells and recedes. | `edgeNoise` |
| **Wash mottling** | fBm at low frequency multiplies each field's color by roughly ±6%, imitating uneven thin glazes. | `washNoise` |
| **Canvas grain** | A fixed per-texel hash (no time input) multiplies the final color. | `grain` |

Design details worth noting:

- **Variations are multiplicative** (`color *= 1.0 + n`), not additive.
  Multiplying keeps the near-black fields near-black and changes tone in
  proportion to brightness. An additive offset would lift the blacks and look
  washed out.
- **Grain is anchored to the painting**, not the screen. It's sampled from
  `floor(vUv * 2048)` rather than `gl_FragCoord`, so it scales with the painting
  like real canvas weave and doesn't shift when the window is resized. It's
  static because canvas texture doesn't move.
- **Layers blend with `mix(color, fill, mask * opacity)`**, in config order.
  Opacity below 1 lets the ground show faintly through, like Rothko's
  translucent layers.

### 7.5 Color management

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

`max(color, 0.0)` before output guards against noise multipliers ever pushing
a channel negative.

---

## 8. Configuration ([`src/config.js`](../src/config.js))

All tunable values live in one plain JS module, kept separate from rendering
code. Plain JS was chosen over JSON so the file can have comments explaining
each value.

### The composition is a first pass

The rectangle layout is an **approximation from memory** of T01163: a black
field over a maroon ground, opened by two tall maroon "windows". It has not
been measured against a reference image. The next step should be to place a
reference beside the render and adjust coordinates in `config.js`.

### Palette

The maroon and black were chosen to sit close in value, as in the original.
Rothko's black is a deep, warm, reddish black rather than neutral `#000`, so
`black` is `#120a0b`. The "window" maroon is slightly lighter than the ground
so the two read as separate layers.

### Motion values

All motion values were chosen to be just at the edge of noticeable:

- `speed: 0.04` means the shader's internal clock advances 1 unit about every
  25 seconds. Visible change takes tens of seconds.
- `drift: 0.006` is less than 1% of the canvas height.
- `edgeNoise: 0.012` is about half the edge softness, so edges ripple but stay
  soft.

When tuning, temporarily raise `speed` to around `0.5` to see what the motion
*does*, then lower it again.

---

## 9. Page shell ([`index.html`](../index.html), [`src/style.css`](../src/style.css))

- `#app` is `position: fixed; inset: 0`, and the body has `overflow: hidden`,
  so the canvas always fills the viewport exactly with no scrollbars.
- `canvas { display: block }` removes the few pixels of gap that inline
  elements leave below themselves.
- The wall is a dim warm gray (`#121010`), not pure black. Against pure black,
  the painting's near-black field would lose its edge with the wall.

---

## 10. Known limitations and likely next steps

- **Composition accuracy:** see [§8](#the-composition-is-a-first-pass).
- **No reduced-motion handling:** honoring
  [`prefers-reduced-motion`](https://developer.mozilla.org/en-US/docs/Web/CSS/@media/prefers-reduced-motion)
  by setting `speed` to 0 or near it would be a small, worthwhile addition.
- **No live tuning UI:** a [lil-gui](https://lil-gui.georgealways.com/) panel
  bound to `config.js` values would make matching the reference much faster.
- **No brush texture:** fBm gives cloudiness but not directional brush
  strokes. Domain warping ([Inigo Quilez: domain warping](https://iquilezles.org/articles/warp/))
  or anisotropic noise would be the next step toward a painted look.
- **Bundle size:** the build warns that the bundle is over 500 kB (about
  130 kB gzipped). Nearly all of it is three.js's WebGL renderer, which
  tree-shaking can't remove much of because its parts reference each other.
  That's harmless for an art piece. If it ever matters, setting
  `build.chunkSizeWarningLimit` in a `vite.config.js` silences the warning.

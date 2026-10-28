# Implementation plan: paint realism

This plan covers the next four qualities to add to the painting:

1. **Ragged edges** between shapes, from loose, chaotic brushwork.
2. **Uneven red coloring along borders**, from an extra red layer.
3. **Uneven tinting inside shapes**, from paint applied at varying thickness.
4. **Gradual fading** toward lighter, slightly washed-out colors, from light
   exposure. This is animated.

Background on the existing architecture is in [docs/README.md](README.md).
Tick items off as they land.

---

## Decisions already made

| Question | Decision |
| --- | --- |
| Fading: a fixed aged look, or animated? | **Animated.** Fading is one of the ways the painting shifts over time. |
| Direction of fading | Colors get **lighter and slightly washed out** (lower saturation, raised values). |
| Brush stroke direction | **Loose crisscrosses**: overlapping strokes in varying directions, with no single dominant axis. |
| Reference image | **None.** Tuning is guided by written feedback, so debug views and named tuning values are essential (see Phase 0). |
| What shifts indefinitely? | **The borders of the strokes.** They constantly grow and recede minutely, always returning toward their original size. Shapes no longer drift as a whole. |
| How does fading run over time? | **One way, continuously**, alongside the breathing borders. Colors never recover. To keep the piece changing indefinitely without ever reaching a final state, fading slows as it goes: `progress(t) = maxFade × (1 − e^(−t/τ))`. |

---

## Core idea: a thickness field per layer

All four qualities come down to *how much paint is at each point*. So each
layer gets a **thickness value at every pixel**, and everything else is
derived from it:

| Quality | How thickness drives it |
| --- | --- |
| Uneven tint | Thick paint hides what is beneath; thin paint lets it through and shifts hue. |
| Ragged edges | A shape ends where its paint thins to zero, and stroke noise decides where that is. |
| Red border unevenness | The red layer's thickness is concentrated in a patchy band around shape borders. |
| Fading | Thin paint has less pigment and fades faster than thick paint. |

Phase 1 put this in place: every layer now computes a thickness per pixel.

---

## Phase 0: Groundwork

### 0.1 Restructure the config into layers

- [x] Replace the flat `rects` list with an ordered list of **layers**, bottom
      to top. Each layer has:
  - `shapes`: one or more rectangles (current `x0/y0/x1/y1` format)
  - `pigment`: color, hiding power, glaze strength (see Phase 1)
  - `thickness`: base amount, variation strength, patch scale
  - `edge`: border width and breath
  - seed: assigned automatically from the layer's position
- [x] Layers in place: **ground**, **black**, **maroon** (two windows).
- [x] **Red underlayers** (the border bands): added in Phase 3 as `red-outer`
      and `red-windows`.
- [x] The shader works out a pixel's thickness for each layer from the
      **union** of that layer's shapes (the nearest shape wins).
- [x] Added a bare **canvas** color beneath all layers, which shows through
      only where paint is thin.

### 0.2 Tuning and debug tools

There's no reference image, and feedback arrives as written descriptions. So
the effects must be easy to isolate and to talk about by name.

- [x] Add a [lil-gui](https://lil-gui.georgealways.com/) panel bound to the
      config values, with folders per layer and per effect. Opens with `?debug`
      in the URL; **H** hides it.
- [x] Add a **debug view** dropdown that renders a single field in grayscale:
      final color, thickness (per layer), coverage (per layer). Can also be set
      from the URL, e.g. `?debug&view=thickness&layer=black`.
- [x] Add a debug view for the stroke field (Phase 2).
- [x] Border band debug view: not needed as a separate view. Band layers are
      ordinary layers, so the existing thickness and coverage views show them
      (`&layer=red-outer`).
- [x] Add debug views for fading: `exposure` and `fade` (Phase 4).
- [x] Add an **fps** readout, and a `&preview=<n>` URL option.
- [x] Add a **"preview speed ×"** override (up to 200×), kept out of the config.
- [x] Add a **"fade progress"** control: added in Phase 4 as `viewed (hours)`.
- [x] Add a **"copy config"** button that copies the current values as JSON, so
      a good state found in the panel can be pasted back into `config.js`.

### 0.3 Leave room for performance work

- [ ] Keep the static fields (the ones that don't change over time) computed in
      separately callable shader functions, so they can move into a pre-computed
      texture later (Phase 5). Done: all static fields now live in the
      baking shader (`fields.frag.glsl`).

---

## Phase 1: Thickness and glaze color model (uneven tinting)

Goal: color varies inside each shape the way real thinly applied paint does.
Patches are deeper or lighter, and thin areas reveal the layers beneath.

### Thickness field

- [x] `thickness(p) = base × shapeFalloff(d) × variation(p)`, where:
  - `d` is the signed distance to the layer's shapes (existing `sdBox`)
  - `shapeFalloff` ramps thickness from 0 at the edge to full inside
  - `variation` combines:
    - [x] **low-frequency fBm**: broad uneven patches
    - [ ] **stroke field** (shared with Phase 2): streaks dragged by the brush
- [x] Thickness texture is **anchored to the canvas** and has no time input.
      Only the borders breathe (and, from Phase 4, the colors fade).

### Pigment model

Replace `mix(color, fill, mask * opacity)` with a two-property glaze model,
based on [Beer–Lambert absorption](https://en.wikipedia.org/wiki/Beer%E2%80%93Lambert_law)
and loosely on [Kubelka–Munk](https://en.wikipedia.org/wiki/Kubelka%E2%80%93Munk_theory):

- [x] **Transmission** (the tint applied to light passing through):
      `T = exp(-absorption × thickness)`, per RGB channel.
- [x] **Hiding** (how opaque the layer is):
      `H = 1 - exp(-hidingPower × thickness)`.
- [x] Composite each layer onto the color below:
      `color = mix(below × T, bodyColor, H)`.
- [x] Keep the config readable with ordinary hex colors. No helper was needed:
      with `absorption = -ln(body)`, the transmission is simply
      `pow(body, glaze × thickness)`, computed directly in the shader.
- [ ] **Tune** `hiding`, `variation` and `scale` from feedback. Current values
      are conservative, so the effect is subtle in the final view.

Expected result: thin black over maroon reads as a deep reddish brown, not
grey, and maroon over black can still cover it where it's thick.

---

## Phase 2: Ragged, brush-stroke edges

Goal: shape boundaries look brushed. They should be uneven at large scale,
streaky and broken at small scale, with crisscrossing strokes.

### Crisscross stroke field

A single direction of streaky noise would read as combed. For loose
crisscrosses:

- [x] **Orientation field**: the stroke direction wanders across the canvas.
      Built as a grid of patches, each with its own angle, blended smoothly
      (a continuously rotating field caused distortion; see docs/README.md §7.7).
- [x] **Two overlapping stroke sets** at about 90° apart, combined with a soft
      max. The crossing set uses lighter pressure so the result doesn't look
      woven.
- [x] Add **per-stroke variation**: each patch has its own pressure and streak
      length.
- [x] Give each layer its own seed and angle, so the black strokes don't line
      up with the maroon strokes.
- [x] Fix "ladder rung" artifacts from the noise lattice (sheared coordinates).
- [x] Strokes also vary thickness **inside** shapes (`strokes.interior`).

### Edge construction

- [x] **Domain warping** for large-scale irregularity: distort `p` with fBm
      before measuring distance to shapes
      ([Inigo Quilez: domain warping](https://iquilezles.org/articles/warp/)).
      This works alongside the `edge.breath` noise, and removed the mitred
      creases at shape corners.
- [x] **Dry-brush breakup**: within the edge band, paint exists only where
      `strokeField > threshold(d)`. The threshold rises toward the edge, so
      edges break into fingers and gaps instead of a smooth fade.
      `edge.breakup` blends between this and the smooth edge.
- [x] **Breathing stroke borders** (the indefinite motion): the breathing noise
      shifts the threshold over time, so individual strokes at the border grow
      and recede minutely around their original size. The stroke texture stays
      anchored to the canvas; only how far each stroke reaches changes.
      Breathing frequency doubled so neighbouring strokes move independently.
- [ ] **Tune** from feedback: spikiness, stroke size, crisscross density.
- [x] **Measure frame rate** on real hardware (debug panel → fps): about 44
      fps, which led to Phase 5.

---

## Phase 3: Red unevenness along borders

Goal: a warmer red shows up unevenly along the borders between shapes, as
though an extra red layer was applied there.

- [x] Red underlayer thickness = **Gaussian band** around the border of the
      layer it outlines, multiplied by **patchiness** noise so it's present in
      some stretches and almost absent in others.
- [x] Settings per band: `outlines`, `width`, `offset` (positive extends
      outside the shape to form a visible halo), `patchiness`, `patchScale`,
      `breakup`. Color comes from the layer's pigment; the seed from its name.
- [x] Bands follow the outlined layer's **actual** border, including its warp
      and breathing, by reusing its border distance (computed in a first pass).
- [x] **Two bands**: `red-outer` below the black (halo, and showing through the
      black's thin edges) and `red-windows` between black and maroon (around
      the windows, and through the maroon's edges). A single band below the
      black couldn't show at the windows, where the black is at full
      thickness.
- [x] The band edges use the same dry-brush breakup as Phase 2, driven by each
      band's own strokes.
- [x] Fixed: the dry-brush cutoff let the strongest strokes leak through far
      from borders (stray flecks). Its range now guarantees zero outside.
- [x] Layer seeds now come from layer **names**, so adding layers doesn't
      change existing layers' strokes.
- [ ] **Tune** from feedback: band strength, width, and how patchy it is.

---

## Phase 4: Animated fading

Goal: over time, colors drift **lighter and slightly washed out**, thin areas
more than thick ones.

### Fading model

- [x] A **fade amount** at each point, per layer:
      `fade = progress(t) × exposure(p) × thinness(thickness)`, where:
  - `exposure(p)`: a gradient from the light's direction plus low-frequency
    noise (light never falls perfectly evenly). Settings in `fading.light`.
  - `thinness`: from layer thickness, so thin paint fades sooner
    (`fading.thinPaint`).
- [x] Apply fading in two parts:
  1. **Pigment loss**: absorption scaled by `(1 − fade)`, i.e. the color raised
     to the power `1 − fade`, which makes colors lighter. Faded paint also
     hides slightly less.
  2. **Washing out**: blend slightly toward a desaturated version plus a faint
     pale veil (chalky surface scattering), weighted by
     `progress × exposure × fading.washout`. Applied once, over all layers.
- [x] Fade **pigments, not the final image**, so faded areas keep their layered
      structure.
- [x] Debug views: `exposure` and `fade` (per layer).

### Animation behavior

Decided: fading runs **one way, continuously**, while the stroke borders
breathe (Phase 2). Colors never recover.

- [x] `progress = strength × (1 − e^(−3t / duration))`. Fastest at first, ever
      slower, never fully stopping.
- [x] Time scale: **`fading.hours = 4`**, the single setting to adjust. The
      factor of 3 makes `hours` mean "95% faded", which is easier to reason
      about than a raw time constant.
- [x] **Resumes exactly between visits**: viewing time is saved in
      `localStorage` (every 5 s, and when the page is hidden or closed).
      It only counts while the page is visible.
- [x] Debug panel: `viewed (hours)` slider, `progress` readout,
      `reset fading`; URL option `&fade=<hours>`.
- [x] `strength` lowered from 0.25 to 0.12: at 0.25 the black turned
      grey-brown by 4 hours, far beyond "slightly washed out".
- [ ] **Tune** from feedback: how washed out at 4 hours, and how uneven.

---

## Phase 5: Performance

These phases add roughly 15–20 fBm evaluations per pixel per layer. Most of
the fields never change over time: the stroke field, the orientation field,
low-frequency thickness variation, and exposure.

- [x] Measure first: about **44 fps** on the development machine with all four
      phases in place. Worth doing.
- [x] Pre-compute the static fields (strokes, patches, warp, band presence,
      exposure) into a
      [`WebGLArrayRenderTarget`](https://threejs.org/docs/pages/WebGLArrayRenderTarget.html):
      one slice per layer plus one for exposure, 8-bit RGBA. An array texture
      rather than separate textures, because sampler arrays can't be indexed
      by a loop variable in GLSL ES 3.00.
- [x] Re-bake whenever settings change (`sync()` marks the fields stale; the
      next frame re-bakes once).
- [x] Fixed resolution tied to the painting: `quality.fieldResolution` = 1024
      texels tall (≈ 42 MB total). Lower than the 2048 first planned: 1024
      already gives 5+ texels per cycle of the finest stroke detail.
- [x] Skip the breathing noise for layers that don't breathe (the ground).
- [x] Verified: pixel comparison before/after shows no visible change (mean
      difference 0.3 / 765).
- [ ] **Re-measure fps** on the development machine. If still under 60, next
      levers: fewer breathing octaves, or a lower pixel-ratio cap.

---

## Order of work

1. ~~Phase 0: layered config, debug panel, debug views~~ (done)
2. ~~Phase 1: thickness + glaze model~~ (done; tuning ongoing)
3. ~~Phase 2: brush-stroke edges, including breathing stroke borders~~ (done; tuning ongoing)
4. ~~Phase 3: red border layer~~ (done; tuning ongoing)
5. ~~Phase 4: animated fading~~ (done; tuning ongoing)
6. ~~Phase 5: pre-computed static fields~~ (done; re-measure fps)

Edges and the border band are both built from the thickness field, and fading
works on the pigment model. That's why Phase 1 comes before them, even though
it isn't the first item in the list of goals.

---

## Giving feedback without a reference image

Feedback can name these things directly:

- **Debug view names** (e.g. "in the *stroke field* view, strokes are too
  regular").
- **Panel values** (e.g. "black `thickness.variation` at 0.4 looks right").
- **Where on the canvas** (e.g. "the right window's left edge", "the top band").
- **Scale**: broad patches, individual strokes, or fine texture.

After each change, a headless screenshot can be taken and compared before
reporting back, as was done when the project was first set up.

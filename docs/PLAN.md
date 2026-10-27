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
- [ ] **Red underlayer** (the border band): added in Phase 3.
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
- [ ] Add debug views for the border band (Phase 3) and fading exposure
      (Phase 4), as each of those exists.
- [x] Add an **fps** readout, and a `&preview=<n>` URL option.
- [x] Add a **"preview speed ×"** override (up to 200×), kept out of the config.
- [ ] Add a **"fade progress"** slider: added in Phase 4.
- [x] Add a **"copy config"** button that copies the current values as JSON, so
      a good state found in the panel can be pasted back into `config.js`.

### 0.3 Leave room for performance work

- [ ] Keep the static fields (the ones that don't change over time) computed in
      separately callable shader functions, so they can move into a pre-computed
      texture later (Phase 5). The stroke field is its own function
      (`strokeField`); the warp offset and thickness patches are still inline
      in `main()` and need splitting out when Phase 5 starts.

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
- [ ] **Measure frame rate** on real hardware (debug panel → fps). If low,
      bring Phase 5 forward.

---

## Phase 3: Red unevenness along borders

Goal: a warmer red shows up unevenly along the borders between shapes, as
though an extra red layer was applied there.

- [ ] Red underlayer thickness = **band function** of distance to the shapes it
      outlines (Gaussian or smoothstep band), multiplied by **patchiness** noise
      so it's present in some stretches and almost absent in others.
- [ ] Settings per band: `width`, `offset` (positive extends outside the shape
      to form a visible halo), `color`, `patchiness`, `seed`.
- [ ] The band sits **below the black layer**. It shows as a halo where it
      extends past the black, and shows through where the black is thin
      (from Phase 1).
- [ ] The band edges use the same stroke field as Phase 2, so the red follows
      the brushwork.

---

## Phase 4: Animated fading

Goal: over time, colors drift **lighter and slightly washed out**, thin areas
more than thick ones.

### Fading model

- [ ] A **fade amount** at each point:
      `fade(p, t) = progress(t) × exposure(p) × thinness(p)`, where:
  - `exposure(p)`: a gentle gradient across the canvas plus low-frequency noise
    (light never falls perfectly evenly)
  - `thinness(p)`: derived from layer thickness, so thin paint fades sooner
- [ ] Apply fading in two parts:
  1. **Pigment loss**: scale absorption down by `(1 - fade × k)`, which makes
     colors lighter.
  2. **Washing out**: blend slightly toward a pale, desaturated version
     (simulating chalky surface scattering), weighted by `fade`.
- [ ] Fade **pigments, not the final image**, so faded areas keep their layered
      structure.

### Animation behavior

Decided: fading runs **one way, continuously**, while the stroke borders
breathe (Phase 2). Colors never recover.

- [ ] `progress(t) = maxFade × (1 − e^(−t/τ))`. Fading is fastest at first and
      keeps slowing, so it never fully stops and never reaches a hard end
      state.
- [ ] Settings: `maxFade` (how washed out it can ever get) and `τ` (the time
      constant: by `t = τ`, about 63% of the maximum fade has happened).
- [ ] Decide the time scale `τ`: minutes, hours, or longer?
- [ ] Decide whether fading starts fresh on each page load, or persists
      between visits (stored in the browser).

---

## Phase 5: Performance

These phases add roughly 15–20 fBm evaluations per pixel per layer. Most of
the fields never change over time: the stroke field, the orientation field,
low-frequency thickness variation, and exposure.

- [ ] Pre-compute the static fields **once** into a texture using a
      [`WebGLRenderTarget`](https://threejs.org/docs/pages/WebGLRenderTarget.html)
      at startup, with one channel per field. The animated shader samples it.
- [ ] Use a fixed texture resolution (e.g. 2048 × 1434) tied to the painting,
      not the screen, so detail stays consistent across window sizes.
- [ ] Only do this when performance requires it. Measure first.

---

## Order of work

1. ~~Phase 0: layered config, debug panel, debug views~~ (done)
2. ~~Phase 1: thickness + glaze model~~ (done; tuning ongoing)
3. ~~Phase 2: brush-stroke edges, including breathing stroke borders~~ (done; tuning ongoing)
4. Phase 3: red border layer
5. Phase 4: animated fading (decide `τ` and persistence first)
6. Phase 5: pre-computed static fields, when needed

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

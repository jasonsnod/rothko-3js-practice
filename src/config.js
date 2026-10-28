// Composition, paint and motion settings for the painting.
//
// Coordinates are normalized to the canvas: (0, 0) is bottom-left, (1, 1) is
// top-right. Layers are painted bottom to top, so later entries sit on top.
//
// The layout is a first-pass approximation of Black on Maroon (1958, Tate
// T01163): a black field over a maroon ground, opened by two tall maroon
// "windows".
//
// Every value here can be tuned live in the debug panel (open the page with
// ?debug in the URL), then copied back with the panel's "copy config" button.

export const painting = {
  // Physical size in cm (height x width) -- only the aspect ratio matters.
  widthCm: 381.2,
  heightCm: 266.7,

  // Fraction of the viewport the painting may occupy (leaves a wall margin).
  viewportFill: 0.86,
};

export const quality = {
  // Height, in texels, of the textures the static patterns (brush strokes,
  // thickness patches, warp, light) are computed into once, rather than
  // every frame. Higher = finer stroke detail on very large screens, at the
  // cost of graphics memory and a slower re-bake when settings change. At
  // 1024 that's 7 slices of about 6 MB each (≈ 42 MB); memory grows with the
  // square of this value.
  fieldResolution: 1024,
};

export const surface = {
  // Bare canvas beneath all paint. Shows only where paint is very thin.
  canvas: '#c9b99a',
  // Fine static canvas grain.
  grain: 0.025,
};

// Each layer's paint is described by:
//
//   pigment.color   Color of the paint where it is thick enough to hide
//                   everything beneath it.
//   pigment.hiding  How quickly paint becomes opaque as it thickens.
//                   Higher = covers more at the same thickness.
//   pigment.glaze   How strongly thin paint tints the layers beneath it.
//                   0 = no tint, 1 = full tint of its own color.
//
//   thickness.base       Paint thickness inside the shape (1 = normal).
//   thickness.variation  How unevenly the paint was applied (0 = perfectly
//                        even, 0.5 = thickness varies by +/-50%).
//   thickness.scale      Size of the uneven patches. Higher = smaller patches.
//
//   strokes.size      Size of each patch of same-direction strokes.
//   strokes.angle     Main stroke direction in degrees (0 = horizontal). A
//                     second set of strokes crosses it at about 90 degrees.
//   strokes.spread    How far each patch's direction varies, in degrees.
//   strokes.length    Typical length of a bristle streak.
//   strokes.width     Typical width of a bristle streak.
//   strokes.interior  How much the strokes vary paint thickness inside the
//                     shape (0 = not at all).
//
//   edge.width    How far the paint thins out across a shape's border.
//   edge.breath   How far stroke borders grow and recede over time.
//   edge.warp     Large-scale irregularity of the outline.
//   edge.breakup  0 = smooth soft border, 1 = border fully broken up by
//                 brush strokes (dry-brush fingers and gaps).
//
//   shapes  One or more rectangles the layer's paint covers.
//
// A band layer has `band` instead of `shapes` and `edge`. Its paint runs along
// another layer's border (following that border's warping and breathing):
//
//   band.outlines    Name of the layer whose border this band follows.
//   band.width       How far the band spreads either side of its center line.
//   band.offset      Shifts the band outward (+) or inward (-) from the border.
//   band.patchiness  0 = present all along the border, 1 = only in patches.
//   band.patchScale  Size of those patches. Higher = smaller patches.
//   band.breakup     How much the band's edges are broken up by its strokes.
//
// Sizes and widths are fractions of the canvas height. Each layer's random
// pattern comes from its name, so renaming a layer changes its strokes.
export const layers = [
  {
    name: 'ground',
    pigment: { color: '#4a1418', hiding: 4.0, glaze: 1.0 },
    thickness: { base: 1.0, variation: 0.25, scale: 2.0 },
    strokes: { size: 0.2, angle: 20, spread: 40, length: 0.35, width: 0.02, interior: 0.15 },
    edge: { width: 0.02, breath: 0.0, warp: 0.0, breakup: 0.0 },
    // Extends past the canvas so the ground has no visible border.
    shapes: [{ x0: -0.1, y0: -0.1, x1: 1.1, y1: 1.1 }],
  },
  {
    // Warm red beneath the black field's border. Shows as a halo where it
    // extends past the black, and through the black's thin, broken edge.
    name: 'red-outer',
    pigment: { color: '#8a1f1d', hiding: 1.4, glaze: 1.0 },
    thickness: { base: 1.0, variation: 0.4, scale: 3.0 },
    strokes: { size: 0.14, angle: -10, spread: 40, length: 0.25, width: 0.016, interior: 0.3 },
    band: { outlines: 'black', width: 0.03, offset: 0.0, patchiness: 0.85, patchScale: 4.0, breakup: 0.5 },
  },
  {
    name: 'black',
    pigment: { color: '#120a0b', hiding: 2.4, glaze: 1.0 },
    thickness: { base: 1.0, variation: 0.35, scale: 2.5 },
    strokes: { size: 0.16, angle: 35, spread: 35, length: 0.3, width: 0.018, interior: 0.25 },
    edge: { width: 0.035, breath: 0.012, warp: 0.02, breakup: 0.6 },
    shapes: [{ x0: 0.03, y0: 0.04, x1: 0.97, y1: 0.96 }],
  },
  {
    // Warm red over the black, around the windows' borders and beneath the
    // maroon. Shows around the windows and through the maroon's ragged edges.
    name: 'red-windows',
    pigment: { color: '#8a1f1d', hiding: 1.0, glaze: 1.0 },
    thickness: { base: 1.0, variation: 0.4, scale: 3.5 },
    strokes: { size: 0.1, angle: 60, spread: 40, length: 0.2, width: 0.012, interior: 0.3 },
    band: { outlines: 'maroon', width: 0.02, offset: 0.005, patchiness: 0.85, patchScale: 5.0, breakup: 0.5 },
  },
  {
    name: 'maroon',
    pigment: { color: '#5a1a1f', hiding: 2.4, glaze: 1.0 },
    thickness: { base: 1.0, variation: 0.35, scale: 3.0 },
    strokes: { size: 0.12, angle: -25, spread: 35, length: 0.25, width: 0.014, interior: 0.25 },
    edge: { width: 0.025, breath: 0.01, warp: 0.012, breakup: 0.6 },
    shapes: [
      { x0: 0.30, y0: 0.2, x1: 0.46, y1: 0.8 }, // left window
      { x0: 0.54, y0: 0.2, x1: 0.70, y1: 0.8 }, // right window
    ],
  },
];

export const motion = {
  // Global time scale. Keep this small: the shifting should be felt, not seen.
  speed: 0.04,
};

// Colors slowly fade lighter and slightly washed out, as if from years of
// light exposure. Fading counts viewing time, is saved in the browser, and
// resumes exactly where it left off on the next visit.
export const fading = {
  // Hours of viewing for colors to (almost) fully fade: 95% of the way there.
  // After that they keep fading, ever more slowly, without quite stopping.
  hours: 4,
  // How far colors can ever fade. 0 = not at all, 1 = pigment almost gone.
  strength: 0.12,
  // How much fading also turns the surface chalky and desaturated, on top of
  // the colors simply getting lighter.
  washout: 0.5,
  // How much faster thin paint fades than thick paint (0 = no difference).
  thinPaint: 0.6,
  // The light that caused the fading: where it comes from (degrees, 0 = from
  // the right, 90 = from above), how much stronger it is on that side, and
  // how unevenly it falls.
  light: { angle: 120, gradient: 0.35, variation: 0.25 },
};

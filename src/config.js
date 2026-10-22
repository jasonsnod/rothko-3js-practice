// Composition and motion settings for the painting.
//
// Coordinates are normalized to the canvas: (0, 0) is bottom-left, (1, 1) is
// top-right. Rectangles are painted in order, so later entries sit on top.
//
// The layout is a first-pass approximation of Black on Maroon (1958, Tate
// T01163): a black field over a maroon ground, opened by two tall maroon
// "windows". Tune these against a reference image.

export const painting = {
  // Physical size in cm (height x width) -- only the aspect ratio matters.
  widthCm: 381.2,
  heightCm: 266.7,

  // Fraction of the viewport the painting may occupy (leaves a wall margin).
  viewportFill: 0.86,
};

export const palette = {
  ground: '#4a1418',
  black: '#120a0b',
  maroon: '#5a1a1f',
};

export const rects = [
  // Black field covering most of the canvas.
  {
    color: palette.black,
    x0: 0.06, y0: 0.08, x1: 0.94, y1: 0.92,
    softness: 0.035, // edge feather width
    opacity: 0.94,
  },
  // Left maroon window.
  {
    color: palette.maroon,
    x0: 0.17, y0: 0.2, x1: 0.33, y1: 0.8,
    softness: 0.025,
    opacity: 0.9,
  },
  // Right maroon window.
  {
    color: palette.maroon,
    x0: 0.67, y0: 0.2, x1: 0.83, y1: 0.8,
    softness: 0.025,
    opacity: 0.9,
  },
];

export const motion = {
  // Global time scale. Keep this small: the shifting should be felt, not seen.
  speed: 0.04,
  // How far (in canvas units) rectangle edges wander.
  drift: 0.006,
  // Strength of the noise that roughens and breathes along edges.
  edgeNoise: 0.012,
  // Mottling of color within each field (layered-wash look).
  washNoise: 0.06,
  // Fine static canvas grain.
  grain: 0.025,
};

import GUI from 'lil-gui';
import { DEBUG_VIEWS } from './Painting.js';

// Live tuning panel. Loaded only when the page URL contains ?debug.
// Press H to hide or show it. URL options:
//   &view=<final|thickness|coverage|strokes|exposure|fade>  starting view
//   &layer=<layer name>  layer for the per-layer views
//   &preview=<n>         time (motion and fading) runs n times faster
//   &fade=<hours>        jump fading to this much viewing time (this changes
//                        the saved fading progress for this browser)
//
// Controls edit the config objects directly, then the painting re-syncs its
// uniforms. "copy config" puts the current values on the clipboard as JSON so
// they can be pasted back into config.js.
export function createDebugPanel(painting, { surface, layers, motion, fading }) {
  const gui = new GUI({ title: 'Black on Maroon' });
  gui.onChange(() => painting.sync());

  // --- View ---------------------------------------------------------------
  // The starting view can be set from the URL, e.g. ?debug&view=thickness&layer=black
  const params = new URLSearchParams(window.location.search);
  const layerOptions = Object.fromEntries(layers.map((layer, i) => [layer.name, i]));
  const view = {
    show: DEBUG_VIEWS[params.get('view')] ?? DEBUG_VIEWS.final,
    layer: layerOptions[params.get('layer')] ?? layers.length - 1,
  };
  const applyView = () => painting.setDebugView(view.show, view.layer);
  applyView();
  painting.timeScale = Number(params.get('preview')) || 1;
  if (params.has('fade')) painting.fadeClock.set(Number(params.get('fade')) * 3600 || 0);

  const viewFolder = gui.addFolder('View');
  viewFolder.add(view, 'show', DEBUG_VIEWS).onChange(applyView);
  viewFolder.add(view, 'layer', layerOptions).onChange(applyView);
  viewFolder.add(painting, 'timeScale', 0, 200, 1).name('preview speed ×');

  // Frames per second, averaged over half a second. Useful because the
  // stroke fields are expensive; see PLAN.md, Phase 5.
  const stats = { fps: 0 };
  viewFolder.add(stats, 'fps').disable().listen();
  let frames = 0;
  let last = performance.now();
  (function count(now) {
    frames++;
    if (now - last >= 500) {
      stats.fps = Math.round((frames * 1000) / (now - last));
      frames = 0;
      last = now;
    }
    requestAnimationFrame(count);
  })(last);

  // --- Motion and surface -------------------------------------------------
  const motionFolder = gui.addFolder('Motion');
  motionFolder.add(motion, 'speed', 0, 1, 0.005);

  const surfaceFolder = gui.addFolder('Surface');
  surfaceFolder.addColor(surface, 'canvas');
  surfaceFolder.add(surface, 'grain', 0, 0.2, 0.005);

  // --- Fading -------------------------------------------------------------
  const fadeFolder = gui.addFolder('Fading');
  fadeFolder.add(fading, 'hours', 0.05, 24, 0.05);
  fadeFolder.add(fading, 'strength', 0, 1, 0.01);
  fadeFolder.add(fading, 'washout', 0, 1, 0.01);
  fadeFolder.add(fading, 'thinPaint', 0, 1, 0.01).name('thin paint');
  const lightFolder = fadeFolder.addFolder('Light').close();
  lightFolder.add(fading.light, 'angle', -180, 180, 1);
  lightFolder.add(fading.light, 'gradient', 0, 1, 0.01);
  lightFolder.add(fading.light, 'variation', 0, 1, 0.01);

  // Viewing time so far, saved in this browser. Not part of the config.
  const clock = {
    get elapsedHours() { return painting.fadeClock.seconds / 3600; },
    set elapsedHours(hours) { painting.fadeClock.set(hours * 3600); },
    get progress() { return Number(painting.fadeProgress().toFixed(3)); },
    reset() { painting.fadeClock.set(0); },
  };
  fadeFolder.add(clock, 'elapsedHours', 0, 12, 0.01).name('viewed (hours)').listen();
  fadeFolder.add(clock, 'progress').disable().listen();
  fadeFolder.add(clock, 'reset').name('reset fading');

  // --- Layers -------------------------------------------------------------
  for (const layer of layers) {
    const folder = gui.addFolder(`Layer: ${layer.name}`).close();

    const pigment = folder.addFolder('Pigment');
    pigment.addColor(layer.pigment, 'color');
    pigment.add(layer.pigment, 'hiding', 0, 8, 0.05);
    pigment.add(layer.pigment, 'glaze', 0, 2, 0.05);

    const thickness = folder.addFolder('Thickness');
    thickness.add(layer.thickness, 'base', 0, 2, 0.01);
    thickness.add(layer.thickness, 'variation', 0, 1, 0.01);
    thickness.add(layer.thickness, 'scale', 0.5, 12, 0.1);

    const strokes = folder.addFolder('Strokes');
    strokes.add(layer.strokes, 'size', 0.02, 0.5, 0.005);
    strokes.add(layer.strokes, 'angle', -90, 90, 1);
    strokes.add(layer.strokes, 'spread', 0, 90, 1);
    strokes.add(layer.strokes, 'length', 0.02, 1, 0.01);
    strokes.add(layer.strokes, 'width', 0.001, 0.05, 0.001);
    strokes.add(layer.strokes, 'interior', 0, 1, 0.01);

    if (layer.band) {
      const band = folder.addFolder(`Band (outlines ${layer.band.outlines})`);
      band.add(layer.band, 'width', 0.002, 0.1, 0.001);
      band.add(layer.band, 'offset', -0.05, 0.05, 0.001);
      band.add(layer.band, 'patchiness', 0, 1, 0.01);
      band.add(layer.band, 'patchScale', 0.5, 12, 0.1);
      band.add(layer.band, 'breakup', 0, 1, 0.01);
      continue;
    }

    const edge = folder.addFolder('Edge');
    edge.add(layer.edge, 'width', 0, 0.1, 0.001);
    edge.add(layer.edge, 'breath', 0, 0.05, 0.001);
    edge.add(layer.edge, 'warp', 0, 0.08, 0.001);
    edge.add(layer.edge, 'breakup', 0, 1, 0.01);

    layer.shapes.forEach((shape, i) => {
      const s = folder.addFolder(`Shape ${i + 1}`).close();
      for (const key of ['x0', 'y0', 'x1', 'y1']) {
        s.add(shape, key, -0.1, 1.1, 0.005);
      }
    });
  }

  // --- Export -------------------------------------------------------------
  gui.add({
    copyConfig() {
      const json = JSON.stringify({ surface, layers, motion, fading }, null, 2);
      console.log(json);
      navigator.clipboard?.writeText(json).catch(() => {
        console.warn('Clipboard unavailable; config was logged above instead.');
      });
    },
  }, 'copyConfig').name('copy config');

  let visible = true;
  window.addEventListener('keydown', (event) => {
    if (event.key === 'h' || event.key === 'H') gui.show((visible = !visible));
  });

  return gui;
}

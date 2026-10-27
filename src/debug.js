import GUI from 'lil-gui';
import { DEBUG_VIEWS } from './Painting.js';

// Live tuning panel. Loaded only when the page URL contains ?debug.
// Press H to hide or show it. Add &view=<final|thickness|coverage|strokes> and
// &layer=<layer name> to start on a specific debug view, and &preview=<n> to
// start with time running n times faster.
//
// Controls edit the config objects directly, then the painting re-syncs its
// uniforms. "copy config" puts the current values on the clipboard as JSON so
// they can be pasted back into config.js.
export function createDebugPanel(painting, { surface, layers, motion }) {
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
      const json = JSON.stringify({ surface, layers, motion }, null, 2);
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

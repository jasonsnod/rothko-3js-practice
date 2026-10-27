import GUI from 'lil-gui';
import { DEBUG_VIEWS } from './Painting.js';

// Live tuning panel. Loaded only when the page URL contains ?debug.
// Press H to hide or show it. Add &view=<final|thickness|coverage> and
// &layer=<layer name> to start on a specific debug view.
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

  const viewFolder = gui.addFolder('View');
  viewFolder.add(view, 'show', DEBUG_VIEWS).onChange(applyView);
  viewFolder.add(view, 'layer', layerOptions).onChange(applyView);
  viewFolder.add(painting, 'timeScale', 0, 200, 1).name('preview speed ×');

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

    const edge = folder.addFolder('Edge');
    edge.add(layer.edge, 'width', 0, 0.1, 0.001);
    edge.add(layer.edge, 'breath', 0, 0.05, 0.001);

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

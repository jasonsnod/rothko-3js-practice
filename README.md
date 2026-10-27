# rothko-practice

A constantly, slightly shifting three.js re-make of Mark Rothko's *Black on Maroon* (1958).

## Running

```sh
npm install
npm run dev      # dev server with hot reload
npm run build    # production build to dist/
npm run preview  # serve the production build
```

Add `?debug` to the URL (e.g. `http://localhost:5173/?debug`) to open the live
tuning panel. Press **H** to hide it.

Requires Node 18, 20 or 22+. (Vite is pinned to v6 because Vite 7+ needs Node 20.19+/22.12+.)

## How it works

For the full reasoning behind each design decision, with links to the
three.js docs, see [docs/README.md](docs/README.md).

The painting is a single plane viewed by an orthographic camera. Everything
visible is drawn in a fragment shader:

- **Rectangles** are signed-distance boxes with smoothstepped, feathered edges.
- **Edge noise** (evolving fractal noise) roughens the edges so they breathe
  rather than slide.
- **Drift** moves each rectangle's position and size slowly and independently.
- **Wash noise** mottles the color inside each field, like layered thin glazes.
- **Grain** adds a fixed canvas texture.

## Layout

| File | Purpose |
| --- | --- |
| `src/config.js` | Composition, palette and motion. Most tuning happens here. |
| `src/Painting.js` | Builds the plane and shader material from the config. |
| `src/shaders/painting.frag.glsl` | Paints the canvas. |
| `src/main.js` | Renderer, camera, letterbox resize, animation loop. |

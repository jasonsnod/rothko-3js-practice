import * as THREE from 'three';
import vertexShader from './shaders/painting.vert.glsl?raw';
import fragmentShader from './shaders/painting.frag.glsl?raw';

const MAX_LAYERS = 6;
const MAX_SHAPES = 12;

export const DEBUG_VIEWS = { final: 0, thickness: 1, coverage: 2 };

// A flat canvas whose surface is painted entirely in a fragment shader.
// Its local size is aspect x 1, so the camera can fit it by height.
//
// The config objects are kept by reference: after changing any of them (as
// the debug panel does), call sync() to push the new values to the shader.
export class Painting {
  constructor({ painting, surface, layers, motion }) {
    this.aspect = painting.widthCm / painting.heightCm;
    this.surface = surface;
    this.layers = layers;
    this.motion = motion;

    // Preview multiplier for watching slow motion quickly. Not part of the
    // config, so it can't be copied into it by accident.
    this.timeScale = 1;

    // Fixed-size arrays, padded; the shader stops at uLayerCount and each
    // layer's shape range.
    const vec4s = (n) => Array.from({ length: n }, () => new THREE.Vector4());
    const colors = (n) => Array.from({ length: n }, () => new THREE.Color());

    this.material = new THREE.ShaderMaterial({
      vertexShader,
      fragmentShader,
      defines: { MAX_LAYERS, MAX_SHAPES },
      uniforms: {
        uTime: { value: 0 },
        uAspect: { value: this.aspect },
        uCanvas: { value: new THREE.Color() },
        uGrain: { value: 0 },
        uLayerCount: { value: 0 },
        uLayerColor: { value: colors(MAX_LAYERS) },
        uLayerPigment: { value: vec4s(MAX_LAYERS) },
        uLayerThickness: { value: vec4s(MAX_LAYERS) },
        uLayerEdge: { value: vec4s(MAX_LAYERS) },
        uLayerShapes: { value: vec4s(MAX_LAYERS) },
        uShapes: { value: vec4s(MAX_SHAPES) },
        uDebugView: { value: DEBUG_VIEWS.final },
        uDebugLayer: { value: 0 },
      },
    });
    this.sync();

    const geometry = new THREE.PlaneGeometry(this.aspect, 1);
    this.mesh = new THREE.Mesh(geometry, this.material);
  }

  sync() {
    const { layers, surface } = this;
    const u = this.material.uniforms;

    const shapeTotal = layers.reduce((n, layer) => n + layer.shapes.length, 0);
    if (layers.length > MAX_LAYERS) {
      throw new Error(`At most ${MAX_LAYERS} layers are supported (got ${layers.length}).`);
    }
    if (shapeTotal > MAX_SHAPES) {
      throw new Error(`At most ${MAX_SHAPES} shapes are supported (got ${shapeTotal}).`);
    }

    u.uCanvas.value.set(surface.canvas);
    u.uGrain.value = surface.grain;
    u.uLayerCount.value = layers.length;

    // Shapes from all layers go into one flat array; each layer records the
    // range it owns.
    let shapeIndex = 0;
    layers.forEach((layer, i) => {
      const { pigment, thickness, edge } = layer;
      u.uLayerColor.value[i].set(pigment.color);
      u.uLayerPigment.value[i].set(pigment.hiding, pigment.glaze, 0, 0);
      u.uLayerThickness.value[i].set(thickness.base, thickness.variation, thickness.scale, 0);
      u.uLayerEdge.value[i].set(edge.width, edge.breath, 0, 0);
      u.uLayerShapes.value[i].set(shapeIndex, layer.shapes.length, i + 1, 0);

      for (const s of layer.shapes) {
        u.uShapes.value[shapeIndex++].set(
          (s.x0 + s.x1) / 2, (s.y0 + s.y1) / 2,
          (s.x1 - s.x0) / 2, (s.y1 - s.y0) / 2,
        );
      }
    });
  }

  setDebugView(view, layerIndex) {
    this.material.uniforms.uDebugView.value = view;
    this.material.uniforms.uDebugLayer.value = layerIndex;
  }

  // Time accumulates per frame (rather than elapsed x speed) so that changing
  // the speed live doesn't make the painting jump.
  update(deltaSeconds) {
    this.material.uniforms.uTime.value += deltaSeconds * this.motion.speed * this.timeScale;
  }

  dispose() {
    this.mesh.geometry.dispose();
    this.material.dispose();
  }
}

import * as THREE from 'three';
import vertexShader from './shaders/painting.vert.glsl?raw';
import fragmentShader from './shaders/painting.frag.glsl?raw';

const MAX_RECTS = 8;

// A flat canvas whose surface is painted entirely in a fragment shader.
// Its local size is aspect x 1, so the camera can fit it by height.
export class Painting {
  constructor({ painting, palette, rects, motion }) {
    if (rects.length > MAX_RECTS) {
      throw new Error(`At most ${MAX_RECTS} rectangles are supported (got ${rects.length}).`);
    }

    this.aspect = painting.widthCm / painting.heightCm;
    this.motion = motion;

    // Pad uniform arrays to MAX_RECTS; the shader stops at uRectCount.
    const rectUniforms = [];
    const colorUniforms = [];
    const paramUniforms = [];
    for (let i = 0; i < MAX_RECTS; i++) {
      const r = rects[i];
      if (r) {
        rectUniforms.push(new THREE.Vector4(
          (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2,
          (r.x1 - r.x0) / 2, (r.y1 - r.y0) / 2,
        ));
        colorUniforms.push(new THREE.Color(r.color));
        paramUniforms.push(new THREE.Vector4(r.softness, r.opacity, i + 1, 0));
      } else {
        rectUniforms.push(new THREE.Vector4());
        colorUniforms.push(new THREE.Color());
        paramUniforms.push(new THREE.Vector4());
      }
    }

    this.material = new THREE.ShaderMaterial({
      vertexShader,
      fragmentShader,
      defines: { MAX_RECTS },
      uniforms: {
        uTime: { value: 0 },
        uAspect: { value: this.aspect },
        uGround: { value: new THREE.Color(palette.ground) },
        uRectCount: { value: rects.length },
        uRects: { value: rectUniforms },
        uRectColors: { value: colorUniforms },
        uRectParams: { value: paramUniforms },
        uDrift: { value: motion.drift },
        uEdgeNoise: { value: motion.edgeNoise },
        uWashNoise: { value: motion.washNoise },
        uGrain: { value: motion.grain },
      },
    });

    const geometry = new THREE.PlaneGeometry(this.aspect, 1);
    this.mesh = new THREE.Mesh(geometry, this.material);
  }

  update(elapsedSeconds) {
    this.material.uniforms.uTime.value = elapsedSeconds * this.motion.speed;
  }

  dispose() {
    this.mesh.geometry.dispose();
    this.material.dispose();
  }
}

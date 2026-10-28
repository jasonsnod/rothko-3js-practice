// Full-screen pass: the 2 x 2 plane already spans clip space, so no camera
// transform is applied.

varying vec2 vUv;

void main() {
  vUv = uv;
  gl_Position = vec4(position.xy, 0.0, 1.0);
}

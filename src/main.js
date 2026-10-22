import * as THREE from 'three';
import { painting, palette, rects, motion } from './config.js';
import { Painting } from './Painting.js';

const container = document.getElementById('app');

const renderer = new THREE.WebGLRenderer({ antialias: false });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
renderer.setClearColor(new THREE.Color(getComputedStyle(document.body).backgroundColor));
container.appendChild(renderer.domElement);

const scene = new THREE.Scene();

// Orthographic: the painting is flat, so no perspective distortion.
const camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0.1, 10);
camera.position.z = 1;

const canvas = new Painting({ painting, palette, rects, motion });
scene.add(canvas.mesh);

// Letterbox the painting inside the viewport, leaving a margin of "wall".
function resize() {
  const width = container.clientWidth;
  const height = container.clientHeight;
  renderer.setSize(width, height);

  const viewAspect = width / height;
  // Visible world height needed so the painting fits both dimensions.
  const fitHeight = Math.max(1, canvas.aspect / viewAspect) / painting.viewportFill;

  camera.top = fitHeight / 2;
  camera.bottom = -fitHeight / 2;
  camera.left = (-fitHeight * viewAspect) / 2;
  camera.right = (fitHeight * viewAspect) / 2;
  camera.updateProjectionMatrix();
}

window.addEventListener('resize', resize);
resize();

const timer = new THREE.Timer();
timer.connect(document);

renderer.setAnimationLoop((timestamp) => {
  timer.update(timestamp);
  canvas.update(timer.getElapsed());
  renderer.render(scene, camera);
});

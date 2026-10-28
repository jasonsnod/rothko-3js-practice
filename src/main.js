import * as THREE from 'three';
import * as config from './config.js';
import { Painting } from './Painting.js';
import { FadeClock } from './FadeClock.js';

const { painting } = config;
const container = document.getElementById('app');

const renderer = new THREE.WebGLRenderer({ antialias: false });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
renderer.setClearColor(new THREE.Color(getComputedStyle(document.body).backgroundColor));
container.appendChild(renderer.domElement);

const scene = new THREE.Scene();

// Orthographic: the painting is flat, so no perspective distortion.
const camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0.1, 10);
camera.position.z = 1;

const fadeClock = new FadeClock();
const canvas = new Painting(config, fadeClock);
scene.add(canvas.mesh);

// The tuning panel is only loaded on request, keeping it out of the
// exhibition build's startup path.
if (new URLSearchParams(window.location.search).has('debug')) {
  import('./debug.js').then(({ createDebugPanel }) => createDebugPanel(canvas, config));
}

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
  canvas.update(timer.getDelta());
  renderer.render(scene, camera);
});

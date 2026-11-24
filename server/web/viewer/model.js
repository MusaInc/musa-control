// 3D preview for the Visualiser panel: loads one model from the app's
// mcvisual:// scheme and frames it. Orbit with one finger, pan with two,
// pinch to zoom. The app reloads the page when the file changes.
import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
import { OBJLoader } from "three/addons/loaders/OBJLoader.js";
import { STLLoader } from "three/addons/loaders/STLLoader.js";
import { PLYLoader } from "three/addons/loaders/PLYLoader.js";
import { ColladaLoader } from "three/addons/loaders/ColladaLoader.js";

const params = new URLSearchParams(location.search);
const src = params.get("src");
const info = document.getElementById("info");
const post = (m) => { try { window.webkit?.messageHandlers?.viewer?.postMessage(m); } catch {} };
const dark = matchMedia("(prefers-color-scheme: dark)").matches;

const renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
renderer.setSize(innerWidth, innerHeight);
renderer.outputColorSpace = THREE.SRGBColorSpace;
document.body.appendChild(renderer.domElement);
const scene = new THREE.Scene();
scene.background = new THREE.Color(dark ? 0x111214 : 0xf4f4f5);
const camera = new THREE.PerspectiveCamera(45, innerWidth / innerHeight, 0.01, 10000);
scene.add(new THREE.HemisphereLight(0xffffff, dark ? 0x222222 : 0x888888, 2.2));
const sun = new THREE.DirectionalLight(0xffffff, 2.4); sun.position.set(3, 5, 4); scene.add(sun);
const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;

function frame(obj) {
  const box = new THREE.Box3().setFromObject(obj);
  const size = box.getSize(new THREE.Vector3()), centre = box.getCenter(new THREE.Vector3());
  const r = Math.max(size.x, size.y, size.z) || 1;
  const grid = new THREE.GridHelper(r * 3, 12, dark ? 0x3f3f46 : 0xd4d4d8, dark ? 0x27272a : 0xe4e4e7);
  grid.position.y = box.min.y; scene.add(grid);
  camera.position.copy(centre).add(new THREE.Vector3(r * 1.1, r * 0.8, r * 1.4));
  camera.near = r / 100; camera.far = r * 100; camera.updateProjectionMatrix();
  controls.target.copy(centre); controls.update();
  let tris = 0; obj.traverse((o) => { if (o.isMesh) { const g = o.geometry; tris += g.index ? g.index.count / 3 : (g.attributes.position?.count || 0) / 3; } });
  info.textContent = `${Math.round(tris).toLocaleString()} triangles · ${size.x.toFixed(2)} × ${size.y.toFixed(2)} × ${size.z.toFixed(2)}`;
  post({ type: "loaded", triangles: Math.round(tris) });
}

function meshFrom(geometry) {
  geometry.computeVertexNormals?.();
  const mat = new THREE.MeshStandardMaterial({ color: geometry.attributes.color ? 0xffffff : 0xb8bcc8, vertexColors: Boolean(geometry.attributes.color), metalness: 0.05, roughness: 0.6 });
  return new THREE.Mesh(geometry, mat);
}

function fail(e) { info.textContent = `Couldn't load this model: ${e?.message || e}`; post({ type: "error", message: String(e?.message || e) }); }

const ext = (params.get("ext") || src?.split("?")[0].split(".").pop() || "").toLowerCase();
if (!src) fail("no file");
else if (ext === "glb" || ext === "gltf") new GLTFLoader().load(src, (g) => { scene.add(g.scene); frame(g.scene); }, undefined, fail);
else if (ext === "obj") new OBJLoader().load(src, (o) => { scene.add(o); frame(o); }, undefined, fail);
else if (ext === "stl") new STLLoader().load(src, (g) => { const m = meshFrom(g); scene.add(m); frame(m); }, undefined, fail);
else if (ext === "ply") new PLYLoader().load(src, (g) => { const m = meshFrom(g); scene.add(m); frame(m); }, undefined, fail);
else if (ext === "dae") new ColladaLoader().load(src, (c) => { scene.add(c.scene); frame(c.scene); }, undefined, fail);
else fail(`.${ext} isn't a supported model format`);

addEventListener("resize", () => { camera.aspect = innerWidth / innerHeight; camera.updateProjectionMatrix(); renderer.setSize(innerWidth, innerHeight); });
renderer.setAnimationLoop(() => { controls.update(); renderer.render(scene, camera); });

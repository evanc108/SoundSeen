// Intense storm — low-V, high-A biome.
//
// High-contrast turbulent noise field in blood-red and electric blue
// (a deliberate near-COMPLEMENTARY pairing — Schloss & Palmer 2011
// rate this as less harmonious, but for the Intense biome that's
// EXACTLY the affect you want; tension is the identity). Procedural
// lightning bolts fire on drops and downbeats. Frame strobes on
// heavy beats per Itti & Koch's saliency stacking — luminance
// contrast is the strongest bottom-up attention captor.
//
// V&M: high A → S≈0.95; brightness counter-modulated to ~0.85.
// Atmosphere is dark by design so the strobe punches.
//
// Bouba/Kiki: percussive content (typical for Intense) → high
// angularity → SHARP edges, hard silhouettes. Lightning bolts are
// jagged polylines, particles are square shards rather than round
// soft points. (Implementation uses Points but with smaller, harder
// material settings.)

import * as THREE from "three";
import type { Scene } from "./scene.js";
import type { FrameContext } from "../types.js";

const BG_VERTEX = /* glsl */ `
  varying vec2 vUv;
  void main() {
    vUv = uv;
    gl_Position = vec4(position, 1.0);
  }
`;

const BG_FRAGMENT = /* glsl */ `
  precision highp float;
  varying vec2 vUv;
  uniform float uTime;
  uniform float uBeat;
  uniform float uDownbeat;
  uniform float uDrop;
  uniform float uTension;
  uniform vec3  uColorRed;
  uniform vec3  uColorBlue;
  uniform vec3  uColorBlack;
  uniform float uSaturation;
  uniform float uBrightness;

  float hash(vec2 p) {
    p = fract(p * vec2(443.897, 441.423));
    p += dot(p, p.yx + 19.19);
    return fract((p.x + p.y) * p.x);
  }
  float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x),
               mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
  }
  // Two-octave fractal noise — turbulent stormcloud feel without
  // expensive multi-octave summation.
  float fbm(vec2 p) {
    return noise(p) * 0.65 + noise(p * 2.13) * 0.35;
  }

  vec3 desaturate(vec3 col, float amt) {
    float l = dot(col, vec3(0.299, 0.587, 0.114));
    return mix(vec3(l), col, amt);
  }

  void main() {
    vec2 uv = vUv;
    vec2 d = uv - vec2(0.5, 0.5);

    // Stormcloud — fbm with horizontal scrolling, shaped by a
    // top-heavy gradient so the cloud lives in the upper half.
    vec2 p = uv * vec2(2.5, 1.6) + vec2(uTime * 0.10, uTime * 0.04);
    float cloud = fbm(p);
    cloud = pow(cloud, 1.7);  // sharpen contrast — Intense should not look soft

    // Color: red dominates, blue accent in dim areas (contrast singleton
    // per Itti-Koch — opposite hue captures attention against the warm field).
    vec3 col = mix(uColorBlack, uColorRed, cloud);
    col = mix(col, uColorBlue, smoothstep(0.45, 0.20, cloud) * 0.45);

    // Beat strobe — abrupt luminance increment on heavy beats.
    // Itti & Koch (2001) — sudden luminance changes are the strongest
    // bottom-up attention captor. Keep the strobe brief & jerky.
    if (uDownbeat > 0.4) {
      col += vec3(uDownbeat * 0.55);
    }

    // Drop: full-frame fracture — invert + flash.
    col = mix(col, vec3(1.0) - col, uDrop * 0.50);
    col += vec3(uDrop * 0.35);

    // Tension drives a screen-warping shake-feel via low-amplitude UV
    // perturbation contributing to the cloud sample (above we used
    // raw uv; this is a second pass for "pressure" feel).
    float pressure = fbm(uv * 5.0 + uTime * 0.5) * uTension * 0.20;
    col += vec3(pressure * 0.4, pressure * 0.1, pressure * 0.5);

    // Vignette — Intense should feel claustrophobic.
    float r = length(d) * 1.4;
    col *= smoothstep(1.5, 0.20, r);

    col = desaturate(col, uSaturation);
    col *= uBrightness;
    gl_FragColor = vec4(col, 1.0);
  }
`;

interface Bolt {
  /// Spawn time of the bolt; bolt lives ~120ms.
  t0: number;
  /// Pre-computed jagged polyline points (NDC).
  points: Float32Array;
  alpha: number;
}

export class IntenseStormScene implements Scene {
  readonly object3D: THREE.Scene;
  readonly camera: THREE.PerspectiveCamera;

  private bgMaterial: THREE.ShaderMaterial;
  private particles: THREE.Points;
  private particleMaterial: THREE.PointsMaterial;
  private positions: Float32Array;
  private static readonly PARTICLE_COUNT = 220;

  // Lightning bolts: each bolt is a short-lived line segment set.
  private boltGeometry: THREE.BufferGeometry;
  private boltMaterial: THREE.LineBasicMaterial;
  private boltLines: THREE.LineSegments;
  private boltBuffer: Float32Array;
  private static readonly MAX_BOLT_VERTS = 256;
  private prevDownbeat = 0;
  private prevDrop = 0;

  constructor() {
    this.object3D = new THREE.Scene();
    this.camera = new THREE.PerspectiveCamera(50, 16 / 9, 0.1, 100);
    this.camera.position.set(0, 0, 4);

    this.bgMaterial = new THREE.ShaderMaterial({
      vertexShader: BG_VERTEX,
      fragmentShader: BG_FRAGMENT,
      uniforms: {
        uTime: { value: 0 },
        uBeat: { value: 0 },
        uDownbeat: { value: 0 },
        uDrop: { value: 0 },
        uTension: { value: 0.5 },
        uColorRed:   { value: new THREE.Color("#c81e2a") }, // blood red
        uColorBlue:  { value: new THREE.Color("#3868d8") }, // electric blue
        uColorBlack: { value: new THREE.Color("#0a0612") }, // dark base
        uSaturation: { value: 1.0 },
        uBrightness: { value: 1.0 },
      },
      depthTest: false,
      depthWrite: false,
    });
    const bg = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), this.bgMaterial);
    bg.frustumCulled = false;
    bg.renderOrder = -10;
    this.object3D.add(bg);

    // Sharp percussive shards — small, hard-edged points in pale electric.
    const N = IntenseStormScene.PARTICLE_COUNT;
    this.positions = new Float32Array(N * 3);
    for (let i = 0; i < N; i++) {
      this.positions[i * 3 + 0] = (Math.random() - 0.5) * 7;
      this.positions[i * 3 + 1] = (Math.random() - 0.5) * 5;
      this.positions[i * 3 + 2] = -Math.random() * 3.0;
    }
    const pgeo = new THREE.BufferGeometry();
    pgeo.setAttribute("position", new THREE.BufferAttribute(this.positions, 3));
    this.particleMaterial = new THREE.PointsMaterial({
      color: new THREE.Color("#a8c8ff"),
      size: 0.025,
      sizeAttenuation: true,
      transparent: true,
      opacity: 0.45,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    });
    this.particles = new THREE.Points(pgeo, this.particleMaterial);
    this.object3D.add(this.particles);

    // Lightning lines — preallocated buffer, written each frame.
    this.boltBuffer = new Float32Array(IntenseStormScene.MAX_BOLT_VERTS * 3);
    this.boltGeometry = new THREE.BufferGeometry();
    this.boltGeometry.setAttribute("position", new THREE.BufferAttribute(this.boltBuffer, 3));
    this.boltMaterial = new THREE.LineBasicMaterial({
      color: new THREE.Color("#e8f0ff"),
      transparent: true,
      opacity: 0.0,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    });
    this.boltLines = new THREE.LineSegments(this.boltGeometry, this.boltMaterial);
    this.object3D.add(this.boltLines);
  }

  render(ctx: FrameContext): void {
    const u = this.bgMaterial.uniforms;
    u.uTime.value = ctx.t;
    u.uBeat.value = ctx.beatPulse;
    u.uDownbeat.value = ctx.downbeatPulse;
    u.uDrop.value = ctx.dropImpulse;
    u.uTension.value = ctx.section?.tension ?? 0.5;

    const sectionGainSat = ctx.section?.saturation ?? 1.0;
    const sectionGainBri = ctx.section?.brightness ?? 1.0;
    u.uSaturation.value = ctx.vmSaturation * (sectionGainSat / Math.max(0.5, ctx.vmSaturation));
    u.uBrightness.value = ctx.vmBrightness * (sectionGainBri / Math.max(0.5, ctx.vmBrightness));

    // Trigger a bolt on the rising edge of downbeatPulse / dropImpulse
    // (i.e., when these values just spiked above a threshold).
    const downbeatFiring = ctx.downbeatPulse > 0.85 && this.prevDownbeat <= 0.85;
    const dropFiring = ctx.dropImpulse > 0.5 && this.prevDrop <= 0.5;
    this.prevDownbeat = ctx.downbeatPulse;
    this.prevDrop = ctx.dropImpulse;

    let vertCount = 0;
    if (downbeatFiring || dropFiring) {
      vertCount = this.writeBolt(ctx.t, dropFiring ? 1.4 : 0.9);
    }
    this.boltGeometry.setDrawRange(0, vertCount);
    (this.boltGeometry.getAttribute("position") as THREE.BufferAttribute).needsUpdate = true;
    this.boltMaterial.opacity =
      Math.max(ctx.downbeatPulse, ctx.dropImpulse * 1.3) * 0.95;

    // Particles drift slightly with subtle jitter on beats — Intense
    // wants edges to feel agitated, not floating-calm.
    const pos = this.particles.geometry.getAttribute("position") as THREE.BufferAttribute;
    const jitter = ctx.beatPulse * 0.04;
    for (let i = 0; i < IntenseStormScene.PARTICLE_COUNT; i++) {
      this.positions[i * 3 + 0] += (Math.sin(ctx.t * 4 + i) * 0.001) + (Math.random() - 0.5) * jitter * 0.05;
      this.positions[i * 3 + 1] += (Math.cos(ctx.t * 3 + i) * 0.001) + (Math.random() - 0.5) * jitter * 0.05;
    }
    pos.needsUpdate = true;
  }

  /// Write a jagged polyline lightning bolt into the line-segment
  /// buffer. Returns the number of vertices written (must be even).
  private writeBolt(seedTime: number, intensity: number): number {
    const SEGMENTS = 10;
    const BRANCHES = intensity > 1.0 ? 3 : 1;
    let v = 0;

    const rand = (s: number) => {
      const x = Math.sin(s * 12.9898 + seedTime * 78.233) * 43758.5453;
      return x - Math.floor(x);
    };

    for (let b = 0; b < BRANCHES; b++) {
      // Bolt origin: random point near top of frame, descending downward.
      const x0 = (rand(b * 17.3) - 0.5) * 5;
      let x = x0;
      let y = 2.5;
      const targetY = -2.0 - rand(b * 31.7) * 0.5;
      const stepY = (targetY - y) / SEGMENTS;

      for (let s = 0; s < SEGMENTS && v < IntenseStormScene.MAX_BOLT_VERTS - 2; s++) {
        const x2 = x + (rand(b * 7 + s * 13.1) - 0.5) * 0.7 * intensity;
        const y2 = y + stepY;

        this.boltBuffer[v * 3 + 0] = x;
        this.boltBuffer[v * 3 + 1] = y;
        this.boltBuffer[v * 3 + 2] = 0;
        v++;
        this.boltBuffer[v * 3 + 0] = x2;
        this.boltBuffer[v * 3 + 1] = y2;
        this.boltBuffer[v * 3 + 2] = 0;
        v++;

        x = x2;
        y = y2;
      }
    }
    return v;
  }

  dispose(): void {
    this.bgMaterial.dispose();
    this.particleMaterial.dispose();
    this.particles.geometry.dispose();
    this.boltMaterial.dispose();
    this.boltGeometry.dispose();
  }
}

// Serene dawn — high-V, low-A biome.
//
// Slow-drifting noise field in pastel teal/peach with soft bokeh particles
// and a gentle radial god-ray wash. Beats register as soft ripples; drops
// are heavily softened (this biome doesn't punch).
//
// MVP-level implementation: the goal here is the SHAPE of the pipeline,
// not flagship visual quality. Iterate on the fragment shader (or swap in
// Pavel Dobryakov's WebGL fluid sim later) to push fidelity.

import * as THREE from "three";
import type { Scene } from "./scene";
import type { FrameContext } from "../types";

const BG_VERTEX = /* glsl */ `
  varying vec2 vUv;
  void main() {
    vUv = uv;
    gl_Position = vec4(position, 1.0);
  }
`;

// Two octaves of value noise sampled in slow-drifting UV space, blended
// with a radial gradient so the center reads as the light source.
const BG_FRAGMENT = /* glsl */ `
  precision highp float;
  varying vec2 vUv;
  uniform float uTime;
  uniform float uBeat;
  uniform float uDrop;
  uniform vec3  uColorCore;
  uniform vec3  uColorEdge;
  uniform float uSaturation;
  uniform float uBrightness;

  // Hash without sin — cheap, no driver-specific drift.
  float hash(vec2 p) {
    p = fract(p * vec2(443.897, 441.423));
    p += dot(p, p.yx + 19.19);
    return fract((p.x + p.y) * p.x);
  }

  float valueNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
  }

  vec3 desaturate(vec3 col, float amt) {
    float l = dot(col, vec3(0.299, 0.587, 0.114));
    return mix(vec3(l), col, amt);
  }

  void main() {
    vec2 uv = vUv;
    vec2 p = uv * 2.5 + vec2(uTime * 0.03, uTime * 0.018);
    float n = valueNoise(p) * 0.6 + valueNoise(p * 2.1) * 0.4;

    // Radial falloff so the frame has a visible "source" rather than
    // reading as a flat field.
    float r = length(uv - 0.5) * 1.8;
    float vignette = smoothstep(1.0, 0.2, r);

    // Beat ripple — small radial pulse that biases the noise outward.
    float ripple = uBeat * (1.0 - smoothstep(0.0, 0.6, abs(r - uBeat * 0.4)));

    float lum = vignette * (0.5 + 0.5 * n) + ripple * 0.25;
    lum += uDrop * 0.20 * (1.0 - r);

    vec3 col = mix(uColorEdge, uColorCore, lum);
    col = desaturate(col, uSaturation);
    col *= uBrightness;
    gl_FragColor = vec4(col, 1.0);
  }
`;

export class SereneDawnScene implements Scene {
  readonly object3D: THREE.Scene;
  readonly camera: THREE.PerspectiveCamera;

  private bgMaterial: THREE.ShaderMaterial;
  private particles: THREE.Points;
  private particleMaterial: THREE.PointsMaterial;
  private particlePositions: Float32Array;

  constructor() {
    this.object3D = new THREE.Scene();
    this.camera = new THREE.PerspectiveCamera(50, 16 / 9, 0.1, 100);
    this.camera.position.set(0, 0, 4);

    // Full-screen background quad with the noise/god-ray fragment shader.
    this.bgMaterial = new THREE.ShaderMaterial({
      vertexShader: BG_VERTEX,
      fragmentShader: BG_FRAGMENT,
      uniforms: {
        uTime: { value: 0 },
        uBeat: { value: 0 },
        uDrop: { value: 0 },
        uColorCore: { value: new THREE.Color("#ffd9b8") }, // peach
        uColorEdge: { value: new THREE.Color("#3a6b73") }, // deep teal
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

    // Soft drifting bokeh particles in the foreground.
    const N = 220;
    this.particlePositions = new Float32Array(N * 3);
    for (let i = 0; i < N; i++) {
      this.particlePositions[i * 3 + 0] = (Math.random() - 0.5) * 6;
      this.particlePositions[i * 3 + 1] = (Math.random() - 0.5) * 4;
      this.particlePositions[i * 3 + 2] = -(Math.random() * 3.0);
    }
    const geo = new THREE.BufferGeometry();
    geo.setAttribute("position", new THREE.BufferAttribute(this.particlePositions, 3));

    this.particleMaterial = new THREE.PointsMaterial({
      color: new THREE.Color("#fff2dc"),
      size: 0.04,
      sizeAttenuation: true,
      transparent: true,
      opacity: 0.55,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    });
    this.particles = new THREE.Points(geo, this.particleMaterial);
    this.object3D.add(this.particles);
  }

  render(ctx: FrameContext): void {
    const u = this.bgMaterial.uniforms;
    u.uTime.value = ctx.t;
    // Soften beats — this biome doesn't punch on the beat.
    u.uBeat.value = ctx.beatPulse * 0.45;
    u.uDrop.value = ctx.dropImpulse * 0.30;

    if (ctx.section) {
      u.uSaturation.value = ctx.section.saturation;
      u.uBrightness.value = ctx.section.brightness;
    }

    // Gentle drift so the bokeh feels alive, not stamped.
    const pos = this.particles.geometry.getAttribute("position") as THREE.BufferAttribute;
    for (let i = 0; i < pos.count; i++) {
      const y = this.particlePositions[i * 3 + 1] + Math.sin(ctx.t * 0.18 + i) * 0.0015;
      pos.setY(i, y);
    }
    pos.needsUpdate = true;
    this.particles.material.opacity = 0.45 + ctx.beatPulse * 0.20;
  }

  dispose(): void {
    this.bgMaterial.dispose();
    this.particleMaterial.dispose();
    this.particles.geometry.dispose();
  }
}

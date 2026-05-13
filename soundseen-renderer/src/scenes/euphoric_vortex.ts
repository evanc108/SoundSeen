// Euphoric Bloom keystone hero — a vortex tunnel of light streaks
// flying toward the camera, plus an aurora overlay. Replaces the "oval
// pulsing" feel of the prior radial particle bloom with a sense of
// motion *through space*.
//
// Vortex: InstancedBufferGeometry of long thin quads oriented along
// world-Z. Each instance spins around the z-axis on its own radius and
// phase, with z cycling continuously from -depth to +0.5 over its life.
//
// Aurora curtain: full-screen overlay quad with horizontally drifting
// fbm sheets of color, hue rotated by chroma_center direction, alpha
// gated to the upper half of the frame.
//
// Audio mapping:
//   speed multiplier   ← rms + spectral_flux + onset_strength_env
//   live count         ← 200 + build · 800
//   hue rotation       ← atan2(chroma_center_y, chroma_center_x)
//   spawn brightness   ← chroma_strength + beat_pulse
//   aurora drift       ← spectral_flux
//   aurora saturation  ← chroma_strength
//   aurora hue         ← chroma_center angle

import * as THREE from "three";
import type { CompositionSpec, FrameContext } from "../types.js";
import { hash1, hash2 } from "./lib/deterministic_hash.js";

const VORTEX_VERT = /* glsl */ `
  attribute vec3 aInstanceRA;   // x=radius, y=baseAngle, z=phaseSpeed
  attribute float aPhaseOffset;
  attribute vec3 aColor;

  uniform float uTime;
  uniform float uTunnelDepth;
  uniform float uSpeedMult;
  uniform float uHueShift;

  varying vec2 vUv;
  varying vec3 vColor;
  varying float vNearness;
  varying float vSpeed;

  void main() {
    float radius = aInstanceRA.x;
    float baseAngle = aInstanceRA.y;
    float speed = aInstanceRA.z;

    // t cycles 0..1 — z goes from -depth (far) to +0.5 (past camera).
    float t = fract(uTime * speed * uSpeedMult * 0.18 + aPhaseOffset);
    float z = mix(-uTunnelDepth, 0.5, t);

    // Spiral: per-instance angle drifts slowly + small phase from t.
    float angle = baseAngle + uTime * 0.35 + t * 0.5;

    vec3 worldPos = vec3(
      cos(angle) * radius,
      sin(angle) * radius,
      z
    );

    // Streak orientation: long axis along world +Z, width axis chosen
    // to be perpendicular to view direction.
    vec3 streakAxis = vec3(0.0, 0.0, 1.0);
    vec3 toCam = normalize(cameraPosition - worldPos);
    vec3 widthAxis = normalize(cross(streakAxis, toCam));

    float streakLen = 0.30 + speed * 0.55;
    float streakWidth = 0.022;

    vec3 offset = position.x * streakWidth * widthAxis
                + position.y * streakLen * streakAxis;

    gl_Position = projectionMatrix * viewMatrix * vec4(worldPos + offset, 1.0);

    vUv = uv;
    // Hue-rotate the per-instance color by uHueShift radians using a
    // cheap RGB rotation matrix (axis = (1,1,1)/sqrt(3)).
    float cs = cos(uHueShift);
    float sn = sin(uHueShift);
    float omcs = 1.0 - cs;
    float k = 0.5773503;
    mat3 R = mat3(
      cs + k*k*omcs,        k*k*omcs - k*sn,     k*k*omcs + k*sn,
      k*k*omcs + k*sn,      cs + k*k*omcs,       k*k*omcs - k*sn,
      k*k*omcs - k*sn,      k*k*omcs + k*sn,     cs + k*k*omcs
    );
    vColor = R * aColor;
    vNearness = 1.0 - t;   // 1 far, 0 near (use to fade in then peak then out)
    vSpeed = speed;
  }
`;

const VORTEX_FRAG = /* glsl */ `
  precision highp float;
  uniform float uBeatPulse;

  varying vec2 vUv;
  varying vec3 vColor;
  varying float vNearness;
  varying float vSpeed;

  void main() {
    // Width taper — gaussian falloff from center to edges
    float wDist = abs(vUv.x - 0.5);
    float wA = smoothstep(0.5, 0.0, wDist);

    // Length taper — peak in middle, fade at both ends, with the
    // leading half (vUv.y > 0.5) glowing brighter (head of comet).
    float lTaper = smoothstep(0.0, 0.20, vUv.y) * smoothstep(1.0, 0.80, vUv.y);
    float head = smoothstep(0.50, 0.95, vUv.y);

    // Birth/death fade so particles don't pop in/out at the cycle seam.
    // vNearness peaks at 0 (just past camera); fade in at vNearness > 0.9
    // (just spawned at far) and fade out at vNearness < 0.05 (right at cam).
    float lifeFade = smoothstep(1.0, 0.9, vNearness) * smoothstep(0.0, 0.06, vNearness);

    float a = wA * lTaper * lifeFade * (0.6 + uBeatPulse * 0.5);

    vec3 col = vColor * (0.8 + head * 0.7) * (1.0 + uBeatPulse * 0.4);

    gl_FragColor = vec4(col, a);
  }
`;

const AURORA_VERT = /* glsl */ `
  varying vec2 vUv;
  void main() {
    vUv = uv;
    gl_Position = vec4(position, 1.0);
  }
`;

const AURORA_FRAG = /* glsl */ `
  precision highp float;
  uniform float uTime;
  uniform float uDrift;
  uniform float uIntensity;
  uniform float uHueShift;
  uniform vec3 uColorA;
  uniform vec3 uColorB;

  varying vec2 vUv;

  float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
  float noise(vec2 p) {
    vec2 i = floor(p); vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i),                hash(i + vec2(1,0)), u.x),
               mix(hash(i + vec2(0,1)),    hash(i + vec2(1,1)), u.x), u.y);
  }
  float fbm(vec2 p) {
    return noise(p) * 0.55 + noise(p * 2.1) * 0.30 + noise(p * 4.3) * 0.15;
  }

  void main() {
    // Aurora occupies the upper 55% of the frame, fading out below.
    float vMask = smoothstep(0.30, 0.80, vUv.y);
    if (vMask < 0.01) discard;

    vec2 q = vec2(vUv.x * 3.5 + uTime * uDrift,
                  vUv.y * 1.5 + sin(vUv.x * 6.0 + uTime * 0.3) * 0.08);
    // Single-pass fbm — was nested (fbm of fbm) but that was the wall-
    // clock bottleneck on long renders. Visually near-identical at this
    // scale.
    float curtain = fbm(q);
    curtain = smoothstep(0.45, 0.85, curtain);

    // Hue-shift base color via cheap rotation, mix between two tones
    // along the vertical axis.
    vec3 base = mix(uColorA, uColorB, vUv.y);
    float cs = cos(uHueShift);
    float sn = sin(uHueShift);
    float omcs = 1.0 - cs;
    float k = 0.5773503;
    mat3 R = mat3(
      cs + k*k*omcs,        k*k*omcs - k*sn,     k*k*omcs + k*sn,
      k*k*omcs + k*sn,      cs + k*k*omcs,       k*k*omcs - k*sn,
      k*k*omcs - k*sn,      k*k*omcs + k*sn,     cs + k*k*omcs
    );
    vec3 col = R * base;

    float a = curtain * vMask * uIntensity;
    gl_FragColor = vec4(col, a);
  }
`;

export class EuphoricBloomHero {
  readonly object3D: THREE.Group;
  private vortexMesh: THREE.Mesh;
  private vortexMaterial: THREE.ShaderMaterial;
  private vortexGeometry: THREE.InstancedBufferGeometry;
  private auroraMesh: THREE.Mesh;
  private auroraMaterial: THREE.ShaderMaterial;
  private static readonly POOL_SIZE = 1200;

  constructor() {
    this.object3D = new THREE.Group();

    // ---- Vortex tunnel ----
    this.vortexGeometry = new THREE.InstancedBufferGeometry();
    const quadPos = new Float32Array([
      -0.5, -0.5, 0,
       0.5, -0.5, 0,
       0.5,  0.5, 0,
      -0.5,  0.5, 0,
    ]);
    const quadUv = new Float32Array([0,0, 1,0, 1,1, 0,1]);
    const quadIdx = new Uint16Array([0, 1, 2, 0, 2, 3]);
    this.vortexGeometry.setAttribute("position", new THREE.BufferAttribute(quadPos, 3));
    this.vortexGeometry.setAttribute("uv", new THREE.BufferAttribute(quadUv, 2));
    this.vortexGeometry.setIndex(new THREE.BufferAttribute(quadIdx, 1));

    const N = EuphoricBloomHero.POOL_SIZE;
    const ra = new Float32Array(N * 3);
    const phase = new Float32Array(N);
    const colors = new Float32Array(N * 3);
    for (let i = 0; i < N; i++) {
      // Radius: log-distributed so density is higher near center axis
      // (creates a denser core of streaks). Range ~0.3 to 4.5.
      const u = hash1(i + 1);
      const radius = 0.3 + Math.pow(u, 0.6) * 4.2;
      const angle = hash2(i, 1) * Math.PI * 2;
      const speed = 0.7 + hash2(i, 3) * 1.6;   // base axial speed
      ra[i * 3 + 0] = radius;
      ra[i * 3 + 1] = angle;
      ra[i * 3 + 2] = speed;
      phase[i] = hash2(i, 7);

      // Per-instance color: warm magenta-yellow spread.
      const h = hash2(i, 11);
      const r = 1.0;
      const g = 0.45 + h * 0.45;
      const b = 0.55 + (1 - h) * 0.45;
      colors[i * 3 + 0] = r;
      colors[i * 3 + 1] = g;
      colors[i * 3 + 2] = b;
    }
    this.vortexGeometry.setAttribute("aInstanceRA", new THREE.InstancedBufferAttribute(ra, 3));
    this.vortexGeometry.setAttribute("aPhaseOffset", new THREE.InstancedBufferAttribute(phase, 1));
    this.vortexGeometry.setAttribute("aColor", new THREE.InstancedBufferAttribute(colors, 3));
    this.vortexGeometry.instanceCount = 200;

    this.vortexMaterial = new THREE.ShaderMaterial({
      vertexShader: VORTEX_VERT,
      fragmentShader: VORTEX_FRAG,
      uniforms: {
        uTime: { value: 0 },
        uTunnelDepth: { value: 14.0 },
        uSpeedMult: { value: 1.0 },
        uHueShift: { value: 0 },
        uBeatPulse: { value: 0 },
      },
      transparent: true,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    });
    this.vortexMesh = new THREE.Mesh(this.vortexGeometry, this.vortexMaterial);
    this.vortexMesh.frustumCulled = false;
    this.object3D.add(this.vortexMesh);

    // ---- Aurora curtain ----
    this.auroraMaterial = new THREE.ShaderMaterial({
      vertexShader: AURORA_VERT,
      fragmentShader: AURORA_FRAG,
      uniforms: {
        uTime: { value: 0 },
        uDrift: { value: 0.05 },
        uIntensity: { value: 0 },
        uHueShift: { value: 0 },
        uColorA: { value: new THREE.Color("#a04eff") },   // magenta
        uColorB: { value: new THREE.Color("#ffcc66") },   // amber-gold
      },
      transparent: true,
      blending: THREE.AdditiveBlending,
      depthTest: false,
      depthWrite: false,
    });
    this.auroraMesh = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), this.auroraMaterial);
    this.auroraMesh.frustumCulled = false;
    this.auroraMesh.renderOrder = -7;
    this.object3D.add(this.auroraMesh);
  }

  update(_spec: CompositionSpec, ctx: FrameContext): void {
    // ---- Vortex ----
    const v = this.vortexMaterial.uniforms;
    v.uTime.value = ctx.t;
    const audio = ctx.audio;
    // Speed picks up huge boost on drops — the tunnel surges forward.
    v.uSpeedMult.value =
      0.6 + audio.rms * 1.0 + audio.spectralFlux * 1.0
          + audio.onsetStrengthEnv * 0.8 + ctx.dropImpulse * 2.5;
    // Hue shifts with chord centroid; drop adds an extra rotational
    // kick so the color identity changes across the drop event.
    v.uHueShift.value =
      Math.atan2(audio.chromaCenterY, audio.chromaCenterX)
      + ctx.dropImpulse * 1.2;
    v.uBeatPulse.value = ctx.beatPulse + ctx.phrasePulse * 0.5;

    // Live count: 200 baseline (always some motion), up to 1200 at climax.
    const live = Math.min(
      EuphoricBloomHero.POOL_SIZE,
      200 + Math.round(ctx.buildIntensity * 1000),
    );
    this.vortexGeometry.instanceCount = live;

    // ---- Aurora ----
    const a = this.auroraMaterial.uniforms;
    a.uTime.value = ctx.t;
    a.uDrift.value = 0.05 + audio.spectralFlux * 0.30;
    a.uIntensity.value = 0.20 + audio.chromaStrength * 0.45 + ctx.beatPulse * 0.15;
    a.uHueShift.value = Math.atan2(audio.chromaCenterY, audio.chromaCenterX) * 0.6;
  }

  dispose(): void {
    this.vortexMaterial.dispose();
    this.vortexGeometry.dispose();
    this.auroraMaterial.dispose();
    this.auroraMesh.geometry.dispose();
  }
}

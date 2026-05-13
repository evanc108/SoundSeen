// Intense Storm keystone hero — turbulent storm wall + persistent
// lightning afterglow.
//
// The existing scene fires a single short-lived bolt on downbeat/drop
// rising edges. This hero adds:
//   - A dark turbulent cloud wall filling the upper 2/3 of the frame,
//     animated via single-pass fbm (cheap), brightening dramatically
//     when lightning fires.
//   - Persistent afterglow: each fired bolt's geometry is held in a
//     short ring buffer and rendered with a decaying additive glow
//     for ~1.4s after the flash.
//
// Audio mapping:
//   storm wall darkness     ← 0.5 + tension·0.4 - centroid·0.2
//   storm wall turbulence   ← 0.2 + flux·0.6
//   afterglow trigger       ← downbeat OR drop rising edge (same as bolts)
//   afterglow lifespan      ← scaled by drop_impulse vs downbeat
//   afterglow color         ← cool electric blue → pale white at climax

import * as THREE from "three";
import type { CompositionSpec, FrameContext } from "../types.js";
import { hash1, hash2 } from "./lib/deterministic_hash.js";

const WALL_VERT = /* glsl */ `
  varying vec2 vUv;
  void main() {
    vUv = uv;
    gl_Position = vec4(position, 1.0);
  }
`;

const WALL_FRAG = /* glsl */ `
  precision highp float;
  uniform float uTime;
  uniform float uDarkness;       // 0..1
  uniform float uTurbulence;     // 0..1
  uniform float uFlash;          // current lightning impulse
  uniform vec3  uCloudColor;
  uniform vec3  uFlashColor;

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
    // Wall lives in upper 2/3 of frame.
    float vMask = smoothstep(0.10, 0.65, vUv.y);
    if (vMask < 0.01) discard;

    // Two layers of turbulence at slightly different speeds for depth.
    vec2 q1 = vec2(vUv.x * 3.0 + uTime * 0.06, vUv.y * 1.5 + uTime * 0.02);
    vec2 q2 = vec2(vUv.x * 5.0 - uTime * 0.04, vUv.y * 2.0 + uTime * 0.03);
    float clouds = mix(fbm(q1), fbm(q2), 0.4);
    clouds = mix(clouds, smoothstep(0.4, 0.8, clouds), uTurbulence);

    vec3 col = uCloudColor * (0.25 + clouds * 0.55);
    // Brighten dramatically on lightning flash.
    col += uFlashColor * uFlash * (0.4 + clouds * 0.7);
    col *= 1.0 - uDarkness * 0.5;

    float a = vMask * (0.55 + clouds * 0.35) * (0.85 + uFlash * 0.15);
    gl_FragColor = vec4(col, a);
  }
`;

const MAX_AFTERGLOWS = 6;
const AFTERGLOW_LIFE = 1.4; // seconds

interface AfterglowSlot {
  startTime: number;
  intensity: number;
  // Vertex count: bolt geometry copied into a per-slot buffer
  vertCount: number;
}

export class IntenseLightningScene {
  readonly object3D: THREE.Group;
  readonly storm: THREE.Mesh;
  private wallMaterial: THREE.ShaderMaterial;
  private afterglowMaterial: THREE.ShaderMaterial;
  private afterglowGeometry: THREE.BufferGeometry;
  private afterglowBuffer: Float32Array;        // (MAX_AFTERGLOWS × MAX_BOLT_VERTS × 3)
  private afterglowAges: Float32Array;          // per-vertex age uniform (passed as attribute? use perVertex slot index)
  private afterglowSlotAttr: Float32Array;      // per-vertex slot index (0..MAX_AFTERGLOWS-1)
  private slotStartTimes: Float32Array;         // MAX_AFTERGLOWS — uniform array
  private slotIntensities: Float32Array;        // MAX_AFTERGLOWS — uniform array
  private slotVertCounts: number[];
  private writeIdx = 0;
  private static readonly VERTS_PER_BOLT = 64;

  constructor() {
    this.object3D = new THREE.Group();

    // ---- Storm wall ----
    this.wallMaterial = new THREE.ShaderMaterial({
      vertexShader: WALL_VERT,
      fragmentShader: WALL_FRAG,
      uniforms: {
        uTime: { value: 0 },
        uDarkness: { value: 0.6 },
        uTurbulence: { value: 0.5 },
        uFlash: { value: 0 },
        uCloudColor: { value: new THREE.Color("#2a3550") },     // cool dark
        uFlashColor: { value: new THREE.Color("#d0e0ff") },     // electric white
      },
      transparent: true,
      blending: THREE.NormalBlending,
      depthTest: false,
      depthWrite: false,
    });
    this.storm = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), this.wallMaterial);
    this.storm.frustumCulled = false;
    this.storm.renderOrder = -9;
    this.object3D.add(this.storm);

    // ---- Lightning afterglow ----
    // Each slot holds up to VERTS_PER_BOLT vertices. The shader fades
    // the per-slot intensity based on (uTime - slotStartTime) / LIFE.
    const totalVerts = MAX_AFTERGLOWS * IntenseLightningScene.VERTS_PER_BOLT;
    this.afterglowBuffer = new Float32Array(totalVerts * 3);
    this.afterglowSlotAttr = new Float32Array(totalVerts);
    this.afterglowAges = new Float32Array(totalVerts);
    this.slotStartTimes = new Float32Array(MAX_AFTERGLOWS).fill(-1000);
    this.slotIntensities = new Float32Array(MAX_AFTERGLOWS);
    this.slotVertCounts = new Array(MAX_AFTERGLOWS).fill(0);

    for (let s = 0; s < MAX_AFTERGLOWS; s++) {
      for (let v = 0; v < IntenseLightningScene.VERTS_PER_BOLT; v++) {
        this.afterglowSlotAttr[s * IntenseLightningScene.VERTS_PER_BOLT + v] = s;
      }
    }

    this.afterglowGeometry = new THREE.BufferGeometry();
    this.afterglowGeometry.setAttribute(
      "position",
      new THREE.BufferAttribute(this.afterglowBuffer, 3),
    );
    this.afterglowGeometry.setAttribute(
      "aSlotIdx",
      new THREE.BufferAttribute(this.afterglowSlotAttr, 1),
    );
    this.afterglowGeometry.setDrawRange(0, 0);

    this.afterglowMaterial = new THREE.ShaderMaterial({
      vertexShader: /* glsl */ `
        attribute float aSlotIdx;
        uniform float uTime;
        uniform float uSlotStart[${MAX_AFTERGLOWS}];
        uniform float uSlotIntensity[${MAX_AFTERGLOWS}];
        varying float vAlpha;
        void main() {
          int idx = int(aSlotIdx + 0.5);
          float age = uTime - uSlotStart[idx];
          float life = ${AFTERGLOW_LIFE.toFixed(3)};
          float t = clamp(age / life, 0.0, 1.0);
          // Quick attack, slow fade — exp decay scaled by per-slot intensity.
          vAlpha = uSlotIntensity[idx] * exp(-t * 3.0) * step(0.0, age);
          gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
        }
      `,
      fragmentShader: /* glsl */ `
        precision highp float;
        uniform vec3 uColor;
        varying float vAlpha;
        void main() {
          gl_FragColor = vec4(uColor * (0.6 + vAlpha * 1.4), vAlpha * 0.85);
        }
      `,
      uniforms: {
        uTime: { value: 0 },
        uSlotStart: { value: new Float32Array(MAX_AFTERGLOWS).fill(-1000) },
        uSlotIntensity: { value: new Float32Array(MAX_AFTERGLOWS) },
        uColor: { value: new THREE.Color("#e8f0ff") },
      },
      transparent: true,
      blending: THREE.AdditiveBlending,
      depthTest: false,
      depthWrite: false,
    });

    const lines = new THREE.LineSegments(this.afterglowGeometry, this.afterglowMaterial);
    lines.frustumCulled = false;
    lines.renderOrder = 10;
    this.object3D.add(lines);
  }

  /// Push a fired bolt (as a flat XYZ vertex array) into the next
  /// afterglow slot. Caller passes the same vertex buffer it writes
  /// into the live bolt LineSegments, plus the vertex count.
  pushBolt(boltVerts: Float32Array, vertCount: number, t: number, intensity: number): void {
    const slot = this.writeIdx;
    this.writeIdx = (this.writeIdx + 1) % MAX_AFTERGLOWS;
    const slotOffset = slot * IntenseLightningScene.VERTS_PER_BOLT * 3;
    const copyVerts = Math.min(vertCount, IntenseLightningScene.VERTS_PER_BOLT);
    for (let i = 0; i < copyVerts * 3; i++) {
      this.afterglowBuffer[slotOffset + i] = boltVerts[i]!;
    }
    // Zero out unused vertices in this slot.
    for (let i = copyVerts * 3; i < IntenseLightningScene.VERTS_PER_BOLT * 3; i++) {
      this.afterglowBuffer[slotOffset + i] = 0;
    }
    this.slotStartTimes[slot] = t;
    this.slotIntensities[slot] = intensity;
    this.slotVertCounts[slot] = copyVerts;

    (this.afterglowGeometry.getAttribute("position") as THREE.BufferAttribute).needsUpdate = true;
    // Draw all slots — the shader culls expired ones via vAlpha=0.
    this.afterglowGeometry.setDrawRange(0, MAX_AFTERGLOWS * IntenseLightningScene.VERTS_PER_BOLT);
  }

  update(_spec: CompositionSpec, ctx: FrameContext): void {
    // Storm wall driven by section tension + audio.
    const tension = ctx.section?.tension ?? 0.5;
    const w = this.wallMaterial.uniforms;
    w.uTime.value = ctx.t;
    w.uDarkness.value = 0.4 + tension * 0.4 - ctx.audio.centroid * 0.2;
    w.uTurbulence.value = 0.25 + ctx.audio.spectralFlux * 0.6;
    // Flash uniform tracks downbeatPulse + dropImpulse (both fire bolts).
    w.uFlash.value = Math.max(ctx.downbeatPulse, ctx.dropImpulse);

    // Afterglow uniform sync.
    const ag = this.afterglowMaterial.uniforms;
    ag.uTime.value = ctx.t;
    (ag.uSlotStart.value as Float32Array).set(this.slotStartTimes);
    (ag.uSlotIntensity.value as Float32Array).set(this.slotIntensities);
  }

  dispose(): void {
    this.wallMaterial.dispose();
    this.storm.geometry.dispose();
    this.afterglowMaterial.dispose();
    this.afterglowGeometry.dispose();
  }
}

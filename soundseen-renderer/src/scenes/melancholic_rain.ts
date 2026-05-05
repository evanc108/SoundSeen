// Melancholic rain — low-V, low-A biome.
//
// Cool desaturated indigo with vertical rain streaks falling through
// volumetric fog. A wet reflection plane below picks up a smeared
// version of the upper scene. Camera dollies very slowly downward —
// the felt direction is "sinking," not "drifting."
//
// Palette: ANALOGOUS cool (slate, indigo, lavender — ~210° to 270°).
// Schloss & Palmer (2011) — analogous reads as harmonious; for low-V
// biomes the harmony is consonance with grief, not relief.
//
// V&M (1994): low-V low-A predicts low-medium S, near-default B —
// per the equations, B ≈ 0.89. We deliberately crush B further
// in the renderer's atmosphere/background so the foreground V&M-bright
// rain still has somewhere to read; the scene's overall percept is
// dim, but the rain itself remains visible.
//
// Drops are SUPPRESSED for this biome. Per the original design plan,
// melancholic doesn't punch — even if the drop heuristic fires we
// scale the response down by 80%.

import * as THREE from "three";
import type { Scene } from "./scene.js";
import type { CompositionSpec, FrameContext } from "../types.js";
import { OnsetParticleEmitter } from "./onset_emitter.js";

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
  uniform float uDrop;
  uniform vec3  uColorTop;     // dim indigo sky
  uniform vec3  uColorBottom;  // wet reflection slate
  uniform vec3  uColorFog;
  uniform float uSaturation;
  uniform float uBrightness;
  uniform float uCentroid;
  uniform float uChromaStrength;
  uniform float uModeWarm;

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

  vec3 desaturate(vec3 col, float amt) {
    float l = dot(col, vec3(0.299, 0.587, 0.114));
    return mix(vec3(l), col, amt);
  }

  void main() {
    vec2 uv = vUv;

    // Vertical gradient: indigo sky on top, slate puddle below.
    // Horizon at y=0.40 — the reflection plane sits in the lower 40%.
    vec3 col;
    if (uv.y > 0.40) {
      float t = (uv.y - 0.40) / 0.60;
      col = mix(uColorTop * 0.95, uColorTop, t);
      // Slow horizontal fog drift in the upper half.
      float fog = noise(vec2(uv.x * 3.0 + uTime * 0.04, uv.y * 2.0)) * 0.20;
      col = mix(col, uColorFog, fog);
    } else {
      // Reflection: vertically mirror the upper sky's brightness, smeared.
      float mirrorY = 0.80 - uv.y; // upper-half coordinate
      vec2 dripUV = vec2(uv.x + sin(uTime * 0.4 + uv.y * 18.0) * 0.01,
                         mirrorY);
      float mirrorN = noise(vec2(dripUV.x * 3.0, dripUV.y * 2.0));
      col = mix(uColorBottom, uColorTop * 0.4, mirrorN * 0.7);
      // Beat ripple in the puddle — gentle, not punchy.
      float ringR = uBeat * 0.40;
      float ringW = 0.05;
      vec2 c = vec2(0.5, 0.20);
      float r = length(uv - c);
      float ring = smoothstep(ringR + ringW, ringR, r)
                 - smoothstep(ringR, max(ringR - ringW, 0.0), r);
      col += vec3(ring * uBeat * 0.18);
    }

    // Drop is *softened* for this biome — 20% strength.
    col += vec3(uDrop * 0.08);

    // Brighter timbre nudges the indigo toward lavender — keeps the
    // scene navigable on bright melancholy (acoustic guitar) without
    // breaking the dim atmosphere on dark melancholy (low strings).
    col += vec3(uCentroid * 0.06, uCentroid * 0.05, uCentroid * 0.10);

    float chromaSat = mix(0.85, 1.05, uChromaStrength);
    col = desaturate(col, uSaturation * chromaSat);

    // Mode bias is slightly stronger here since melancholic ↔ minor is
    // the most direct empirical link (Hevner 1937, Palmer 2013).
    col.r *= 1.0 + uModeWarm * 0.06;
    col.b *= 1.0 - uModeWarm * 0.06;

    col *= uBrightness;
    gl_FragColor = vec4(col, 1.0);
  }
`;

export class MelancholicRainScene implements Scene {
  readonly object3D: THREE.Scene;
  readonly camera: THREE.PerspectiveCamera;

  private bgMaterial: THREE.ShaderMaterial;
  private rainPositions: Float32Array;
  private rainSpeeds: Float32Array;
  private rainParticles: THREE.Points;
  private rainMaterial: THREE.PointsMaterial;
  private onsetEmitter: OnsetParticleEmitter;
  private static readonly RAIN_COUNT = 800;

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
        uDrop: { value: 0 },
        // Analogous cool anchors (~230°, ~210°, ~250°).
        uColorTop:    { value: new THREE.Color("#1a1f3a") }, // indigo sky
        uColorBottom: { value: new THREE.Color("#2a2e44") }, // slate puddle
        uColorFog:    { value: new THREE.Color("#354068") }, // lavender fog
        uSaturation: { value: 1.0 },
        uBrightness: { value: 1.0 },
        uCentroid: { value: 0.4 },
        uChromaStrength: { value: 0.0 },
        uModeWarm: { value: 0.0 },
      },
      depthTest: false,
      depthWrite: false,
    });
    const bg = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), this.bgMaterial);
    bg.frustumCulled = false;
    bg.renderOrder = -10;
    this.object3D.add(bg);

    // Rain — vertical streaks drifting down. Each particle has its own
    // fall speed so the rain doesn't read as a marching grid.
    const N = MelancholicRainScene.RAIN_COUNT;
    this.rainPositions = new Float32Array(N * 3);
    this.rainSpeeds = new Float32Array(N);
    for (let i = 0; i < N; i++) {
      this.rainPositions[i * 3 + 0] = (Math.random() - 0.5) * 9;
      this.rainPositions[i * 3 + 1] = Math.random() * 5 - 1;  // start anywhere vertically
      this.rainPositions[i * 3 + 2] = -Math.random() * 3.5;
      this.rainSpeeds[i] = 1.8 + Math.random() * 1.2;
    }
    const geo = new THREE.BufferGeometry();
    geo.setAttribute("position", new THREE.BufferAttribute(this.rainPositions, 3));

    this.rainMaterial = new THREE.PointsMaterial({
      // Rain itself sits brighter than the background atmosphere so
      // V&M's predicted brightness still reads despite the dim sky.
      color: new THREE.Color("#a4b0d0"),
      size: 0.018,
      sizeAttenuation: true,
      transparent: true,
      opacity: 0.55,
      blending: THREE.NormalBlending,
      depthWrite: false,
    });
    this.rainParticles = new THREE.Points(geo, this.rainMaterial);
    this.object3D.add(this.rainParticles);

    // Per-onset particles — small lavender, restrained pool. Even
    // melancholy songs have onsets (piano, strings); they should land
    // softly rather than not at all.
    this.onsetEmitter = new OnsetParticleEmitter({
      baseColor: new THREE.Color("#b4b8d8"),
      maxSize: 14,
      poolSize: 160,
    });
    this.object3D.add(this.onsetEmitter.object3D);
  }

  render(spec: CompositionSpec, ctx: FrameContext): void {
    const u = this.bgMaterial.uniforms;
    u.uTime.value = ctx.t;
    u.uBeat.value = ctx.beatPulse * 0.65;     // softened — biome doesn't punch
    u.uDrop.value = ctx.dropImpulse * 0.20;   // strongly softened drops

    const sectionGainSat = ctx.section?.saturation ?? 1.0;
    const sectionGainBri = ctx.section?.brightness ?? 1.0;
    u.uSaturation.value = ctx.vmSaturation * (sectionGainSat / Math.max(0.5, ctx.vmSaturation));
    u.uBrightness.value = ctx.vmBrightness * (sectionGainBri / Math.max(0.5, ctx.vmBrightness));

    u.uCentroid.value = ctx.audio.centroid;
    u.uChromaStrength.value = ctx.audio.chromaStrength;
    const modeStrength = ctx.section?.mode_strength ?? 0;
    u.uModeWarm.value = ctx.section?.mode === "minor" ? -modeStrength : modeStrength;

    // Step rain downward; recycle to the top when it leaves the frame.
    const pos = this.rainParticles.geometry.getAttribute("position") as THREE.BufferAttribute;
    const dt = 1 / 60;
    for (let i = 0; i < MelancholicRainScene.RAIN_COUNT; i++) {
      const ix = i * 3;
      this.rainPositions[ix + 1] -= this.rainSpeeds[i]! * dt;
      if (this.rainPositions[ix + 1]! < -2.5) {
        this.rainPositions[ix + 1] = 3.0 + Math.random() * 0.5;
        this.rainPositions[ix + 0] = (Math.random() - 0.5) * 9;
      }
    }
    pos.needsUpdate = true;

    // Slow camera dolly downward so the felt direction is "sinking"
    // — but tied to section progress so it's bounded per section.
    const sp = ctx.sectionProgress;
    this.camera.position.y = -sp * 0.4;
    this.camera.lookAt(0, this.camera.position.y, 0);
    this.camera.updateProjectionMatrix();

    this.onsetEmitter.update(spec, ctx);
  }

  dispose(): void {
    this.bgMaterial.dispose();
    this.rainMaterial.dispose();
    this.rainParticles.geometry.dispose();
    this.onsetEmitter.dispose();
  }
}

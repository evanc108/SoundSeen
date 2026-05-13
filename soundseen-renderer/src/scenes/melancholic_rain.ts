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
import { MelancholicWaterScene } from "./melancholic_water.js";
import { Skyline } from "./effects/skyline.js";
import { GodRays } from "./effects/godrays.js";
import { EventLayer } from "./effects/event_layer.js";
import { TextureOverlay } from "./effects/texture_overlay.js";
import { hash1, hash2 } from "./lib/deterministic_hash.js";
import { cinematicCameraDeltas } from "./lib/cinematic_camera.js";

const BG_VERTEX = /* glsl */ `
  varying vec2 vUv;
  void main() {
    vUv = uv;
    gl_Position = vec4(position, 1.0);
  }
`;

// Rain ribbons — instanced billboard quads with vertical-axis-locked
// rotation. Replaces the prior THREE.Points so each drop reads as an
// actual stretched streak rather than a 2D dot. Aspect ratio modulated
// by rolloff (1:3 → 1:7) so high-frequency-heavy passages produce long
// thin streaks; bass-heavy passages get rounder drops.
const RIBBON_VERTEX = /* glsl */ `
  attribute vec3 aInstancePos;
  attribute float aOpacity;

  uniform float uRibbonW;
  uniform float uRibbonH;

  varying vec2 vUv;
  varying float vOpacity;

  void main() {
    vec3 worldUp = vec3(0.0, 1.0, 0.0);
    vec3 toCam = cameraPosition - aInstancePos;
    toCam.y = 0.0;                       // lock rotation around world Y
    vec3 camFwd = normalize(toCam);
    vec3 camRight = normalize(cross(worldUp, camFwd));

    vec3 offset = position.x * uRibbonW * camRight
                + position.y * uRibbonH * worldUp;
    vec4 worldPos = vec4(aInstancePos + offset, 1.0);

    gl_Position = projectionMatrix * viewMatrix * worldPos;
    vUv = uv;
    vOpacity = aOpacity;
  }
`;

const RIBBON_FRAGMENT = /* glsl */ `
  precision highp float;
  uniform float uBeatPulse;
  varying vec2 vUv;
  varying float vOpacity;

  void main() {
    // Bright leading edge at the top of the ribbon, soft tail fading
    // downward. The leading-edge highlight reads as the wet front of
    // a falling drop catching ambient light. Beat pulse momentarily
    // brightens the lead so rain visibly "thumps" on each beat.
    float lead = smoothstep(0.82, 1.0, vUv.y);
    float tail = pow(vUv.y, 1.4);
    float a = tail * 0.45 + lead * (0.95 + uBeatPulse * 0.6);

    // Horizontal taper softens the rectangle into an ellipse-ish blade
    // so ribbons don't read as flat strips.
    float hT = 1.0 - pow(abs(vUv.x - 0.5) * 2.0, 2.5);
    a *= max(0.0, hT);

    vec3 base = vec3(0.62, 0.68, 0.92);
    vec3 hot  = vec3(1.05 + uBeatPulse * 0.4, 1.05, 1.20);
    vec3 col = mix(base, hot, lead);

    gl_FragColor = vec4(col, a * vOpacity);
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
  uniform float uHarmonicRatio;
  uniform float uChromaStrength;
  uniform float uModeWarm;
  uniform float uHueDistance;
  uniform float uPhrasePulse;

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
    // Horizon was a hard step at y=0.40 — visible seam. Now a smoothstep
    // band 0.32→0.48 mixes between the two computed branches. The W3
    // wave plane (Milestone D) will replace the puddle region wholesale.
    vec3 skyCol;
    {
      float t = max(0.0, (uv.y - 0.40) / 0.60);
      skyCol = mix(uColorTop * 0.95, uColorTop, t);
      // Bouba/Kiki on fog: high harmonic_ratio (sustained, tonal) →
      // smoother, slower fog drift; low → more granular fog.
      float fogFreq = mix(4.0, 2.4, uHarmonicRatio);
      float fog = noise(vec2(uv.x * fogFreq + uTime * 0.04, uv.y * 2.0)) * 0.20;
      skyCol = mix(skyCol, uColorFog, fog);
    }

    vec3 puddleCol;
    {
      // Reflection: vertically mirror the upper sky's brightness, smeared.
      float mirrorY = 0.80 - uv.y; // upper-half coordinate
      vec2 dripUV = vec2(uv.x + sin(uTime * 0.4 + uv.y * 18.0) * 0.01,
                         mirrorY);
      float mirrorN = noise(vec2(dripUV.x * 3.0, dripUV.y * 2.0));
      puddleCol = mix(uColorBottom, uColorTop * 0.4, mirrorN * 0.7);
      // Beat ripple in the puddle — gentle, not punchy.
      float ringR = uBeat * 0.40;
      float ringW = 0.05;
      vec2 c = vec2(0.5, 0.20);
      float r = length(uv - c);
      float ring = smoothstep(ringR + ringW, ringR, r)
                 - smoothstep(ringR, max(ringR - ringW, 0.0), r);
      puddleCol += vec3(ring * uBeat * 0.18);
    }

    float horizon = smoothstep(0.32, 0.48, uv.y);
    vec3 col = mix(puddleCol, skyCol, horizon);

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

    // hue_distance: rare for melancholic to register high tension,
    // but if it does (e.g., dissonant minor), shift the indigo toward
    // a faint warm bleed — reads as suppressed agitation.
    if (uHueDistance > 0.35) {
      float warmth = (uHueDistance - 0.35) * 0.4;
      col.r += warmth * 0.04;
      col.g += warmth * 0.02;
    }

    // Phrase pulse: a single faint horizontal sweep — the visual
    // analogue of "a wave going through the puddle." Krumhansl-tier
    // mark, restrained for this biome.
    col += vec3(uPhrasePulse * 0.05) * smoothstep(0.6, 0.0, abs(uv.y - 0.40));

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
  private rainOpacities: Float32Array;
  private rainGeometry: THREE.InstancedBufferGeometry;
  private rainMesh: THREE.Mesh;
  private rainMaterial: THREE.ShaderMaterial;
  private onsetEmitter: OnsetParticleEmitter;
  private water: MelancholicWaterScene;
  private skyline: Skyline;
  private godrays: GodRays;
  private events: EventLayer;
  private texture: TextureOverlay;
  // Pool capacity. Live count is computed per-frame as
  // 400 + round(buildIntensity * 1200) and applied via setDrawRange so
  // climaxes show ~4× rain density without paying for it during calm
  // passages.
  private static readonly RAIN_POOL = 1600;

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
        uHarmonicRatio: { value: 0.6 },
        uChromaStrength: { value: 0.0 },
        uModeWarm: { value: 0.0 },
        uHueDistance: { value: 0.3 },
        uPhrasePulse: { value: 0.0 },
      },
      depthTest: false,
      depthWrite: false,
    });
    const bg = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), this.bgMaterial);
    bg.frustumCulled = false;
    bg.renderOrder = -10;
    this.object3D.add(bg);

    // Rain — InstancedBufferGeometry of stretched billboard quads
    // (vertical-axis-locked). Each instance has its own world position
    // + fall speed + opacity. Live count gated per-frame via
    // geometry.instanceCount so calm passages cost ~400 instances and
    // climaxes cost ~1600. Per-instance attributes update each frame.
    const N = MelancholicRainScene.RAIN_POOL;
    this.rainPositions = new Float32Array(N * 3);
    this.rainSpeeds = new Float32Array(N);
    this.rainOpacities = new Float32Array(N);
    for (let i = 0; i < N; i++) {
      this.rainPositions[i * 3 + 0] = (hash1(i + 1) - 0.5) * 9;
      this.rainPositions[i * 3 + 1] = hash2(i, 1) * 5 - 1;  // start anywhere vertically
      this.rainPositions[i * 3 + 2] = -hash2(i, 2) * 3.5;
      this.rainSpeeds[i] = 1.8 + hash2(i, 3) * 1.2;
      this.rainOpacities[i] = 0.6 + hash2(i, 4) * 0.3;
    }

    // Base quad — 4 verts, 2 triangles, position.xy ∈ [-0.5, 0.5].
    this.rainGeometry = new THREE.InstancedBufferGeometry();
    const quadPos = new Float32Array([
      -0.5, -0.5, 0,
       0.5, -0.5, 0,
       0.5,  0.5, 0,
      -0.5,  0.5, 0,
    ]);
    const quadUv = new Float32Array([0, 0,  1, 0,  1, 1,  0, 1]);
    const quadIdx = new Uint16Array([0, 1, 2, 0, 2, 3]);
    this.rainGeometry.setAttribute("position", new THREE.BufferAttribute(quadPos, 3));
    this.rainGeometry.setAttribute("uv", new THREE.BufferAttribute(quadUv, 2));
    this.rainGeometry.setIndex(new THREE.BufferAttribute(quadIdx, 1));
    this.rainGeometry.setAttribute(
      "aInstancePos",
      new THREE.InstancedBufferAttribute(this.rainPositions, 3),
    );
    this.rainGeometry.setAttribute(
      "aOpacity",
      new THREE.InstancedBufferAttribute(this.rainOpacities, 1),
    );
    this.rainGeometry.instanceCount = 400; // starting count; render() updates per frame

    this.rainMaterial = new THREE.ShaderMaterial({
      vertexShader: RIBBON_VERTEX,
      fragmentShader: RIBBON_FRAGMENT,
      uniforms: {
        uRibbonW: { value: 0.020 },
        uRibbonH: { value: 0.080 },
        uBeatPulse: { value: 0 },
      },
      transparent: true,
      blending: THREE.NormalBlending,
      depthWrite: false,
    });
    this.rainMesh = new THREE.Mesh(this.rainGeometry, this.rainMaterial);
    this.rainMesh.frustumCulled = false;
    this.object3D.add(this.rainMesh);

    // Per-onset particles — small lavender, restrained pool. Even
    // melancholy songs have onsets (piano, strings); they should land
    // softly rather than not at all.
    this.onsetEmitter = new OnsetParticleEmitter({
      baseColor: new THREE.Color("#b4b8d8"),
      maxSize: 14,
      poolSize: 160,
    });
    this.object3D.add(this.onsetEmitter.object3D);

    // Wave-displaced puddle plane — the keystone hero geometry. Beat
    // rings, onset splashes, ambient flow + directional light. Sits at
    // y=-1.2, z=-1 and occludes the bg shader's puddle gradient in the
    // lower frame.
    this.water = new MelancholicWaterScene();
    this.object3D.add(this.water.object3D);

    // Distant skyline parallax — two billboard layers in the upper
    // frame with procedural silhouette + centroid drift + chroma-driven
    // window glow + drop lightning.
    this.skyline = new Skyline({
      buildingColor: new THREE.Color("#1a1d2c"),
      windowColor: new THREE.Color("#f5c878"),
      flickerColor: new THREE.Color("#fff0d8"),
      hazeTint: new THREE.Color("#000008"),
      shape: "urban",
    });
    this.object3D.add(this.skyline.object3D);

    // Volumetric god-ray shafts — silver-lavender tinting toward warm
    // gold at high chroma_strength. Sun pinned just outside the
    // upper-right corner so rays slant down-left through the rain.
    this.godrays = new GodRays({
      shaftColor: new THREE.Color("#c8cce6"),
      warmTint: new THREE.Color("#f0deb4"),
      sunPos: new THREE.Vector2(0.72, 1.10),
    });
    this.object3D.add(this.godrays.object3D);

    // Event layer — gentler magnitudes for Melancholic (drops are
    // already scaled 0.20 inside the scene). Shockwave color matches
    // the rain ribbon palette.
    this.events = new EventLayer({
      shockColor: new THREE.Color("#9aabe0"),
      strobeColor: new THREE.Color("#d0d4f0"),
      burstColor: new THREE.Color("#a8b8e8"),
      shockSpread: 0.75,
    });
    this.object3D.add(this.events.object3D);

    // Texture overlay — surface treatment that responds to the music's
    // *character* (angularity → halftone, zcr → scanlines, etc.).
    // Lavender tint on the harmonic-ratio wash for melancholic.
    this.texture = new TextureOverlay({
      tintColor: new THREE.Color("#b0b8e0"),
    });
    this.object3D.add(this.texture.object3D);
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
    u.uHarmonicRatio.value = ctx.audio.harmonicRatio;
    u.uChromaStrength.value = ctx.audio.chromaStrength;
    const modeStrength = ctx.section?.mode_strength ?? 0;
    u.uModeWarm.value = ctx.section?.mode === "minor" ? -modeStrength : modeStrength;
    u.uHueDistance.value = ctx.section?.hue_distance ?? 0.3;
    u.uPhrasePulse.value = ctx.phrasePulse;

    // Step rain downward; recycle to the top when it leaves the frame.
    // Rolloff modulates the spawn ceiling — bright-mix passages spawn rain
    // higher in the frame (longer falls, visible upper-air weight); dark
    // mixes spawn lower (shorter compressed falls). Rain becomes a
    // perceivable readout of high-frequency content.
    //
    // Density scales with buildIntensity: 400 active particles in calm
    // passages, 1600 (pool max) at climax — ~4× during build-ups. The
    // pool is preallocated; we just gate the draw call.
    //
    // vScale (audio-reactive velocity field) multiplies fall speed by
    // spectral_flux + onset_strength_env. Peaks ~2.4× — rain visibly
    // rushes during loud, transient-dense passages.
    const rolloff = ctx.audio.rolloff;
    const spawnCeil = 1.5 + rolloff * 1.5;
    const liveCount = Math.min(
      MelancholicRainScene.RAIN_POOL,
      400 + Math.round(ctx.buildIntensity * 1200),
    );
    const vScale =
      1.0 + ctx.audio.spectralFlux * 0.6 + ctx.audio.onsetStrengthEnv * 0.8;
    // Aspect ratio 1:3 (low rolloff, rounder drops) → 1:7 (high rolloff,
    // long streaks). Width stays narrow; height grows.
    const aspect = 3.0 + rolloff * 4.0;
    this.rainMaterial.uniforms.uRibbonW.value = 0.020;
    this.rainMaterial.uniforms.uRibbonH.value = 0.020 * aspect;
    this.rainMaterial.uniforms.uBeatPulse.value = ctx.beatPulse;
    const posAttr = this.rainGeometry.getAttribute("aInstancePos") as THREE.InstancedBufferAttribute;
    const dt = 1 / 60;
    for (let i = 0; i < liveCount; i++) {
      const ix = i * 3;
      this.rainPositions[ix + 1] -= this.rainSpeeds[i]! * vScale * dt;
      if (this.rainPositions[ix + 1]! < -2.5) {
        this.rainPositions[ix + 1] = spawnCeil + hash2(ctx.t, i) * 0.5;
        this.rainPositions[ix + 0] = (hash2(ctx.t, i + 1000) - 0.5) * 9;
      }
    }
    this.rainGeometry.instanceCount = liveCount;
    posAttr.needsUpdate = true;

    // Cinematic camera: section dolly down (biome-specific "sinking")
    // plus the shared cinematic deltas (bass sway, build push-in,
    // phrase swoop, drop shake, tension roll).
    const sp = ctx.sectionProgress;
    const cam = cinematicCameraDeltas(ctx);
    this.camera.position.set(0, -sp * 0.4, 4).add(cam.posDelta);
    this.camera.lookAt(0, this.camera.position.y * 0.5, 0);
    this.camera.rotation.z = cam.rollZ;
    this.camera.updateProjectionMatrix();

    this.onsetEmitter.update(spec, ctx);
    // Per-band continuous spawning — sparkles per mel band when energy
    // exceeds threshold. Emitter internally throttles to 0.10s/band.
    const bands = ctx.audio.melBands;
    for (let k = 0; k < 8; k++) {
      this.onsetEmitter.spawnBandPulse(k, bands[k] ?? 0, ctx.t, ctx);
    }

    // Drive the wave plane forward — pushes new beat rings + onset
    // splashes into the shader's ring buffers, advances uTime.
    this.water.update(spec, ctx);
    this.skyline.update(spec, ctx);
    this.godrays.update(spec, ctx);
    this.events.update(spec, ctx);
    this.texture.update(spec, ctx);
  }

  dispose(): void {
    this.bgMaterial.dispose();
    this.rainMaterial.dispose();
    this.rainGeometry.dispose();
    this.onsetEmitter.dispose();
    this.water.dispose();
    this.skyline.dispose();
    this.godrays.dispose();
    this.events.dispose();
    this.texture.dispose();
  }
}

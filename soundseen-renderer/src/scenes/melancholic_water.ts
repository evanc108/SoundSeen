// Wave-displaced puddle plane — the keystone "wow" addition for the
// Melancholic Rain biome. Replaces the old 2D puddle branch in the
// background shader with a real 3D mesh: 96×96 PlaneGeometry oriented
// horizontally at y=-1.2, ShaderMaterial that combines three
// displacement sources, analytic sky reflection, and one directional
// light. Wave crests catch the light → reads as actual water.
//
// Displacement sources (all summed, clamped to ±0.5):
//   1. Beat rings    — 4-slot ring buffer, propagate at 1.8 u/s,
//                      amplitude `0.22 · exp(-age/1.8)`, lifespan ~3s.
//   2. Onset splashes — 8-slot ring buffer, tighter Gaussian bumps,
//                       intensity-weighted, 0.6s decay.
//   3. Ambient flow   — perpetual sin(x)·sin(z) cross-pattern, modulated
//                       by spectral_flux so chaotic passages chop more.
//
// Normals are computed via finite difference at the vertex shader (3×
// displacement evaluations per vertex) — costs ~0.3ms total on ANGLE,
// well under budget — so the Lambert + specular highlight is accurate.

import * as THREE from "three";
import type { CompositionSpec, FrameContext } from "../types.js";
import { hash1, hash2 } from "./lib/deterministic_hash.js";

const MAX_BEAT_RINGS = 4;
const MAX_SPLASHES = 8;

const WATER_VERT = /* glsl */ `
  uniform float uTime;
  uniform float uFlux;
  uniform float uHarmonicRatio;
  uniform vec3  uBeatRings[${MAX_BEAT_RINGS}];   // (x, z, startTime)
  uniform vec4  uSplashes[${MAX_SPLASHES}];      // (x, z, startTime, intensity)

  varying vec3 vWorldPos;
  varying vec3 vWorldNormal;
  varying float vDisplacement;
  varying float vCrestMask;

  // Total displacement at a plane-local (x, z) coordinate. Factored so
  // we can sample it at the vertex plus two neighbors for normal
  // estimation via finite difference.
  float sampleDisp(float x, float z) {
    float disp = 0.0;

    // Beat rings — propagating expanding ring with a sinusoidal wave
    // riding the leading edge. Lifespan 3s; amplitude pushed for
    // outstanding-tier drama.
    for (int i = 0; i < ${MAX_BEAT_RINGS}; i++) {
      vec3 ring = uBeatRings[i];
      float age = uTime - ring.z;
      if (age < 0.0 || age > 3.0) continue;
      float r = length(vec2(x - ring.x, z - ring.y));
      float ringR = age * 2.0;
      float amp = 0.32 * exp(-age / 1.8);
      disp += amp
              * smoothstep(0.22, 0.0, abs(r - ringR))
              * sin((r - ringR) * 25.0);
    }

    // Onset splashes — tight Gaussian bump, fast decay.
    for (int i = 0; i < ${MAX_SPLASHES}; i++) {
      vec4 s = uSplashes[i];
      float age = uTime - s.z;
      if (age < 0.0 || age > 0.8) continue;
      float r = length(vec2(x - s.x, z - s.y));
      float amp = 0.22 * s.w * exp(-age / 0.2);
      disp += amp * exp(-r * r * 15.0);
    }

    // Ambient flow — perpetual gentle cross-sin motion, scaled by
    // spectral_flux so transient-dense passages chop more. Tonal
    // (high harmonic_ratio) passages flow more smoothly.
    float flowAmt = mix(0.025, 0.055, uHarmonicRatio);
    disp += sin(x * 2.0 + uTime * 0.3) * sin(z * 1.7 + uTime * 0.2)
            * flowAmt * (0.5 + uFlux * 0.5);

    // Mandatory: a few-beat collision plus drop can stack ~1u — clamp.
    return clamp(disp, -0.5, 0.5);
  }

  void main() {
    // Geometry was created with rotateX(-pi/2), so the vertex's local
    // position is in plane-local (x, 0, z); we displace along +y.
    float px = position.x;
    float pz = position.z;

    float dCenter = sampleDisp(px,        pz);
    float dRight  = sampleDisp(px + 0.08, pz);
    float dFwd    = sampleDisp(px,        pz + 0.08);

    vec3 p = vec3(px, dCenter, pz);

    // Estimate normal from neighbor displacements (finite difference).
    // Tangents along x and z; cross product gives surface normal.
    vec3 tx = vec3(0.08, dRight - dCenter, 0.0);
    vec3 tz = vec3(0.0,  dFwd   - dCenter, 0.08);
    vec3 nLocal = normalize(cross(tz, tx));

    vec4 worldPos4 = modelMatrix * vec4(p, 1.0);
    vWorldPos = worldPos4.xyz;
    // For a plane sitting in world XZ, world normal ≈ local normal
    // (model has only a translation, no rotation in the host scene).
    vWorldNormal = normalize((modelMatrix * vec4(nLocal, 0.0)).xyz);
    vDisplacement = dCenter;

    // Crest mask — bright on upward-pointing wave tops, used in the
    // fragment shader to boost specular contribution.
    vCrestMask = smoothstep(0.04, 0.16, dCenter);

    gl_Position = projectionMatrix * viewMatrix * worldPos4;
  }
`;

const WATER_FRAG = /* glsl */ `
  precision highp float;

  uniform vec3 uSkyColorTop;
  uniform vec3 uSkyColorBottom;
  uniform vec3 uSkyColorFog;
  uniform vec3 uLightDir;
  uniform vec3 uLightColor;
  uniform float uTime;
  uniform float uCentroid;
  uniform float uChromaStrength;
  uniform float uTension;

  varying vec3 vWorldPos;
  varying vec3 vWorldNormal;
  varying float vDisplacement;
  varying float vCrestMask;

  // Cheap animated caustic-style pattern. Three rotating sin waves
  // multiplied + powered yield the bright wandering "spots" that
  // characterize underwater light through ripples — but here we apply
  // them on top of the reflection so the surface reads as alive.
  float caustics(vec2 p) {
    vec2 q1 = vec2(p.x + uTime * 0.18, p.y + uTime * 0.12);
    vec2 q2 = vec2(p.x * 1.4 - uTime * 0.10, p.y * 1.3 + uTime * 0.16);
    float c = sin(q1.x * 4.0) * sin(q1.y * 3.5)
            + sin(q2.x * 5.3) * sin(q2.y * 4.7) * 0.7;
    return pow(max(0.0, c * 0.5 + 0.5), 4.0);
  }

  void main() {
    vec3 N = normalize(vWorldNormal);

    // Analytic sky reflection. A water surface mirrors what's above —
    // parallax the sky lookup by the normal so tilted facets sample a
    // different sky band. Matches the bg shader's vertical gradient.
    float skyT = clamp(N.y * 1.2 + 0.0, 0.0, 1.0);
    vec3 skyCol = mix(uSkyColorBottom * 0.8, uSkyColorTop, skyT);
    float fogAmt = 0.3 * smoothstep(-0.4, 0.6, N.x);
    skyCol = mix(skyCol, uSkyColorFog, fogAmt);

    // Lambert + specular from a single directional light. Tighter
    // exponent (48) crisps the highlight; intensity ramps with crest
    // mask so wave tops genuinely glitter.
    vec3 L = normalize(uLightDir);
    float nDotL = max(0.0, dot(N, L));
    vec3 V = normalize(cameraPosition - vWorldPos);
    vec3 R = reflect(-L, N);
    float spec = pow(max(0.0, dot(V, R)), 48.0);

    // Fresnel rim — grazing-angle view brightens the reflection. For a
    // mostly-horizontal plane viewed from above-front this lifts the
    // whole surface toward the sky color, reading as "wet."
    float fres = pow(1.0 - max(0.0, dot(V, N)), 5.0);

    vec3 col = skyCol * (0.42 + 0.58 * nDotL);
    col = mix(col, skyCol * 1.25, fres * 0.55);
    col += uLightColor * spec * (1.1 + 1.6 * vCrestMask);

    // Foam at high crests — bright peaks read clearly even when the
    // sky reflection is dim. Threshold tuned against the ±0.5 disp clamp.
    float foam = smoothstep(0.18, 0.34, vDisplacement);
    col = mix(col, vec3(0.85, 0.88, 0.95), foam * 0.45);

    // Caustic shimmer — wandering bright spots over the whole surface.
    // Tinted with the light color so it reads as filtered sunlight
    // through the (implied) overcast above. Modulated by chroma so it
    // brightens when the music is tonal.
    float caust = caustics(vWorldPos.xz * 0.6);
    col += uLightColor * caust * (0.18 + uChromaStrength * 0.22);

    // Slight warmth lift on chord-strong frames, slight darken with
    // tension. Centroid (brightness) nudges everything brighter when
    // the mix opens up.
    col *= 1.0 - uTension * 0.18;
    col += vec3(uChromaStrength * 0.05, uChromaStrength * 0.04,
                uChromaStrength * 0.07);
    col *= 0.85 + uCentroid * 0.30;

    gl_FragColor = vec4(col, 1.0);
  }
`;

export class MelancholicWaterScene {
  readonly object3D: THREE.Group;
  readonly mesh: THREE.Mesh;
  private material: THREE.ShaderMaterial;
  private beatRings: Float32Array;   // (x, z, startTime) × MAX_BEAT_RINGS
  private splashes: Float32Array;    // (x, z, startTime, intensity) × MAX_SPLASHES
  private ringWriteIdx = 0;
  private splashWriteIdx = 0;
  private prevBeatT = -1;
  private prevOnsetT = -1;

  constructor() {
    this.object3D = new THREE.Group();

    const geo = new THREE.PlaneGeometry(8, 4, 96, 96);
    geo.rotateX(-Math.PI / 2);

    // Pre-fill with "expired" entries so the shader's age check culls
    // them on the first render.
    this.beatRings = new Float32Array(MAX_BEAT_RINGS * 3);
    this.splashes = new Float32Array(MAX_SPLASHES * 4);
    for (let i = 0; i < MAX_BEAT_RINGS; i++) {
      this.beatRings[i * 3 + 2] = -1000;
    }
    for (let i = 0; i < MAX_SPLASHES; i++) {
      this.splashes[i * 4 + 2] = -1000;
    }

    this.material = new THREE.ShaderMaterial({
      vertexShader: WATER_VERT,
      fragmentShader: WATER_FRAG,
      uniforms: {
        uTime: { value: 0 },
        uFlux: { value: 0 },
        uHarmonicRatio: { value: 0.6 },
        uCentroid: { value: 0.4 },
        uChromaStrength: { value: 0.0 },
        uTension: { value: 0.4 },
        uBeatRings: { value: this.beatRings },
        uSplashes: { value: this.splashes },
        // Match the bg shader's palette so the wave reads as the same
        // world. Slight bias warmer on top so the reflected sky has a
        // bit more pop than the bg fog.
        uSkyColorTop:    { value: new THREE.Color("#262d50") },
        uSkyColorBottom: { value: new THREE.Color("#1c2236") },
        uSkyColorFog:    { value: new THREE.Color("#3f4a78") },
        // Directional light from above-front-right.
        uLightDir:   { value: new THREE.Vector3(0.4, 1.0, 0.6).normalize() },
        uLightColor: { value: new THREE.Color("#d8d5ff") },
      },
      transparent: false,
      depthWrite: true,
    });

    this.mesh = new THREE.Mesh(geo, this.material);
    this.mesh.position.set(0, -1.2, -1);
    this.object3D.add(this.mesh);
  }

  update(spec: CompositionSpec, ctx: FrameContext): void {
    const u = this.material.uniforms;
    u.uTime.value = ctx.t;
    u.uFlux.value = ctx.audio.spectralFlux;
    u.uHarmonicRatio.value = ctx.audio.harmonicRatio;
    u.uCentroid.value = ctx.audio.centroid;
    u.uChromaStrength.value = ctx.audio.chromaStrength;
    u.uTension.value = ctx.section?.tension ?? 0.4;

    // Push new beat rings into the circular buffer. Rings are placed
    // at deterministic hash-jittered XZ origins so successive downbeats
    // don't stack at the same point.
    for (const beat of spec.beat_track) {
      if (beat.t <= this.prevBeatT) continue;
      if (beat.t > ctx.t) break;
      const idx = this.ringWriteIdx;
      this.ringWriteIdx = (this.ringWriteIdx + 1) % MAX_BEAT_RINGS;
      const x = (hash1(beat.t) - 0.5) * 4.5;     // within plane x range
      const z = (hash2(beat.t, 1) - 0.5) * 1.8;  // within plane z range
      this.beatRings[idx * 3 + 0] = x;
      this.beatRings[idx * 3 + 1] = z;
      this.beatRings[idx * 3 + 2] = beat.t;
    }
    this.prevBeatT = ctx.t;

    // Push new onset splashes — tighter scatter, intensity-weighted.
    for (const onset of spec.onset_track) {
      if (onset.t <= this.prevOnsetT) continue;
      if (onset.t > ctx.t) break;
      const idx = this.splashWriteIdx;
      this.splashWriteIdx = (this.splashWriteIdx + 1) % MAX_SPLASHES;
      const x = (hash1(onset.t + 0.5) - 0.5) * 4.5;
      const z = (hash2(onset.t + 0.5, 1) - 0.5) * 1.8;
      this.splashes[idx * 4 + 0] = x;
      this.splashes[idx * 4 + 1] = z;
      this.splashes[idx * 4 + 2] = onset.t;
      this.splashes[idx * 4 + 3] = onset.intensity;
    }
    this.prevOnsetT = ctx.t;
  }

  dispose(): void {
    this.material.dispose();
    this.mesh.geometry.dispose();
  }
}

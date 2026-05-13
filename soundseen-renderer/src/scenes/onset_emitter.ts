// OnsetParticleEmitter — per-onset particle pool with ADSR envelopes.
//
// Every musical onset (snare hit, piano note, sax stab, …) spawns ONE
// particle whose alpha+size envelope mirrors the onset's ADSR. A snare
// is short attack + short decay → small bright snap that vanishes. A
// piano hit is short attack + long decay → bright spark that lingers.
// A bowed string is long attack + sustain → soft bloom that swells.
//
// Each particle's spatial position is set at spawn from the onset's
// pitch class (Pratt 1930: high pitch → up the screen; Walker et al.
// 2010: high pitch → smaller). Sharp attack_slope → harder edge
// (kiki); soft slope → bouba blur. The shape vocabulary is dynamic
// per-onset, not per-section, so a percussive break inside a tonal
// chorus reads as visibly more angular.
//
// Implementation: a fixed-size particle pool with custom ShaderMaterial
// that takes per-particle attributes. New onsets find a free slot
// (oldest-completed wins) and write spawn parameters; the vertex
// shader advances each particle's age based on a uniform clock.

import * as THREE from "three";
import type { CompositionSpec, FrameContext, OnsetDirective } from "../types.js";
import { hash1, hash2 } from "./lib/deterministic_hash.js";

// Per-particle attributes packed into typed arrays:
//   position:   xyz spawn position
//   spawn:      time of spawn, lifespan, attack_slope, _pad   (vec4)
//   adsr:       attack_time_ms, decay_time_ms, sustain_level, intensity   (vec4)
//   color:      rgb tint
//   baseSize:   spawn-time radius (scaled by inverse pitch height)

const VERT = /* glsl */ `
  attribute vec4 aSpawn;     // x=spawnT, y=lifespan, z=attackSlope, w=pad
  attribute vec4 aADSR;      // x=attMs, y=decMs, z=susLvl, w=intensity
  attribute vec3 aColor;
  attribute float aBaseSize;

  uniform float uTime;

  varying float vAge01;
  varying float vEnvelope;
  varying float vAttackSlope;
  varying vec3 vColor;
  varying float vIntensity;

  void main() {
    float age = uTime - aSpawn.x;
    float lifespan = aSpawn.y;
    vAge01 = clamp(age / max(lifespan, 0.001), 0.0, 1.0);
    vAttackSlope = aSpawn.z;
    vColor = aColor;
    vIntensity = aADSR.w;

    // Reconstruct a normalized ADSR envelope from the per-particle
    // spec values. Lifespan = attack + decay + release (release is
    // ~150ms tail after sustain). Sustain holds for max(0, lifespan-attack-decay-release).
    float attS = aADSR.x * 0.001;        // s
    float decS = aADSR.y * 0.001;        // s
    float sus  = aADSR.z;                // 0..1
    float relS = 0.150;                  // fixed release tail
    float susS = max(0.0, lifespan - attS - decS - relS);

    float env;
    if (age < attS) {
      // Attack: 0 → 1. Power-shape by attackSlope so steep slopes
      // produce a snappier rise (kiki) and shallow ones a soft swell.
      float k = mix(2.5, 0.6, clamp(aSpawn.z, 0.0, 1.0));
      env = pow(age / max(attS, 0.001), k);
    } else if (age < attS + decS) {
      // Decay: 1 → sus.
      float u = (age - attS) / max(decS, 0.001);
      env = mix(1.0, sus, u);
    } else if (age < attS + decS + susS) {
      env = sus;
    } else {
      // Release: sus → 0.
      float u = (age - attS - decS - susS) / max(relS, 0.001);
      env = mix(sus, 0.0, clamp(u, 0.0, 1.0));
    }
    if (age < 0.0 || age > lifespan) env = 0.0;

    vEnvelope = env;

    // Size: spawn-time base × envelope × intensity, with a small
    // attack-slope kicker so kiki onsets briefly punch above their
    // sustain size. Capped to avoid GPU pixel-fill blowup.
    float kick = 1.0 + aSpawn.z * vEnvelope * 0.4;
    float size = aBaseSize * env * kick * (0.6 + 0.7 * aADSR.w);
    gl_PointSize = clamp(size, 0.0, 64.0);

    vec4 mvPosition = modelViewMatrix * vec4(position, 1.0);
    gl_Position = projectionMatrix * mvPosition;
  }
`;

const FRAG = /* glsl */ `
  precision highp float;
  varying float vAge01;
  varying float vEnvelope;
  varying float vAttackSlope;
  varying vec3 vColor;
  varying float vIntensity;

  void main() {
    if (vEnvelope <= 0.001) discard;

    // Distance from center of point sprite, 0 at center, ~0.7 at corner.
    vec2 d = gl_PointCoord - vec2(0.5);
    float r = length(d) * 2.0;
    if (r >= 1.0) discard;

    // Bouba/Kiki edge: shallow slope → soft gaussian falloff (bouba);
    // steep slope → hard linear falloff with a sharp ring (kiki).
    float softness = 1.0 - clamp(vAttackSlope, 0.0, 1.0);
    float soft  = exp(-r * r * 6.0);                      // gaussian
    float hard  = smoothstep(1.0, 0.85, r) * (1.0 - r);   // hard edge with bright core
    float alpha = mix(hard, soft, softness);

    // Slight inner glow boost, strongest right at attack peak.
    float glow = 1.0 + vEnvelope * 0.5;
    vec3 col = vColor * glow;

    gl_FragColor = vec4(col, alpha * vEnvelope * vIntensity * 0.95);
  }
`;

interface EmitterOptions {
  /// Pool capacity. ~256 is enough for most songs since onsets rarely
  /// fire faster than ~10/s and per-onset lifespans are <2s.
  poolSize?: number;
  /// Color tint applied to all particles spawned by this emitter.
  /// Scenes pass their biome accent so the emitter blends into the
  /// scene's palette.
  baseColor: THREE.Color;
  /// Maximum size (NDC-ish point-size) at full envelope — scenes scale
  /// the same emitter differently so percussive scenes (Intense) get
  /// smaller sharper particles than tonal scenes (Serene).
  maxSize?: number;
}

export class OnsetParticleEmitter {
  readonly object3D: THREE.Points;

  private material: THREE.ShaderMaterial;
  private positions: Float32Array;
  private spawn: Float32Array;
  private adsr: Float32Array;
  private colors: Float32Array;
  private baseSizes: Float32Array;
  private slotEndTimes: Float32Array;  // when each slot's lifespan ends
  private nextSpawn = 0;
  private prevT = -1;
  // Cadence gate for per-band continuous spawning. Each band tracks the
  // last t at which it spawned so the host can call spawnBandPulse every
  // render frame and the emitter throttles to ~10 Hz internally.
  private lastBandSpawnT: Float32Array = new Float32Array(8).fill(-1000);

  private readonly poolSize: number;
  private readonly baseColor: THREE.Color;
  private readonly maxSize: number;

  constructor(opts: EmitterOptions) {
    this.poolSize = opts.poolSize ?? 256;
    this.baseColor = opts.baseColor.clone();
    this.maxSize = opts.maxSize ?? 28;

    const N = this.poolSize;
    this.positions = new Float32Array(N * 3);
    this.spawn = new Float32Array(N * 4);
    this.adsr = new Float32Array(N * 4);
    this.colors = new Float32Array(N * 3);
    this.baseSizes = new Float32Array(N);
    this.slotEndTimes = new Float32Array(N);

    // All slots start expired so the first onsets fill from index 0.
    for (let i = 0; i < N; i++) {
      this.slotEndTimes[i] = -1;
      // Spawn time far in past so envelope is 0.
      this.spawn[i * 4 + 0] = -1000;
      this.spawn[i * 4 + 1] = 0.001;
      // Default color so freshly-allocated material doesn't draw garbage
      this.colors[i * 3 + 0] = this.baseColor.r;
      this.colors[i * 3 + 1] = this.baseColor.g;
      this.colors[i * 3 + 2] = this.baseColor.b;
    }

    const geo = new THREE.BufferGeometry();
    geo.setAttribute("position", new THREE.BufferAttribute(this.positions, 3));
    geo.setAttribute("aSpawn",   new THREE.BufferAttribute(this.spawn, 4));
    geo.setAttribute("aADSR",    new THREE.BufferAttribute(this.adsr, 4));
    geo.setAttribute("aColor",   new THREE.BufferAttribute(this.colors, 3));
    geo.setAttribute("aBaseSize",new THREE.BufferAttribute(this.baseSizes, 1));

    this.material = new THREE.ShaderMaterial({
      vertexShader: VERT,
      fragmentShader: FRAG,
      uniforms: { uTime: { value: 0 } },
      transparent: true,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    });
    this.object3D = new THREE.Points(geo, this.material);
    this.object3D.frustumCulled = false;
  }

  /// Drive the emitter forward. Spawns particles for any onsets in the
  /// (prev, current] window, advances the shader's clock uniform.
  /// Call this once per render() in the host scene.
  update(spec: CompositionSpec, ctx: FrameContext, accentTint?: THREE.Color): void {
    this.material.uniforms.uTime.value = ctx.t;

    const lo = this.prevT;
    const hi = ctx.t;
    this.prevT = ctx.t;
    if (lo < 0) return;  // first frame — skip retro-spawn

    // Bind the most recent onsets in (lo, hi]. Each onset spawns a
    // burst of N particles in a fan around the base position. N scales
    // with intensity + spectral_contrast so soft piano hits stay at the
    // floor (2) and peak snares cap at 7. Fan radius widens with
    // spectral_contrast — peaky spectra burst out further.
    const contrast = ctx.audio.spectralContrast;
    for (const onset of spec.onset_track) {
      if (onset.t <= lo) continue;
      if (onset.t > hi) break;
      const N = Math.max(
        2,
        Math.min(7, Math.round(2 + onset.intensity * 4 + contrast * 2)),
      );
      for (let b = 0; b < N; b++) {
        this.spawnFor(onset, ctx, accentTint, b, N, contrast);
      }
    }
  }

  private spawnFor(
    onset: OnsetDirective,
    ctx: FrameContext,
    accentTint: THREE.Color | undefined,
    b: number,
    N: number,
    contrast: number,
  ): void {
    // Pick a slot — round-robin. Most onsets fire fast enough that the
    // pool's natural rotation handles eviction gracefully.
    const slot = this.nextSpawn;
    this.nextSpawn = (this.nextSpawn + 1) % this.poolSize;

    // Lifespan: attack + decay + sustain-tail + release. Sustain held
    // briefly per onset so even sharp hits get a tiny readable plateau.
    const attS = onset.attack_time_ms * 0.001;
    const decS = onset.decay_time_ms  * 0.001;
    const susS = 0.05 + onset.sustain_level * 0.20;
    const relS = 0.150;
    const lifespan = attS + decS + susS + relS;

    this.slotEndTimes[slot] = onset.t + lifespan;

    // Vertical placement: band-weighted (v4 mel_bands) + pitch_class
    // fine-offset. Mel bands give every onset a y position — including
    // drum hits where pitch_class is -1 (atonal). sub_bass → bottom of
    // frame, ultra_high → top, with the 8 bands evenly distributed.
    // Pitch class (when present) provides ±0.3 fine adjustment for
    // tonal melody (Pratt 1930) on top of the band-derived altitude.
    const bands = ctx.audio.melBands;
    let bandY = 0;
    if (bands && bands.length === 8) {
      let totalE = 0;
      let weightedSum = 0;
      for (let k = 0; k < 8; k++) {
        const e = bands[k] ?? 0;
        totalE += e;
        // Bin k=0 (sub_bass) at y=-1.8, k=7 (ultra_high) at y=+1.8
        const bandPos = -1.8 + (k / 7) * 3.6;
        weightedSum += bandPos * e;
      }
      if (totalE > 1e-4) bandY = weightedSum / totalE;
    }
    const pitchFine =
      onset.pitch_class >= 0 ? ((onset.pitch_class / 11) * 2 - 1) * 0.3 : 0;
    // Pitch → inverse size (Walker 2010) — still applies even when band
    // drives the y position.
    const sizeFromPitch =
      onset.pitch_class >= 0 ? 1.4 - 0.7 * ((onset.pitch_class / 11)) : 1.0;

    // Base placement: deterministic per onset (same x,y across burst
    // members), then a fan offset per b separates burst particles into
    // a ring around the base point. Fan radius scales with
    // spectral_contrast — peaky spectra fan wider.
    const baseHash = hash1(onset.t);
    const baseX = (baseHash - 0.5) * 4.5;
    const pitchHeight =
      onset.pitch_class >= 0 ? (onset.pitch_class / 11) * 2 - 1 : 0;
    const baseY = bandY !== 0 ? bandY + pitchFine : pitchHeight * 1.6;

    const fanAngle = (b / Math.max(1, N)) * Math.PI * 2;
    const fanR = 0.15 + contrast * 0.25 + hash2(onset.t, b) * 0.10;
    const x = baseX + Math.cos(fanAngle) * fanR;
    const y = baseY + Math.sin(fanAngle) * fanR;
    const z = -0.5 - hash2(onset.t, b + 1) * 1.5;

    const ix3 = slot * 3;
    const ix4 = slot * 4;

    this.positions[ix3 + 0] = x;
    this.positions[ix3 + 1] = y;
    this.positions[ix3 + 2] = z;

    this.spawn[ix4 + 0] = onset.t;
    this.spawn[ix4 + 1] = lifespan;
    this.spawn[ix4 + 2] = onset.attack_slope;
    this.spawn[ix4 + 3] = 0;

    this.adsr[ix4 + 0] = onset.attack_time_ms;
    this.adsr[ix4 + 1] = onset.decay_time_ms;
    this.adsr[ix4 + 2] = onset.sustain_level;
    this.adsr[ix4 + 3] = onset.intensity;

    // Color: base palette tint, optionally pulled toward accent for
    // tonal passages. Itoh (2017): pitch-class → hue rainbow only
    // robust in synesthetes — so we tint subtly, not literally.
    const tint = accentTint ?? this.baseColor;
    const blend = onset.pitch_class >= 0 ? 0.35 : 0.0;
    this.colors[ix3 + 0] = this.baseColor.r * (1 - blend) + tint.r * blend;
    this.colors[ix3 + 1] = this.baseColor.g * (1 - blend) + tint.g * blend;
    this.colors[ix3 + 2] = this.baseColor.b * (1 - blend) + tint.b * blend;

    // Base size — Walker 2010 inverse-pitch scaling × scene maxSize ×
    // section angularity (sharper sections bias smaller).
    const sectionAng = ctx.section?.angularity ?? 0.5;
    const angScale = 1.0 - sectionAng * 0.25;
    this.baseSizes[slot] = this.maxSize * sizeFromPitch * angScale;

    // Mark all attribute buffers dirty.
    const geo = this.object3D.geometry;
    (geo.getAttribute("position") as THREE.BufferAttribute).needsUpdate = true;
    (geo.getAttribute("aSpawn")   as THREE.BufferAttribute).needsUpdate = true;
    (geo.getAttribute("aADSR")    as THREE.BufferAttribute).needsUpdate = true;
    (geo.getAttribute("aColor")   as THREE.BufferAttribute).needsUpdate = true;
    (geo.getAttribute("aBaseSize")as THREE.BufferAttribute).needsUpdate = true;
  }

  /// Per-band continuous spawning. Called every render frame from the
  /// host scene for each of the 8 mel bands. Internally throttled to a
  /// 0.10s cadence per band; only fires when the band energy exceeds
  /// 0.55. Spawned particle uses a pure-decay envelope (instant attack,
  /// short decay, fade) instead of full ADSR — these are sparkles, not
  /// articulated onsets.
  spawnBandPulse(
    bandIndex: number,
    energy: number,
    t: number,
    _ctx: FrameContext,
  ): void {
    if (bandIndex < 0 || bandIndex > 7) return;
    if (energy <= 0.55) return;
    if (t - this.lastBandSpawnT[bandIndex]! < 0.10) return;
    this.lastBandSpawnT[bandIndex] = t;

    const slot = this.nextSpawn;
    this.nextSpawn = (this.nextSpawn + 1) % this.poolSize;

    const k = bandIndex;
    const y = -1.8 + (k / 7) * 3.6;
    const xScatter = (hash2(t, k) - 0.5) * 5.0;
    const lifespan = 0.4 + hash2(t, k + 13) * 0.3;  // 0.4–0.7s
    this.slotEndTimes[slot] = t + lifespan;

    const ix3 = slot * 3;
    const ix4 = slot * 4;

    this.positions[ix3 + 0] = xScatter;
    this.positions[ix3 + 1] = y;
    this.positions[ix3 + 2] = -0.5 - hash2(t, k + 23) * 1.5;

    // ADSR knobs that yield a pure-decay-style envelope. The shader's
    // fixed 150ms release tail does most of the fade work.
    this.spawn[ix4 + 0] = t;
    this.spawn[ix4 + 1] = lifespan;
    this.spawn[ix4 + 2] = 0.6;   // mid attack_slope — round, not snappy
    this.spawn[ix4 + 3] = 0;

    this.adsr[ix4 + 0] = 5;      // 5ms attack
    this.adsr[ix4 + 1] = 50;     // 50ms decay
    this.adsr[ix4 + 2] = 0.5;    // sustain at half
    this.adsr[ix4 + 3] = energy; // band energy as per-particle intensity

    // Tint by band: brighter at high bands. baseColor × [0.6 .. 1.4].
    const tintScale = 0.6 + (k / 7) * 0.8;
    this.colors[ix3 + 0] = this.baseColor.r * tintScale;
    this.colors[ix3 + 1] = this.baseColor.g * tintScale;
    this.colors[ix3 + 2] = this.baseColor.b * tintScale;

    // Smaller than per-onset particles — sparkles, not punches.
    this.baseSizes[slot] = this.maxSize * 0.6;

    const geo = this.object3D.geometry;
    (geo.getAttribute("position") as THREE.BufferAttribute).needsUpdate = true;
    (geo.getAttribute("aSpawn")   as THREE.BufferAttribute).needsUpdate = true;
    (geo.getAttribute("aADSR")    as THREE.BufferAttribute).needsUpdate = true;
    (geo.getAttribute("aColor")   as THREE.BufferAttribute).needsUpdate = true;
    (geo.getAttribute("aBaseSize")as THREE.BufferAttribute).needsUpdate = true;
  }

  dispose(): void {
    this.material.dispose();
    this.object3D.geometry.dispose();
  }
}

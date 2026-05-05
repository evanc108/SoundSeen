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

    // Bind the most recent onsets in (lo, hi].
    for (const onset of spec.onset_track) {
      if (onset.t <= lo) continue;
      if (onset.t > hi) break;
      this.spawnFor(onset, ctx, accentTint);
    }
  }

  private spawnFor(
    onset: OnsetDirective,
    ctx: FrameContext,
    accentTint?: THREE.Color,
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

    // Pitch → vertical placement (Pratt 1930). Atonal (-1) → center.
    const pitchHeight =
      onset.pitch_class >= 0 ? (onset.pitch_class / 11) * 2 - 1 : 0;
    // Pitch → inverse size (Walker 2010). High pitch → smaller particle.
    const sizeFromPitch =
      onset.pitch_class >= 0 ? 1.4 - 0.7 * ((onset.pitch_class / 11)) : 1.0;

    // Horizontal placement: slight randomness biased by pitch class so
    // different pitches don't all stack on the same X line. Determ
    // randomness: hash by onset time.
    const hash = (onset.t * 13.7) % 1;
    const x = (hash - 0.5) * 4.5;
    const y = pitchHeight * 1.6;  // ±1.6 NDC vertical range
    const z = -0.5 - hash * 1.5;

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

  dispose(): void {
    this.material.dispose();
    this.object3D.geometry.dispose();
  }
}

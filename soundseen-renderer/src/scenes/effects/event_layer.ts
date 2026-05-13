// Event layer — fullscreen additive overlay that fires discrete shape
// events on audio cues, giving every scene a clear visual punctuation
// rhythm on top of the continuous reactivity:
//
//   drop_triggers  → radial shockwave (expanding bright ring)
//   beatPulse      → brief white strobe lift
//   phrasePulse    → radial spoke burst (16-spoke fan emanating from
//                    center, decays over ~0.5s)
//
// All three are tinted per-biome via constructor opts. Magnitudes here
// are aggressive on purpose — the user's verdict on prior versions was
// "static" / "oval pulsing" — these events break that steady-state feel.

import * as THREE from "three";
import type { CompositionSpec, FrameContext } from "../../types.js";

const MAX_SHOCKWAVES = 4;

const EVENT_VERT = /* glsl */ `
  varying vec2 vUv;
  void main() {
    vUv = uv;
    gl_Position = vec4(position, 1.0);
  }
`;

const EVENT_FRAG = /* glsl */ `
  precision highp float;
  uniform float uTime;
  uniform float uShockTimes[${MAX_SHOCKWAVES}];   // wall time of each active shockwave
  uniform float uShockSpread;                     // 1.0 default, controls speed
  uniform float uBeatStrobe;
  uniform float uPhraseBurst;
  uniform float uAspect;
  uniform vec3  uShockColor;
  uniform vec3  uStrobeColor;
  uniform vec3  uBurstColor;

  varying vec2 vUv;

  float shockwave(vec2 d, float age) {
    if (age < 0.0 || age > 1.4) return 0.0;
    float r = length(d);
    // Ring radius grows from 0 to ~1.6 over 1.4s.
    float ringR = age * 1.4 * uShockSpread;
    float ringW = 0.08 + age * 0.25;
    float band = smoothstep(ringW, 0.0, abs(r - ringR));
    float fade = 1.0 - smoothstep(0.0, 1.4, age);
    // Multiply by a leading-edge sharpener so the front of the wave is
    // brighter than the trailing skirt.
    float front = smoothstep(0.10, 0.0, r - ringR);
    return band * fade * (0.7 + front * 0.6);
  }

  void main() {
    // Aspect-correct screen coords centered at (0.5, 0.5).
    vec2 d = (vUv - vec2(0.5)) * vec2(uAspect, 1.0);

    // ---- Shockwaves: sum up to MAX_SHOCKWAVES active ones ----
    float wave = 0.0;
    for (int i = 0; i < ${MAX_SHOCKWAVES}; i++) {
      float age = uTime - uShockTimes[i];
      wave += shockwave(d, age);
    }
    wave = min(wave, 1.5);

    // ---- Phrase radial burst: 16-spoke fan ----
    float ang = atan(d.y, d.x);
    float spokes = sin(ang * 16.0) * 0.5 + 0.5;
    spokes = pow(spokes, 6.0);
    float r2 = length(d);
    float radial = exp(-r2 * 1.6);
    float burst = spokes * radial * uPhraseBurst;

    // ---- Beat strobe: full-frame lift, no falloff ----
    float strobe = uBeatStrobe * 0.18;

    vec3 col = uShockColor * wave
             + uBurstColor  * burst * 1.2
             + uStrobeColor * strobe;
    float alpha = clamp(wave * 0.85 + burst * 0.7 + strobe, 0.0, 1.0);
    gl_FragColor = vec4(col, alpha);
  }
`;

export interface EventLayerOptions {
  shockColor: THREE.Color;
  strobeColor?: THREE.Color;
  burstColor?: THREE.Color;
  /// Multiplier on shockwave propagation speed. Default 1.0.
  shockSpread?: number;
  /// Aspect ratio of the render target. Default 16/9.
  aspect?: number;
}

export class EventLayer {
  readonly object3D: THREE.Mesh;
  private material: THREE.ShaderMaterial;
  private shockTimes: number[];
  private writeIdx = 0;
  private prevT = -1;

  constructor(opts: EventLayerOptions) {
    this.shockTimes = new Array(MAX_SHOCKWAVES).fill(-1000);

    this.material = new THREE.ShaderMaterial({
      vertexShader: EVENT_VERT,
      fragmentShader: EVENT_FRAG,
      uniforms: {
        uTime: { value: 0 },
        uShockTimes: { value: new Float32Array(this.shockTimes) },
        uShockSpread: { value: opts.shockSpread ?? 1.0 },
        uBeatStrobe: { value: 0 },
        uPhraseBurst: { value: 0 },
        uAspect: { value: opts.aspect ?? 16 / 9 },
        uShockColor: { value: opts.shockColor.clone() },
        uStrobeColor: {
          value: (opts.strobeColor ?? new THREE.Color("#ffffff")).clone(),
        },
        uBurstColor: {
          value: (opts.burstColor ?? opts.shockColor).clone(),
        },
      },
      transparent: true,
      blending: THREE.AdditiveBlending,
      depthTest: false,
      depthWrite: false,
    });

    this.object3D = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), this.material);
    this.object3D.frustumCulled = false;
    // Drawn after god-rays so events read on top of everything.
    this.object3D.renderOrder = 200;
  }

  update(spec: CompositionSpec, ctx: FrameContext): void {
    const u = this.material.uniforms;
    u.uTime.value = ctx.t;
    u.uBeatStrobe.value = ctx.beatPulse;
    u.uPhraseBurst.value = ctx.phrasePulse;

    // Push new drop triggers in (prevT, t] into the shockwave ring buffer.
    if (this.prevT >= 0) {
      for (const drop of spec.drop_triggers) {
        if (drop.t <= this.prevT) continue;
        if (drop.t > ctx.t) break;
        this.shockTimes[this.writeIdx] = drop.t;
        this.writeIdx = (this.writeIdx + 1) % MAX_SHOCKWAVES;
      }
    }
    this.prevT = ctx.t;

    // Sync into the typed-array uniform.
    const arr = u.uShockTimes.value as Float32Array;
    for (let i = 0; i < MAX_SHOCKWAVES; i++) arr[i] = this.shockTimes[i]!;
  }

  dispose(): void {
    this.material.dispose();
    this.object3D.geometry.dispose();
  }
}

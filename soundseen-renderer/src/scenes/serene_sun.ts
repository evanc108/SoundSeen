// Serene Dawn keystone hero — luminous low sun + corona halo + cloud
// strata. The single largest "wow" addition for the high-V low-A
// biome. Every visual parameter is explicitly wired to a librosa
// feature; the mapping table in MAPPINGS.md covers them in full.
//
// Audio mapping (per parameter):
//   sun disk vertical pos     ← pitchHeight                (Pratt 1930)
//   sun disk size             ← harmonicRatio              (Bouba/Kiki — tonal=bigger)
//   sun disk core brightness  ← rms × section.brightness   (Spence 2011 loudness→mass)
//   corona spread             ← chromaStrength             (tonal frames bloom wide)
//   corona softness           ← harmonicRatio              (smooth vs granular)
//   sun hue                   ← mfccWarm                   (warm tilt)
//   cloud band density        ← 1 - rms                    (loud = clear sky)
//   cloud band drift speed    ← spectralFlux               (transient density)
//   cloud band tint           ← chromaStrength + mfccWarm
//   horizon glow              ← centroid                   (brightness mix)

import * as THREE from "three";
import type { CompositionSpec, FrameContext } from "../types.js";

const SUN_VERT = /* glsl */ `
  varying vec2 vUv;
  void main() {
    vUv = uv;
    gl_Position = vec4(position, 1.0);
  }
`;

const SUN_FRAG = /* glsl */ `
  precision highp float;
  uniform float uTime;
  uniform vec2  uSunPos;          // screen-space sun center [0..1]^2
  uniform float uDiskRadius;      // ← harmonicRatio
  uniform float uCoreBrightness;  // ← rms × section.brightness
  uniform float uCoronaSpread;    // ← chromaStrength
  uniform float uCoronaSoftness;  // ← harmonicRatio
  uniform float uCloudDensity;    // ← 1 - rms
  uniform float uCloudDrift;      // ← spectralFlux
  uniform float uHorizonGlow;     // ← centroid
  uniform vec3  uSunColor;        // ← mfccWarm warmth
  uniform vec3  uCloudTint;
  uniform vec3  uHorizonColor;

  varying vec2 vUv;

  // 2D value noise — cheap, used for cloud bands.
  float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
  }
  float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i),                hash(i + vec2(1, 0)), u.x),
               mix(hash(i + vec2(0, 1)),   hash(i + vec2(1, 1)), u.x), u.y);
  }
  float fbm(vec2 p) {
    return noise(p) * 0.55
         + noise(p * 2.1 + 1.3) * 0.30
         + noise(p * 4.7 + 3.1) * 0.15;
  }

  void main() {
    // Sun disk: bright core falling off radially, then a wide corona.
    vec2 d = vUv - uSunPos;
    // Stretch the sun slightly vertically to read as a low rising sun.
    d.y *= 1.4;
    float r = length(d);

    float core = smoothstep(uDiskRadius * 0.55, 0.0, r);
    float corona = exp(-r / max(0.05, uCoronaSpread * 0.30));
    corona *= mix(1.0, 1.4, uCoronaSoftness);

    vec3 col = uSunColor * (core * uCoreBrightness + corona * 0.7);

    // Horizon glow: warm haze hugging the bottom 35% of the frame.
    float horizonMask = smoothstep(0.35, 0.0, vUv.y);
    col += uHorizonColor * horizonMask * (0.30 + uHorizonGlow * 0.45);

    // Cloud strata: 2–3 stacked horizontal bands of low-amplitude fbm
    // scrolling at uCloudDrift. Density gates the band opacity.
    float bandWeight = 0.0;
    for (int b = 0; b < 3; b++) {
      float bandY = 0.55 + float(b) * 0.07;
      float bandThickness = 0.05;
      float yMask = smoothstep(bandThickness, 0.0, abs(vUv.y - bandY));
      vec2 q = vec2(vUv.x * 4.0 + uTime * uCloudDrift + float(b) * 7.3,
                    vUv.y * 6.0);
      float c = fbm(q);
      bandWeight += yMask * smoothstep(0.45, 0.85, c);
    }
    bandWeight = clamp(bandWeight, 0.0, 1.0) * uCloudDensity;
    col = mix(col, uCloudTint, bandWeight * 0.55);

    // Output alpha: opaque where any element registered, transparent
    // elsewhere so we layer cleanly over the existing bg gradient.
    float alpha = clamp(core * uCoreBrightness * 1.4
                      + corona * 0.6
                      + horizonMask * (0.30 + uHorizonGlow * 0.40)
                      + bandWeight * 0.55, 0.0, 1.0);
    gl_FragColor = vec4(col, alpha);
  }
`;

export class SereneSunScene {
  readonly object3D: THREE.Mesh;
  private material: THREE.ShaderMaterial;

  constructor() {
    this.material = new THREE.ShaderMaterial({
      vertexShader: SUN_VERT,
      fragmentShader: SUN_FRAG,
      uniforms: {
        uTime: { value: 0 },
        // Sun anchored low and slightly right — sunrise feel.
        uSunPos: { value: new THREE.Vector2(0.55, 0.40) },
        uDiskRadius: { value: 0.18 },
        uCoreBrightness: { value: 1.0 },
        uCoronaSpread: { value: 0.5 },
        uCoronaSoftness: { value: 0.7 },
        uCloudDensity: { value: 0.5 },
        uCloudDrift: { value: 0.02 },
        uHorizonGlow: { value: 0.5 },
        // Warm cream-amber sun; cool warm tilt with mfccWarm lerps it
        // toward the deeper-amber end during dark-instrument frames.
        uSunColor: { value: new THREE.Color("#ffe2a0") },
        uCloudTint: { value: new THREE.Color("#ffd6a0") },
        uHorizonColor: { value: new THREE.Color("#ffa86b") },
      },
      transparent: true,
      depthTest: false,
      depthWrite: false,
    });

    this.object3D = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), this.material);
    this.object3D.frustumCulled = false;
    // Drawn after the bg gradient but before particles/post-FX.
    this.object3D.renderOrder = -8;
  }

  update(_spec: CompositionSpec, ctx: FrameContext): void {
    const u = this.material.uniforms;
    u.uTime.value = ctx.t;

    // pitchHeight (-1..+1) drives sun vertical placement.
    // Map -1 → y=0.30 (low), +1 → y=0.55 (high).
    const pitchHeight = ctx.audio.pitchHeight ?? 0;
    const sunY = 0.42 + pitchHeight * 0.12;
    (u.uSunPos.value as THREE.Vector2).y = sunY;

    // harmonicRatio (0..1) drives sun disk radius (Bouba/Kiki).
    u.uDiskRadius.value = 0.13 + ctx.audio.harmonicRatio * 0.10;

    // rms × section.brightness → core brightness (Spence 2011).
    const sectionBri = ctx.section?.brightness ?? 1.0;
    u.uCoreBrightness.value =
      (0.6 + ctx.audio.rms * 1.1) * sectionBri;

    // chromaStrength → corona spread; harmonicRatio → softness.
    u.uCoronaSpread.value = 0.4 + ctx.audio.chromaStrength * 0.7;
    u.uCoronaSoftness.value = ctx.audio.harmonicRatio;

    // Loud passages clear the sky; quiet passages thicken cloud bands.
    u.uCloudDensity.value = 0.35 + (1 - ctx.audio.rms) * 0.55;
    // spectralFlux → cloud drift speed.
    u.uCloudDrift.value = 0.02 + ctx.audio.spectralFlux * 0.18;

    // centroid → horizon glow intensity (bright timbres glow more).
    u.uHorizonGlow.value = ctx.audio.centroid;

    // mfccWarm (-1..+1) → sun color warmth.
    const warm = (ctx.audio.mfccWarm + 1) * 0.5;
    (u.uSunColor.value as THREE.Color).setRGB(
      0.95 + warm * 0.10,
      0.78 + warm * 0.12,
      0.42 + (1 - warm) * 0.25,
    );
  }

  dispose(): void {
    this.material.dispose();
    this.object3D.geometry.dispose();
  }
}

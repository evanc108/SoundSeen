// Volumetric god-ray shafts — fullscreen additive pass usable in any
// biome scene. Constructor takes a palette + sun-position so each
// biome tints them appropriately (cool silver for melancholic, warm
// gold for serene, hot magenta for euphoric, electric blue for storm).
//
// Shader: three angle-band streak patterns at different frequencies +
// animation phases, sharpened via power curve, radial + vertical
// falloff. Audio reactivity is uniform across biomes — caller supplies
// the palette via the constructor and updates the standard set of
// uniforms via update().

import * as THREE from "three";
import type { CompositionSpec, FrameContext } from "../../types.js";

const GODRAY_VERT = /* glsl */ `
  varying vec2 vUv;
  void main() {
    vUv = uv;
    gl_Position = vec4(position, 1.0);
  }
`;

const GODRAY_FRAG = /* glsl */ `
  precision highp float;
  uniform float uTime;
  uniform float uIntensity;
  uniform float uSpread;
  uniform float uPhraseFlash;
  uniform vec3  uShaftColor;
  uniform vec2  uSunPos;
  uniform float uVerticalBias;  // 0 = rays fade upward, 1 = fade downward

  varying vec2 vUv;

  void main() {
    vec2 dir = vUv - uSunPos;
    float angle = atan(dir.y, dir.x);
    float dist  = length(dir);

    float a = sin(angle * 30.0 + uTime * 0.07);
    float b = sin(angle * 17.0 - uTime * 0.04 + 1.7);
    float c = sin(angle * 9.0  + uTime * 0.02 + 3.1);
    float streak = (a * 0.5 + b * 0.3 + c * 0.2) * 0.5 + 0.5;
    streak = pow(streak, mix(5.0, 2.5, uSpread));

    streak *= exp(-dist * 1.2);

    // Vertical falloff: choose which half of the frame brightens.
    float vMask = mix(
      smoothstep(-0.05, 0.55, vUv.y),       // upper-half bright
      smoothstep(1.05, 0.45, vUv.y),        // lower-half bright
      uVerticalBias
    );
    streak *= vMask;

    streak += uPhraseFlash * 0.15;
    streak *= 1.0 + uPhraseFlash * 0.35;

    float intensity = streak * uIntensity;
    vec3 col = uShaftColor * intensity;
    gl_FragColor = vec4(col, intensity);
  }
`;

export interface GodRaysOptions {
  /// Base shaft color. Will be lerped with the warm tint when chroma is high.
  shaftColor: THREE.Color;
  /// Sun position in screen NDC-like coords [0,1]^2. Off-frame is fine.
  sunPos: THREE.Vector2;
  /// Optional second color the shaft tints toward at high chroma_strength.
  warmTint?: THREE.Color;
  /// 0 = rays fade upward (top dim, bottom bright); 1 = rays fade downward.
  /// Default 0 — light comes from above.
  verticalBias?: number;
  /// Intensity baseline before audio reactivity; default 0.10.
  intensityBase?: number;
  /// Multiplier on the (rms+chroma+build) reactivity sum; default 1.0.
  intensityScale?: number;
}

export class GodRays {
  readonly object3D: THREE.Mesh;
  private material: THREE.ShaderMaterial;
  private opts: GodRaysOptions;
  private baseColor: THREE.Color;
  private warmColor: THREE.Color;

  constructor(opts: GodRaysOptions) {
    this.opts = opts;
    this.baseColor = opts.shaftColor.clone();
    this.warmColor = (opts.warmTint ?? opts.shaftColor).clone();

    this.material = new THREE.ShaderMaterial({
      vertexShader: GODRAY_VERT,
      fragmentShader: GODRAY_FRAG,
      uniforms: {
        uTime: { value: 0 },
        uIntensity: { value: 0 },
        uSpread: { value: 0.5 },
        uPhraseFlash: { value: 0 },
        uShaftColor: { value: this.baseColor.clone() },
        uSunPos: { value: opts.sunPos.clone() },
        uVerticalBias: { value: opts.verticalBias ?? 0 },
      },
      transparent: true,
      blending: THREE.AdditiveBlending,
      depthTest: false,
      depthWrite: false,
    });

    this.object3D = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), this.material);
    this.object3D.frustumCulled = false;
    this.object3D.renderOrder = 100;
  }

  update(_spec: CompositionSpec, ctx: FrameContext): void {
    const u = this.material.uniforms;
    u.uTime.value = ctx.t;

    const base = this.opts.intensityBase ?? 0.10;
    const scale = this.opts.intensityScale ?? 1.0;
    const intensity = Math.min(
      1.2,
      base +
        scale *
          (ctx.audio.rms * 0.55 +
            ctx.audio.chromaStrength * 0.30 +
            ctx.buildIntensity * 0.25),
    );
    u.uIntensity.value = intensity;
    u.uSpread.value = ctx.audio.centroid;
    u.uPhraseFlash.value = ctx.phrasePulse;

    // Lerp shaft color between base and warm tint via chroma_strength.
    const t = ctx.audio.chromaStrength;
    const tint = u.uShaftColor.value as THREE.Color;
    tint.setRGB(
      this.baseColor.r * (1 - t) + this.warmColor.r * t,
      this.baseColor.g * (1 - t) + this.warmColor.g * t,
      this.baseColor.b * (1 - t) + this.warmColor.b * t,
    );
  }

  dispose(): void {
    this.material.dispose();
    this.object3D.geometry.dispose();
  }
}

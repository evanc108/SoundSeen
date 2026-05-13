// Texture vocabulary overlay — the visual *surface* responds to the
// music's character. Fullscreen multiplicative + additive layer whose
// pattern is chosen by which audio feature dominates:
//
//   high angularity   → halftone dot grid (percussive/kiki feel)
//   high zcr          → CRT scanlines (sibilant/hissy)
//   high chroma       → iridescent vertical color bands (tonal/chord)
//   high harmonic     → smooth ink-bleed wash (sustained/bouba)
//   drop_impulse      → horizontal slice glitch displacement
//
// Each treatment fades in/out smoothly so dominant transitions don't
// pop. All four can co-exist when the audio sits at the corners of the
// feature space.
//
// This effect is cheap: one fullscreen quad, no framebuffer sampling.
// The patterns multiply/add against the already-rendered scene via
// AdditiveBlending / NormalBlending mix.

import * as THREE from "three";
import type { CompositionSpec, FrameContext } from "../../types.js";

const OVERLAY_VERT = /* glsl */ `
  varying vec2 vUv;
  void main() {
    vUv = uv;
    gl_Position = vec4(position, 1.0);
  }
`;

const OVERLAY_FRAG = /* glsl */ `
  precision highp float;
  uniform float uTime;
  uniform float uAngularity;
  uniform float uZcr;
  uniform float uChromaStrength;
  uniform float uHarmonicRatio;
  uniform float uDropImpulse;
  uniform vec3  uTintColor;

  varying vec2 vUv;

  float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

  void main() {
    vec3 col = vec3(0.0);
    float a = 0.0;

    // ---- Halftone dots ----
    // Active when angularity high. Cell grid of fading dots; dot size
    // shrinks toward the center of each cell, so the dark fills the
    // gaps between dots. The effect reads as a print-newsprint texture.
    float angW = smoothstep(0.35, 0.7, uAngularity);
    if (angW > 0.001) {
      vec2 cellPx = vec2(8.0);            // ~8-px cells at 1080p
      vec2 cell = floor(vUv * 240.0);     // ~240 cells across width
      vec2 cellUv = fract(vUv * 240.0) - 0.5;
      float d = length(cellUv);
      float dotR = mix(0.45, 0.20, uAngularity);
      float dot = 1.0 - smoothstep(dotR, dotR + 0.12, d);
      // Halftone darkens *between* dots — invert.
      col -= vec3(0.40) * angW * (1.0 - dot);
      a += 0.4 * angW * (1.0 - dot);
    }

    // ---- Scanlines ----
    // Active when zcr high. Horizontal interference pattern, 1080 lines
    // per height = one scanline per pixel-row at 1080p.
    float zcrW = smoothstep(0.4, 0.75, uZcr);
    if (zcrW > 0.001) {
      float scan = sin(vUv.y * 1440.0) * 0.5 + 0.5;
      // Slight horizontal jitter on scanline phase for CRT flicker.
      float jitter = sin(uTime * 8.0 + vUv.y * 60.0) * 0.5 + 0.5;
      float scanMask = mix(0.7, 1.0, scan) * mix(0.85, 1.0, jitter);
      col -= vec3(0.30) * zcrW * (1.0 - scanMask);
      a += 0.3 * zcrW * (1.0 - scanMask);
    }

    // ---- Iridescent vertical bands ----
    // Active when chromaStrength high. Subtle prismatic shift — vertical
    // soft bands of tinted RGB drift slowly. Reads as oil-slick / chord
    // color halo.
    float chrW = smoothstep(0.55, 0.85, uChromaStrength);
    if (chrW > 0.001) {
      float bandPhase = vUv.x * 4.0 + uTime * 0.15;
      vec3 irid = vec3(
        sin(bandPhase) * 0.5 + 0.5,
        sin(bandPhase + 2.094) * 0.5 + 0.5,
        sin(bandPhase + 4.189) * 0.5 + 0.5
      );
      col += irid * 0.08 * chrW;
      a += 0.08 * chrW;
    }

    // ---- Smooth ink-bleed wash ----
    // Active when harmonicRatio high. Slow low-amplitude noise haze that
    // gives the frame a soft "ink on paper" feel during sustained tonal
    // passages — the *opposite* of the halftone treatment.
    float harW = smoothstep(0.6, 0.9, uHarmonicRatio);
    if (harW > 0.001) {
      float wash = hash(floor(vUv * 50.0 + vec2(uTime * 0.4))) * 0.5;
      col += uTintColor * wash * 0.10 * harW;
      a += 0.10 * harW;
    }

    // ---- Drop glitch slices ----
    // Active when drop_impulse > 0.3. Horizontal slices flicker with
    // chromatic offset — RGB channels split by a few pixels worth of UV.
    float dropW = smoothstep(0.3, 0.7, uDropImpulse);
    if (dropW > 0.001) {
      float sliceN = floor(vUv.y * 25.0 + uTime * 12.0);
      float sliceH = hash(vec2(sliceN, floor(uTime * 16.0)));
      if (sliceH > 0.75) {
        float offset = (sliceH - 0.85) * 0.06 * dropW;
        // Channel split — synthesize via additive tinted bands.
        col.r += 0.25 * dropW * step(0.85, sliceH);
        col.b += 0.25 * dropW * step(0.85, sliceH);
        a += 0.25 * dropW * step(0.85, sliceH);
      }
    }

    gl_FragColor = vec4(col, clamp(a, 0.0, 1.0));
  }
`;

export interface TextureOverlayOptions {
  /// Tint color for the ink-bleed wash. Defaults to neutral white.
  tintColor?: THREE.Color;
}

export class TextureOverlay {
  readonly object3D: THREE.Mesh;
  private material: THREE.ShaderMaterial;

  constructor(opts: TextureOverlayOptions = {}) {
    this.material = new THREE.ShaderMaterial({
      vertexShader: OVERLAY_VERT,
      fragmentShader: OVERLAY_FRAG,
      uniforms: {
        uTime: { value: 0 },
        uAngularity: { value: 0 },
        uZcr: { value: 0 },
        uChromaStrength: { value: 0 },
        uHarmonicRatio: { value: 0 },
        uDropImpulse: { value: 0 },
        uTintColor: { value: (opts.tintColor ?? new THREE.Color("#ffffff")).clone() },
      },
      transparent: true,
      // Custom blending: combine multiplicative darkening (halftone +
      // scanlines) with additive lift (iridescence + wash). Use normal
      // blending with alpha so the layer composites cleanly atop the
      // scene render — the shader already encodes the additive parts as
      // positive rgb and the multiplicative parts as negative rgb that
      // alpha-blends into a dim region.
      blending: THREE.NormalBlending,
      depthTest: false,
      depthWrite: false,
    });

    this.object3D = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), this.material);
    this.object3D.frustumCulled = false;
    // Drawn after every other 3D element AND after the event layer, so
    // the texture treatment is the final word over everything.
    this.object3D.renderOrder = 300;
  }

  update(_spec: CompositionSpec, ctx: FrameContext): void {
    const u = this.material.uniforms;
    u.uTime.value = ctx.t;
    const angularity = ctx.section?.angularity ?? 0.5;
    u.uAngularity.value = angularity;
    u.uZcr.value = ctx.audio.zcr;
    u.uChromaStrength.value = ctx.audio.chromaStrength;
    u.uHarmonicRatio.value = ctx.audio.harmonicRatio;
    u.uDropImpulse.value = ctx.dropImpulse;
  }

  dispose(): void {
    this.material.dispose();
    this.object3D.geometry.dispose();
  }
}

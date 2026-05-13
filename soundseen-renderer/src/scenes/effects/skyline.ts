// Distant silhouette parallax — two billboard layers in the upper
// frame with a procedurally generated DataTexture silhouette.
//
// Constructor takes building/window colors so each biome ships its own
// distant-feel (urban indigo for melancholic, warm hills for serene,
// festival towers for euphoric, jagged storm crags for intense).
//
// Audio reactivity:
//   - Far layer x-drift   ±0.02 u/s · (centroid - 0.5)
//   - Near layer x-drift  ±0.01 u/s
//   - Window glow         multiplied by chroma_strength
//   - Lightning flicker   far layer warm flash on drop_triggers

import * as THREE from "three";
import type { CompositionSpec, FrameContext } from "../../types.js";
import { hash1, hash2, hash3 } from "../lib/deterministic_hash.js";

const SKYLINE_VERT = /* glsl */ `
  varying vec2 vUv;
  void main() {
    vUv = uv;
    gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
  }
`;

const SKYLINE_FRAG = /* glsl */ `
  precision highp float;
  uniform sampler2D uTex;
  uniform float uScroll;
  uniform float uChromaStrength;
  uniform float uDropFlicker;
  uniform float uDepth;
  uniform vec3  uBuildingColor;
  uniform vec3  uWindowColor;
  uniform vec3  uFlickerColor;
  uniform vec3  uHazeTint;       // additive haze color for far layer

  varying vec2 vUv;

  void main() {
    vec2 uv = vec2(vUv.x + uScroll, vUv.y);
    vec4 tex = texture2D(uTex, uv);
    if (tex.a < 0.01) discard;

    vec3 col = mix(uBuildingColor, uWindowColor,
                   tex.r * uChromaStrength);
    col += uFlickerColor * uDropFlicker * 0.4;
    col *= mix(0.55, 1.0, uDepth);
    col += uHazeTint * (1.0 - uDepth);

    gl_FragColor = vec4(col, tex.a * mix(0.75, 1.0, uDepth));
  }
`;

export type SilhouetteShape = "urban" | "hills" | "festival" | "crags";

export interface SkylineOptions {
  buildingColor: THREE.Color;
  windowColor: THREE.Color;
  flickerColor?: THREE.Color;
  hazeTint?: THREE.Color;
  /// Silhouette shape selector — different procedurals per biome.
  shape?: SilhouetteShape;
  /// Whether to enable lightning flicker on drops. Default true.
  enableFlicker?: boolean;
  /// Multiplier on chroma-driven window glow. Default 1.0.
  windowReactivity?: number;
  /// Y position of the far layer mesh; default 1.8.
  farY?: number;
  /// Y position of the near layer mesh; default 1.2.
  nearY?: number;
}

function generateSilhouetteTexture(shape: SilhouetteShape): THREE.DataTexture {
  const W = 512;
  const H = 128;
  const data = new Uint8Array(W * H * 4);
  const heights = new Float32Array(W);

  if (shape === "urban") {
    // Sharp boxy buildings with windows.
    for (let x = 0; x < W; x++) {
      const n1 = hash1(x * 0.04) * 0.55;
      const n2 = hash2(x * 0.13, 1) * 0.3;
      const n3 = hash3(x * 0.05, 1, 2) * 0.2;
      heights[x] = Math.pow(Math.min(1, n1 + n2 + n3), 1.25) * 0.88;
    }
  } else if (shape === "hills") {
    // Rolling smooth hills — multiple low-freq sines summed.
    for (let x = 0; x < W; x++) {
      const u = x / W;
      const h =
        0.35 +
        Math.sin(u * Math.PI * 2.1 + 0.3) * 0.18 +
        Math.sin(u * Math.PI * 3.7 + 1.4) * 0.10 +
        Math.sin(u * Math.PI * 5.5 + 2.1) * 0.06 +
        hash1(x * 0.02) * 0.05;
      heights[x] = Math.max(0.15, Math.min(0.8, h));
    }
  } else if (shape === "festival") {
    // Festival skyline — tall narrow spires of varying heights, like
    // stage rigs. More variance than urban, sharper peaks.
    for (let x = 0; x < W; x++) {
      const spire = hash1(Math.floor(x / 8) * 0.5);
      const h = Math.pow(spire, 0.7) * 0.9;
      heights[x] = h * (0.85 + hash2(x, 7) * 0.15);
    }
  } else {
    // crags — jagged peaks, high contrast.
    for (let x = 0; x < W; x++) {
      const n1 = hash1(x * 0.08) * 0.6;
      const n2 = hash2(x * 0.21, 1) * 0.4;
      heights[x] = Math.pow(Math.max(0, n1 + n2 - 0.1), 2.0) * 0.95;
    }
  }

  // Smooth 1-pass.
  const smoothed = new Float32Array(W);
  for (let x = 0; x < W; x++) {
    const prev = heights[(x - 1 + W) % W]!;
    const next = heights[(x + 1) % W]!;
    smoothed[x] = (prev + heights[x]! * 2 + next) / 4;
  }

  const hasWindows = shape === "urban" || shape === "festival";

  for (let y = 0; y < H; y++) {
    const yNorm = 1 - y / H;
    for (let x = 0; x < W; x++) {
      const idx = (y * W + x) * 4;
      const top = smoothed[x]!;
      if (yNorm < top) {
        let isWindow = false;
        if (hasWindows) {
          const cellSize = shape === "festival" ? 4 : 6;
          const wx = Math.floor(x / cellSize);
          const wy = Math.floor((y / H) * 24);
          const threshold = shape === "festival" ? 0.55 : 0.74;
          isWindow =
            hash3(wx, wy, 17) > threshold &&
            yNorm > 0.06 &&
            yNorm < top - 0.04;
        }
        data[idx + 0] = isWindow ? 235 : 0;
        data[idx + 1] = 35;
        data[idx + 2] = 60;
        data[idx + 3] = 255;
      } else {
        data[idx + 3] = 0;
      }
    }
  }

  const tex = new THREE.DataTexture(data, W, H, THREE.RGBAFormat);
  tex.needsUpdate = true;
  tex.wrapS = THREE.RepeatWrapping;
  tex.wrapT = THREE.ClampToEdgeWrapping;
  tex.minFilter = THREE.LinearFilter;
  tex.magFilter = THREE.LinearFilter;
  tex.generateMipmaps = false;
  return tex;
}

export class Skyline {
  readonly object3D: THREE.Group;
  private farMaterial: THREE.ShaderMaterial;
  private nearMaterial: THREE.ShaderMaterial;
  private texture: THREE.DataTexture;
  private opts: SkylineOptions;

  constructor(opts: SkylineOptions) {
    this.opts = opts;
    this.object3D = new THREE.Group();
    this.texture = generateSilhouetteTexture(opts.shape ?? "urban");

    this.farMaterial = this.makeMaterial(true);
    this.nearMaterial = this.makeMaterial(false);

    const far = new THREE.Mesh(
      new THREE.PlaneGeometry(40, 10),
      this.farMaterial,
    );
    far.position.set(0, opts.farY ?? 1.8, -15);
    far.renderOrder = -5;
    this.object3D.add(far);

    const near = new THREE.Mesh(
      new THREE.PlaneGeometry(24, 6),
      this.nearMaterial,
    );
    near.position.set(0, opts.nearY ?? 1.2, -8);
    near.renderOrder = -4;
    this.object3D.add(near);
  }

  private makeMaterial(isFar: boolean): THREE.ShaderMaterial {
    return new THREE.ShaderMaterial({
      vertexShader: SKYLINE_VERT,
      fragmentShader: SKYLINE_FRAG,
      uniforms: {
        uTex: { value: this.texture },
        uScroll: { value: 0 },
        uChromaStrength: { value: 0 },
        uDropFlicker: { value: 0 },
        uDepth: { value: isFar ? 0.55 : 1.0 },
        uBuildingColor: { value: this.opts.buildingColor.clone() },
        uWindowColor: { value: this.opts.windowColor.clone() },
        uFlickerColor: {
          value: (this.opts.flickerColor ?? new THREE.Color("#fff0d8")).clone(),
        },
        uHazeTint: {
          value: (this.opts.hazeTint ?? new THREE.Color("#000008")).clone(),
        },
      },
      transparent: true,
      depthWrite: false,
    });
  }

  update(_spec: CompositionSpec, ctx: FrameContext): void {
    const reactivity = this.opts.windowReactivity ?? 1.0;
    this.farMaterial.uniforms.uScroll.value =
      ctx.t * 0.02 * (ctx.audio.centroid - 0.5);
    this.nearMaterial.uniforms.uScroll.value =
      ctx.t * 0.01 * (ctx.audio.centroid - 0.5);

    this.farMaterial.uniforms.uChromaStrength.value =
      ctx.audio.chromaStrength * 0.35 * reactivity;
    this.nearMaterial.uniforms.uChromaStrength.value =
      ctx.audio.chromaStrength * 0.75 * reactivity;

    const flickerEnabled = this.opts.enableFlicker ?? true;
    const flickerVal = flickerEnabled ? ctx.dropImpulse : 0;
    this.farMaterial.uniforms.uDropFlicker.value = flickerVal;
    this.nearMaterial.uniforms.uDropFlicker.value = flickerVal * 0.3;
  }

  dispose(): void {
    this.farMaterial.dispose();
    this.nearMaterial.dispose();
    this.texture.dispose();
    this.object3D.traverse((obj) => {
      if (obj instanceof THREE.Mesh) obj.geometry.dispose();
    });
  }
}

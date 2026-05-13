// Browser-side runtime that lives inside headless Chrome.
//
// The Node orchestrator (../render.ts) loads this page via Playwright,
// injects a CompositionSpec via window.__loadSpec(spec), then steps frames
// one at a time via window.__renderFrameAt(t) and reads the canvas back.
//
// Real-time playback is intentionally avoided — every frame is rendered
// at a fixed delta (1/fps), so the output is bit-deterministic regardless
// of wall clock or system load.

import * as THREE from "three";
import {
  BloomEffect,
  BrightnessContrastEffect,
  ChromaticAberrationEffect,
  EffectComposer,
  EffectPass,
  HueSaturationEffect,
  KernelSize,
  NoiseEffect,
  RenderPass,
  ToneMappingEffect,
  ToneMappingMode,
  VignetteEffect,
  VignetteTechnique,
  BlendFunction,
} from "postprocessing";
import type {
  CompositionSpec,
  EmotionSample,
  FrameContext,
  SectionDirective,
  PhraseDirective,
  BiomeWeights,
} from "../types.js";
import { makeScene } from "../scenes/registry.js";
import type { Scene } from "../scenes/scene.js";

declare global {
  interface Window {
    __loadSpec(spec: CompositionSpec): void;
    __renderFrameAt(t: number): void;
    __ready: boolean;
  }
}

const FPS = 60;
const WIDTH = 1920;
const HEIGHT = 1080;

const canvas = document.getElementById("canvas") as HTMLCanvasElement;
const renderer = new THREE.WebGLRenderer({
  canvas,
  antialias: true,
  preserveDrawingBuffer: true, // so toBlob() / readback returns the last frame
});
renderer.setSize(WIDTH, HEIGHT, false);
renderer.setClearColor(0x000000, 1);
// EffectComposer (postprocessing lib) provides ACES tonemap as a pass —
// disable renderer-level tonemapping so we don't double-apply.
renderer.toneMapping = THREE.NoToneMapping;

// EffectComposer pipeline. HalfFloatType MRTs preserve HDR through the
// chain so bloom and grade operate in linear space. The pipeline is
// built lazily once the first scene is known (RenderPass needs a scene
// + camera reference at construction time).
const composer = new EffectComposer(renderer, {
  frameBufferType: THREE.HalfFloatType,
  multisampling: 0,
});
let renderPass: RenderPass | null = null;
let postPassA: EffectPass | null = null;
let postPassB: EffectPass | null = null;
// Per-biome bloom intensity. Euphoric should glow more; Melancholic
// should glow less. We mutate bloomEffect.intensity at scene swap time.
const BIOME_BLOOM_INTENSITY: Record<string, number> = {
  euphoric_bloom: 1.4,
  serene_dawn: 0.9,
  intense_storm: 1.2,
  melancholic_rain: 0.7,
};
// MipmapBlur is the only viable bloom variant on swiftshader (Kawase
// re-reads near-full-res 4-6× per pass). Threshold 0.8 — only bright
// cores (radial bloom centers, lightning bolts, particle highlights)
// glow; the rest of the scene stays grounded.
const bloomEffect = new BloomEffect({
  luminanceThreshold: 0.80,
  luminanceSmoothing: 0.10,
  intensity: 1.0,
  kernelSize: KernelSize.LARGE,
  mipmapBlur: true,
});
// Lens-stage radial RGB split. Driven per-frame by SectionDirective
// hue_distance (Schloss & Palmer 2011 — at high tension, complementary-
// hue split reads as visual dissonance). Lives in EffectPass A so the
// smear inherits bloom halos, like a real lens.
const chromaticAberrationEffect = new ChromaticAberrationEffect({
  offset: new THREE.Vector2(0.0008, 0),
  radialModulation: false,
  modulationOffset: 0,
});
// Display-stage passes (EffectPass B). Order inside the pass matters:
// tonemap MUST come before grade/vignette/grain because LUT and contrast
// curves assume LDR input.
const toneMappingEffect = new ToneMappingEffect({
  mode: ToneMappingMode.ACES_FILMIC,
});
// Per-biome color grade. Each scene swap nudges hue/saturation/
// contrast toward the biome's identity (warm for Euphoric, cool for
// Melancholic, neutral for Serene, push-contrast for Intense).
const hueSaturationEffect = new HueSaturationEffect({
  hue: 0,
  saturation: 0.10,
});
const brightnessContrastEffect = new BrightnessContrastEffect({
  brightness: 0,
  contrast: 0.10,
});
// Section-tension drives vignette tightness. Crushes the frame edges
// when the music gets dense.
const vignetteEffect = new VignetteEffect({
  technique: VignetteTechnique.DEFAULT,
  offset: 0.30,
  darkness: 0.40,
});
// Film grain. ZCR (noise/sibilance density) drives opacity — sibilant
// passages get visibly grittier.
const noiseEffect = new NoiseEffect({
  blendFunction: BlendFunction.OVERLAY,
  premultiply: false,
});
noiseEffect.blendMode.opacity.value = 0.05;
// Per-biome grade presets. Mutated on scene swap.
const BIOME_GRADE: Record<string, { hue: number; sat: number; bri: number; con: number }> = {
  euphoric_bloom:   { hue:  0.04, sat:  0.20, bri:  0.02, con:  0.10 },
  serene_dawn:      { hue: -0.02, sat:  0.06, bri:  0.00, con:  0.06 },
  intense_storm:    { hue:  0.00, sat:  0.15, bri: -0.04, con:  0.20 },
  melancholic_rain: { hue: -0.06, sat: -0.05, bri: -0.06, con:  0.08 },
};

let spec: CompositionSpec | null = null;
let currentScene: Scene | null = null;
let currentSceneName: string | null = null;

function makeSceneFor(spec: CompositionSpec, t: number): Scene {
  const section = sectionAt(spec, t);
  const sceneName = section?.scene ?? "serene_dawn";
  if (sceneName !== currentSceneName) {
    currentScene?.dispose();
    currentScene = makeScene(sceneName);
    currentSceneName = sceneName;
    // Re-target the composer's RenderPass at the new scene. The
    // downstream effect passes don't depend on scene identity (most
    // effects ignore the camera) but EffectPass holds a camera ref,
    // so we update both.
    if (renderPass === null) {
      renderPass = new RenderPass(currentScene.object3D, currentScene.camera);
      composer.addPass(renderPass);
      // EffectPass A — linear-space, sees bloomed HDR. Bloom then CA
      // so the chromatic smear inherits the bloom halo (lens-stage).
      postPassA = new EffectPass(currentScene.camera, bloomEffect, chromaticAberrationEffect);
      composer.addPass(postPassA);
      // EffectPass B — display-stage. Tonemap MUST come first so grade/
      // vignette/grain operate on LDR. Grain last (sensor noise).
      postPassB = new EffectPass(
        currentScene.camera,
        toneMappingEffect,
        hueSaturationEffect,
        brightnessContrastEffect,
        vignetteEffect,
        noiseEffect,
      );
      composer.addPass(postPassB);
    } else {
      renderPass.mainScene = currentScene.object3D;
      renderPass.mainCamera = currentScene.camera;
      if (postPassA) postPassA.mainCamera = currentScene.camera;
      if (postPassB) postPassB.mainCamera = currentScene.camera;
    }
    bloomEffect.intensity = BIOME_BLOOM_INTENSITY[sceneName] ?? 1.0;
    const grade = BIOME_GRADE[sceneName];
    if (grade) {
      hueSaturationEffect.hue = grade.hue;
      hueSaturationEffect.saturation = grade.sat;
      brightnessContrastEffect.brightness = grade.bri;
      brightnessContrastEffect.contrast = grade.con;
    }
  }
  return currentScene!;
}

function sectionAt(spec: CompositionSpec, t: number): SectionDirective | null {
  // Linear scan is fine — sections lists are short (~5–10 per song).
  for (const s of spec.section_script) {
    if (t >= s.start && t < s.end) return s;
  }
  return null;
}

function lerpBiomeWeights(a: BiomeWeights, b: BiomeWeights, u: number): BiomeWeights {
  return {
    euphoric:    a.euphoric    + (b.euphoric    - a.euphoric)    * u,
    serene:      a.serene      + (b.serene      - a.serene)      * u,
    intense:     a.intense     + (b.intense     - a.intense)     * u,
    melancholic: a.melancholic + (b.melancholic - a.melancholic) * u,
  };
}

function biomeWeightsAt(spec: CompositionSpec, t: number): BiomeWeights {
  const tl = spec.emotion_timeline;
  if (tl.length === 0) {
    return { euphoric: 0, serene: 1, intense: 0, melancholic: 0 };
  }
  if (t <= tl[0]!.t) return tl[0]!.biome_weights;
  if (t >= tl[tl.length - 1]!.t) return tl[tl.length - 1]!.biome_weights;
  // Binary search would be faster but linear is fine — emotion_timeline
  // is one row per 0.5s, ~600 rows for a 5min song.
  for (let i = 0; i < tl.length - 1; i++) {
    const a = tl[i]!;
    const b = tl[i + 1]!;
    if (t >= a.t && t < b.t) {
      const u = (t - a.t) / Math.max(1e-6, b.t - a.t);
      return lerpBiomeWeights(a.biome_weights, b.biome_weights, u);
    }
  }
  return tl[tl.length - 1]!.biome_weights;
}

/// Interpolate V&M (saturation, brightness) between adjacent emotion
/// samples so the renderer doesn't step at the 0.5s emotion grid.
function vmPaletteAt(spec: CompositionSpec, t: number): { sat: number; bri: number } {
  const tl = spec.emotion_timeline;
  if (tl.length === 0) return { sat: 0.7, bri: 0.9 };
  if (t <= tl[0]!.t) return { sat: tl[0]!.vm_saturation, bri: tl[0]!.vm_brightness };
  if (t >= tl[tl.length - 1]!.t) {
    const last = tl[tl.length - 1]!;
    return { sat: last.vm_saturation, bri: last.vm_brightness };
  }
  for (let i = 0; i < tl.length - 1; i++) {
    const a = tl[i]!;
    const b = tl[i + 1]!;
    if (t >= a.t && t < b.t) {
      const u = (t - a.t) / Math.max(1e-6, b.t - a.t);
      return {
        sat: a.vm_saturation + (b.vm_saturation - a.vm_saturation) * u,
        bri: a.vm_brightness + (b.vm_brightness - a.vm_brightness) * u,
      };
    }
  }
  const last = tl[tl.length - 1]!;
  return { sat: last.vm_saturation, bri: last.vm_brightness };
}

function phraseAt(spec: CompositionSpec, t: number): PhraseDirective | null {
  for (const p of spec.phrase_track) {
    if (t >= p.t_start && t <= p.t_end) return p;
  }
  return null;
}

const ZERO_BANDS: number[] = [0, 0, 0, 0, 0, 0, 0, 0];

function audioFrameAt(spec: CompositionSpec, t: number): import("../types.js").AudioFrame {
  const ft = spec.frames_track;
  const fallback = {
    centroid: 0.5,
    harmonicRatio: 0.5,
    chromaStrength: 0.0,
    rolloff: 0.5,
    zcr: 0.3,
    spectralContrast: 0.5,
    pitchHeight: 0,
    pitchClass: -1,
    chromaCenterX: 0,
    chromaCenterY: 0,
    melBands: ZERO_BANDS,
    pitchDirection: 0,
    rms: 0,
    mfccWarm: 0,
    spectralFlux: 0,
    onsetStrengthEnv: 0,
  };
  if (!ft || ft.count === 0) return fallback;

  const idxF = Math.max(0, Math.min(ft.count - 1, t / Math.max(1e-6, ft.interval)));
  const i0 = Math.floor(idxF);
  const i1 = Math.min(ft.count - 1, i0 + 1);
  const u = idxF - i0;

  const lerp = (arr: number[], a: number, b: number) =>
    (arr[a] ?? 0) + ((arr[b] ?? arr[a] ?? 0) - (arr[a] ?? 0)) * u;
  const lerpOpt = (arr: number[] | undefined, def: number) =>
    arr && arr.length > 0
      ? (arr[i0] ?? def) + ((arr[i1] ?? arr[i0] ?? def) - (arr[i0] ?? def)) * u
      : def;

  // Pitch class: don't interpolate (categorical). Use nearest.
  const pcArr = ft.pitch_class || [];
  const pc = (u < 0.5 ? pcArr[i0] : pcArr[i1]) ?? -1;
  const pitchHeight = pc >= 0 ? (pc / 11) * 2 - 1 : 0;

  // v4 mel bands: per-band linear interp. Fall back to all-zero for
  // v3 specs (renderer code reads ctx.audio.melBands[k] safely).
  let melBands = ZERO_BANDS;
  const mb = ft.mel_bands;
  if (mb && mb.length > 0) {
    const row0 = mb[i0] || ZERO_BANDS;
    const row1 = mb[i1] || row0;
    const out = new Array<number>(8);
    for (let k = 0; k < 8; k++) {
      const a = row0[k] ?? 0;
      const b = row1[k] ?? a;
      out[k] = a + (b - a) * u;
    }
    melBands = out;
  }

  return {
    centroid:         lerp(ft.centroid_norm, i0, i1),
    harmonicRatio:    lerp(ft.harmonic_ratio, i0, i1),
    chromaStrength:   lerp(ft.chroma_strength, i0, i1),
    rolloff:          lerp(ft.rolloff, i0, i1),
    zcr:              lerp(ft.zcr, i0, i1),
    spectralContrast: lerp(ft.spectral_contrast, i0, i1),
    pitchHeight,
    pitchClass:       pc,
    chromaCenterX:    lerpOpt(ft.chroma_center_x, 0),
    chromaCenterY:    lerpOpt(ft.chroma_center_y, 0),
    melBands,
    pitchDirection:   lerpOpt(ft.pitch_direction, 0),
    rms:              lerpOpt(ft.rms, 0),
    mfccWarm:         lerpOpt(ft.mfcc_warm, 0),
    spectralFlux:     lerpOpt(ft.spectral_flux, 0),
    onsetStrengthEnv: lerpOpt(ft.onset_strength_env, 0),
  };
}

const BEAT_HALF_LIFE = 0.150; // s
const ONSET_HALF_LIFE = 0.080;
const DROP_DURATION = 1.30;

function pulseFromMostRecent(events: { t: number }[], t: number, halfLife: number): number {
  // Find the most recent event with e.t <= t. Linear scan again — fine.
  let last: { t: number } | null = null;
  for (const e of events) {
    if (e.t > t) break;
    last = e;
  }
  if (!last) return 0;
  const dt = t - last.t;
  if (dt < 0) return 0;
  return Math.pow(0.5, dt / halfLife);
}

function dropImpulseAt(spec: CompositionSpec, t: number): number {
  let last: number | null = null;
  for (const tr of spec.drop_triggers) {
    if (tr.t > t) break;
    last = tr.t;
  }
  if (last === null) return 0;
  const dt = t - last;
  if (dt < 0 || dt > DROP_DURATION) return 0;
  // Crest 0–0.35s → flash 0.35–0.60s → settle 0.60–1.30s. Bell shape.
  return Math.exp(-Math.pow((dt - 0.45) / 0.30, 2));
}

// Build accumulator state (module-level so it persists across frames).
// Goes 0→1 over "ascending" sections, snaps to 0 with easeOutCubic over
// 1.0s at drops, holds near 1.0 in climax/peak sections, decays back
// to 0 through descending/outro sections.
let _buildIntensity = 0;
let _buildLastT = 0;

const BUILD_SMOOTH_TAU = 0.30; // s — one-pole low-pass on the target
const BUILD_DROP_RELEASE = 1.00; // s — duration of post-drop easeOutCubic

function buildIntensityAt(spec: CompositionSpec, t: number, section: SectionDirective | null, sectionProgress: number): number {
  // Target value based on section semantics.
  let target = 0;
  if (section) {
    const ep = (section.energy_profile || "").toLowerCase();
    const lbl = (section.label || "").toLowerCase();
    if (ep === "ascending" || /build|riser|buildup|pre[\-_ ]?drop/.test(lbl)) {
      // Climb across the section. easeInQuad so the climb feels like
      // pressure mounting toward the end, not linear.
      target = Math.pow(sectionProgress, 1.6);
    } else if (ep === "peak" || /climax|drop|chorus[_ ]?peak/.test(lbl)) {
      // Hold near 1.0 with a subtle breath so it doesn't feel frozen.
      target = 0.92 + Math.sin(t * 2.0 * Math.PI * 0.4) * 0.06;
    } else if (ep === "descending" || /outro|fade|tail/.test(lbl)) {
      // Linear decay across the section.
      target = Math.max(0, 1.0 - sectionProgress);
    } else {
      target = 0.2; // baseline ambient build for chorus/verse, not zero
    }
  }

  // Drop release: find most recent drop within BUILD_DROP_RELEASE seconds.
  // Multiply the target by easeOutCubic(1-u) where u = age/release window.
  let dropAge: number | null = null;
  for (const dr of spec.drop_triggers) {
    if (dr.t > t) break;
    const age = t - dr.t;
    if (age >= 0 && age <= BUILD_DROP_RELEASE) {
      dropAge = age;
    }
  }
  if (dropAge !== null) {
    const u = dropAge / BUILD_DROP_RELEASE;
    const ease = 1.0 - Math.pow(1.0 - u, 3); // easeOutCubic 0→1
    target *= 1.0 - ease;
  }

  // One-pole low-pass so transitions don't step.
  const dt = Math.max(1e-3, t - _buildLastT);
  _buildLastT = t;
  const alpha = Math.min(1.0, dt / BUILD_SMOOTH_TAU);
  _buildIntensity += (target - _buildIntensity) * alpha;
  return Math.max(0, Math.min(1, _buildIntensity));
}

function buildContext(spec: CompositionSpec, t: number): FrameContext {
  const section = sectionAt(spec, t);
  const sectionProgress = section
    ? Math.min(1, Math.max(0, (t - section.start) / Math.max(1e-6, section.end - section.start)))
    : 0;
  const phrase = phraseAt(spec, t);
  const phraseProgress = phrase
    ? Math.min(1, Math.max(0, (t - phrase.t_start) / Math.max(1e-6, phrase.t_end - phrase.t_start)))
    : 0;
  // Phrase pulse: spike at t_start, decay with τ ≈ 0.5s so it's gone
  // by ~1.5s into the phrase but visible at the boundary.
  let phrasePulse = 0;
  if (phrase) {
    const dt = t - phrase.t_start;
    if (dt >= 0 && dt < 2.0) {
      phrasePulse = Math.exp(-dt / 0.5);
    }
  }
  const downbeats = spec.beat_track.filter((b) => b.downbeat);
  const vm = vmPaletteAt(spec, t);
  return {
    t,
    progress: spec.duration_seconds > 0 ? t / spec.duration_seconds : 0,
    section,
    sectionProgress,
    phrase,
    phraseProgress,
    phrasePulse,
    biomeWeights: biomeWeightsAt(spec, t),
    vmSaturation: vm.sat,
    vmBrightness: vm.bri,
    audio: audioFrameAt(spec, t),
    beatPulse: pulseFromMostRecent(spec.beat_track, t, BEAT_HALF_LIFE),
    downbeatPulse: pulseFromMostRecent(downbeats, t, BEAT_HALF_LIFE),
    onsetPulse: pulseFromMostRecent(spec.onset_track, t, ONSET_HALF_LIFE),
    dropImpulse: dropImpulseAt(spec, t),
    buildIntensity: buildIntensityAt(spec, t, section, sectionProgress),
  };
}

function applyCamera(scene: Scene, ctx: FrameContext): void {
  if (!ctx.section) return;
  const cam = scene.camera as THREE.PerspectiveCamera;
  const sp = ctx.sectionProgress;
  switch (ctx.section.camera) {
    case "wide_static":
      cam.position.set(0, 0, 5);
      break;
    case "slow_dolly_in":
      cam.position.set(0, 0, 5 - sp * 1.0);
      break;
    case "rapid_zoom":
      cam.position.set(0, 0, 5 - sp * 2.5);
      break;
    case "explosive_zoom_out":
      cam.position.set(0, 0, 3 + sp * 4.0);
      break;
    case "high_orbit":
      cam.position.set(Math.sin(ctx.t * 0.25) * 1.5, 0.4, 4);
      break;
    case "off_axis_rotate":
      cam.position.set(Math.sin(sp * Math.PI) * 1.2, 0.2, 4);
      cam.rotation.z = Math.sin(ctx.t * 0.4) * 0.06;
      break;
    case "wide_pullback":
      cam.position.set(0, 0, 5 + sp * 1.5);
      break;
    case "slow_fade":
      cam.position.set(0, 0, 5);
      break;
  }
  cam.lookAt(0, 0, 0);
  cam.updateProjectionMatrix();
}

window.__loadSpec = (s: CompositionSpec) => {
  spec = s;
  // Pre-warm scene 0 so the first frame doesn't pay the GL upload cost.
  if (s.section_script.length > 0) {
    makeSceneFor(s, s.section_script[0]!.start);
  }
};

window.__renderFrameAt = (t: number) => {
  if (!spec) throw new Error("no spec loaded");
  const scene = makeSceneFor(spec, t);
  const ctx = buildContext(spec, t);
  applyCamera(scene, ctx);
  scene.render(spec, ctx);

  // Per-frame post-FX modulation. The lens responds continuously to
  // music, not just at section boundaries. Two drivers stack:
  //   - direct timbre/section signals (hue_distance, tension, zcr, rms)
  //   - buildIntensity arc (climbs through build-ups, releases at drops)
  const hueDistance = ctx.section?.hue_distance ?? 0.3;
  const tension = ctx.section?.tension ?? 0.4;
  const rms = ctx.audio.rms;
  const build = ctx.buildIntensity;

  // Bloom: per-biome base × (1 + rms loudness × 0.8) × (1 + build × 0.8).
  // Loud + build-up = double-multiplied glow; quiet outro = ducked.
  const sceneName = currentSceneName ?? "serene_dawn";
  const baseBloom = BIOME_BLOOM_INTENSITY[sceneName] ?? 1.0;
  const grade = BIOME_GRADE[sceneName];
  bloomEffect.intensity = baseBloom * (1.0 + rms * 2.2) * (1.0 + build * 1.6);

  // Chromatic aberration: section tension × buildIntensity multiplier.
  // Stays subtle in calm sections; reaches 1.5× hue_distance offset
  // by the end of a build.
  const caOffset = 0.0006 + hueDistance * 0.018 * (1.0 + build * 0.5);
  chromaticAberrationEffect.offset!.set(caOffset, 0);

  // Vignette: tightens with tension AND build — frame visibly "closes
  // in" during build-ups.
  vignetteEffect.darkness = 0.30 + tension * 0.40 + build * 0.35;
  vignetteEffect.offset = 0.30 - build * 0.05;

  // Grain: ZCR drives base opacity. RMS attenuates (loud passages
  // wash grain out under bloom; quiet ones let it through).
  noiseEffect.blendMode.opacity.value = (0.04 + ctx.audio.zcr * 0.16) * (1.0 - rms * 0.5);

  // Drop signature: when dropImpulse is active, the post-FX channels
  // amplify briefly so the drop reads as a recognizable visual event,
  // not just a soft scene-internal pulse. Per-biome variation comes
  // from each biome's base bloom intensity / grade values; the
  // multipliers below stack on top universally.
  const drop = ctx.dropImpulse;
  if (drop > 0) {
    bloomEffect.intensity *= 1.0 + drop * 2.5;
    vignetteEffect.darkness += drop * 0.25;
    chromaticAberrationEffect.offset!.set(caOffset * (1.0 + drop * 2.5), 0);
    noiseEffect.blendMode.opacity.value *= 1.0 + drop * 1.0;
  }

  // Contrast push on build + drop. Highest-yield post-FX addition for
  // climaxes — frames feel "harder" rather than just brighter.
  brightnessContrastEffect.contrast = (grade?.con ?? 0) + build * 0.12 + drop * 0.20;

  // Phrase boundary multi-channel event (Krumhansl 1996). The previous
  // implementation only lit a luminance pulse inside each scene shader;
  // here we layer post-FX channels so the boundary lands as a "moment,"
  // not a tint: bloom flicker, saturation pulse, slight FOV nudge.
  const phr = ctx.phrasePulse;
  if (phr > 0.05) {
    bloomEffect.intensity *= 1.0 + phr * 0.30;
    hueSaturationEffect.saturation += phr * 0.28;
  }

  // Section transition palette shift: in the first 1.5s after a new
  // section starts, lift saturation + bloom so the viewer registers
  // "we're somewhere new" beyond just the camera move.
  if (ctx.section) {
    const sectAge = ctx.t - ctx.section.start;
    if (sectAge >= 0 && sectAge < 1.5) {
      const w = 1.0 - sectAge / 1.5;
      bloomEffect.intensity *= 1.0 + w * 0.25;
      hueSaturationEffect.saturation += w * 0.08;
    }
  }

  // Hue rotation per frame: combine biome base grade + chord-driven
  // chroma_center rotation (±10° max) + mfcc-driven warmth shift (±8%).
  // chroma_center direction comes from the 12-bin chord centroid (Itoh-
  // safe: chord shape, not per-note rainbow). mfcc_warm shifts toward
  // warm (strings/acoustic) or cool (synth/digital) instrumental color.
  const chromaAngle = Math.atan2(ctx.audio.chromaCenterY, ctx.audio.chromaCenterX);
  const chromaStrength = Math.hypot(ctx.audio.chromaCenterX, ctx.audio.chromaCenterY);
  // Map angle [-π, π] to ±10° = ±π/18 rad, scaled by tonality.
  const chromaHueShift = (chromaAngle / Math.PI) * 0.175 * Math.min(1, chromaStrength * 2.0);
  // mfcc_warm [-1, +1] → ±0.14 rad (~8°). Negative MFCC[1] = darker tilt
  // (cool); positive = brighter (warm) — but renderers report MFCC[1]
  // as already normalized, so the sign just shifts hue accordingly.
  const mfccHueShift = ctx.audio.mfccWarm * 0.14;
  hueSaturationEffect.hue = (grade?.hue ?? 0) + chromaHueShift + mfccHueShift;
  // Saturation also tracks chroma_center magnitude: tonal frames lift,
  // atonal/noisy frames keep biome baseline.
  hueSaturationEffect.saturation = (grade?.sat ?? 0.10) + chromaStrength * 0.15;

  // Camera FOV push-in: loud + build both narrow the lens toward the
  // subject. Capped at -14° from base 50° at extreme rms+build.
  const cam = scene.camera as THREE.PerspectiveCamera;
  if (cam.isPerspectiveCamera) {
    cam.fov = 50 - rms * 7.0 - build * 7.0;
    cam.updateProjectionMatrix();
  }

  // composer drives the RenderPass + post-FX passes. Final pass writes
  // to canvas; Playwright reads back via screenshot().
  composer.render();
};

window.__ready = true;

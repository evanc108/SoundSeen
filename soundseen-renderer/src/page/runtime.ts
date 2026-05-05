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
  };
  if (!ft || ft.count === 0) return fallback;

  const idxF = Math.max(0, Math.min(ft.count - 1, t / Math.max(1e-6, ft.interval)));
  const i0 = Math.floor(idxF);
  const i1 = Math.min(ft.count - 1, i0 + 1);
  const u = idxF - i0;

  const lerp = (arr: number[], a: number, b: number) =>
    (arr[a] ?? 0) + ((arr[b] ?? arr[a] ?? 0) - (arr[a] ?? 0)) * u;

  // Pitch class: don't interpolate (categorical). Use nearest.
  const pcArr = ft.pitch_class || [];
  const pc = (u < 0.5 ? pcArr[i0] : pcArr[i1]) ?? -1;
  const pitchHeight = pc >= 0 ? (pc / 11) * 2 - 1 : 0;

  return {
    centroid:         lerp(ft.centroid_norm, i0, i1),
    harmonicRatio:    lerp(ft.harmonic_ratio, i0, i1),
    chromaStrength:   lerp(ft.chroma_strength, i0, i1),
    rolloff:          lerp(ft.rolloff, i0, i1),
    zcr:              lerp(ft.zcr, i0, i1),
    spectralContrast: lerp(ft.spectral_contrast, i0, i1),
    pitchHeight,
    pitchClass:       pc,
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
  renderer.render(scene.object3D, scene.camera);
};

window.__ready = true;

// Synthetic-spec smoke test. Generates a minimal CompositionSpec
// in-memory and renders a 5-second test MP4 — useful for validating
// the full pipeline (Playwright + WebGL + FFmpeg + audio mux) without
// hitting the real backend.
//
// Usage:
//   npm run sample -- <audio.mp3> [out.mp4]
//
// If no audio file is provided, defaults to ../soundseen-backend/test.mp3
// (the bundled test track in the backend tree).

import { promises as fs } from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { renderComposition } from "./render.js";
import type { CompositionSpec } from "./types.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function syntheticSpec(durationSeconds: number): CompositionSpec {
  const beats = [];
  const phrases = [];
  const onsets = [];
  // 120 BPM, 4/4 — a beat every 0.5s, downbeat every 2s.
  for (let i = 0; i < Math.floor(durationSeconds * 2); i++) {
    const t = i * 0.5;
    const downbeat = i % 4 === 0;
    beats.push({
      t,
      downbeat,
      intensity: 0.6 + (downbeat ? 0.2 : 0),
      sharpness: 0.55,
      bass_intensity: downbeat ? 0.5 : 0.25,
    });
    onsets.push({
      t: t + 0.05,
      intensity: 0.3,
      sharpness: 0.6,
      attack_strength: 0.4,
      attack_slope: 0.7,
    });
  }
  const downbeats = beats.filter((b) => b.downbeat);
  for (let i = 0; i < downbeats.length; i += 4) {
    const first = downbeats[i]!;
    const last = downbeats[Math.min(i + 3, downbeats.length - 1)]!;
    phrases.push({
      t_start: first.t,
      t_end: last.t,
      phrase_index: i / 4,
      bar_count: Math.min(4, downbeats.length - i),
    });
  }

  // Emotion timeline: 0.5s grid, drifts from low-A serene up to
  // high-A euphoric over the duration, so the renderer exercises the
  // V&M coefficients across a meaningful range.
  const emotion: CompositionSpec["emotion_timeline"] = [];
  const samples = Math.ceil(durationSeconds / 0.5);
  for (let i = 0; i < samples; i++) {
    const u = samples > 1 ? i / (samples - 1) : 0;
    const valence = 0.7;
    const arousal = 0.25 + u * 0.5; // 0.25 → 0.75
    const sat = 0.55 + 0.45 * arousal;
    const bri = 0.9 - 0.15 * arousal + 0.1 * valence;
    emotion.push({
      t: i * 0.5,
      valence,
      arousal,
      biome_weights: serenfBlendBiomeWeights(valence, arousal),
      vm_saturation: sat,
      vm_brightness: bri,
    });
  }

  return {
    spec_version: 2,
    preset: "default",
    song_id: "sample-synthetic",
    duration_seconds: durationSeconds,
    bpm: 120,
    emotion_timeline: emotion,
    section_script: [
      {
        start: 0,
        end: durationSeconds,
        label: "verse",
        energy_profile: "moderate",
        scene: "serene_dawn",
        biome_weights: { euphoric: 0.2, serene: 0.6, intense: 0.1, melancholic: 0.1 },
        camera: "slow_dolly_in",
        saturation: 0.85,
        brightness: 0.95,
        tension: 0.25,
        angularity: 0.30,
        hue_distance: 0.20,
      },
    ],
    beat_track: beats,
    phrase_track: phrases,
    onset_track: onsets,
    drop_triggers: [],
  };
}

function serenfBlendBiomeWeights(v: number, a: number): { euphoric: number; serene: number; intense: number; melancholic: number } {
  // Inline copy of the Python softmax so the sample doesn't require
  // hitting the backend. tau=0.25, four quadrant centers.
  const centers: Record<string, [number, number]> = {
    euphoric:    [0.75, 0.75],
    serene:      [0.75, 0.25],
    intense:     [0.25, 0.75],
    melancholic: [0.25, 0.25],
  };
  const tau = 0.25;
  const logits: Record<string, number> = {};
  for (const [name, [cv, ca]] of Object.entries(centers)) {
    const dv = v - cv;
    const da = a - ca;
    logits[name] = -(dv * dv + da * da) / tau;
  }
  const max = Math.max(...Object.values(logits));
  const exps: Record<string, number> = {};
  let sum = 0;
  for (const [name, l] of Object.entries(logits)) {
    exps[name] = Math.exp(l - max);
    sum += exps[name]!;
  }
  return {
    euphoric:    exps.euphoric!    / sum,
    serene:      exps.serene!      / sum,
    intense:     exps.intense!     / sum,
    melancholic: exps.melancholic! / sum,
  };
}

async function main() {
  const audioArg = process.argv[2];
  const outArg = process.argv[3] ?? "sample-out.mp4";
  const durationSeconds = 5;

  const defaultAudio = path.resolve(__dirname, "..", "..", "soundseen-backend", "test.mp3");
  const audioPath = audioArg ?? defaultAudio;

  try {
    await fs.access(audioPath);
  } catch {
    console.error(`audio file not found: ${audioPath}`);
    console.error(`usage: npm run sample -- <audio.mp3> [out.mp4]`);
    process.exit(2);
  }

  const spec = syntheticSpec(durationSeconds);
  const tmpSpec = path.join(os.tmpdir(), `soundseen-sample-${Date.now()}.json`);
  await fs.writeFile(tmpSpec, JSON.stringify(spec, null, 2));

  console.log(`rendering ${durationSeconds}s sample → ${outArg}`);
  console.log(`  audio:  ${audioPath}`);
  console.log(`  spec:   ${tmpSpec}`);

  const start = Date.now();
  await renderComposition({
    specPath: tmpSpec,
    audioPath,
    outputPath: path.resolve(outArg),
    maxSeconds: durationSeconds,
  });
  const elapsed = (Date.now() - start) / 1000;
  console.log(`\ndone in ${elapsed.toFixed(1)}s. open ${outArg} to preview.`);

  await fs.unlink(tmpSpec).catch(() => undefined);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

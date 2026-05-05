// Synthetic-spec smoke test. Generates a minimal CompositionSpec
// in-memory and renders a 5-second test MP4 — useful for validating
// the full pipeline (Playwright + WebGL + FFmpeg + audio mux) without
// hitting the real backend.
//
// Usage:
//   npm run sample -- [--scene <name>] [--audio <path>] [--out <path>]
//   npm run sample -- --scene euphoric_bloom
//
// Scenes: serene_dawn (default) | euphoric_bloom | intense_storm | melancholic_rain.
// Audio defaults to ../soundseen-backend/test.mp3.

import { promises as fs } from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { renderComposition } from "./render.js";
import type { CompositionSpec } from "./types.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

type SceneName = CompositionSpec["section_script"][number]["scene"];

const BIOME_PROFILE: Record<SceneName, { v: number; a: number; tension: number; angularity: number }> = {
  serene_dawn:      { v: 0.75, a: 0.30, tension: 0.20, angularity: 0.30 },
  euphoric_bloom:   { v: 0.78, a: 0.78, tension: 0.40, angularity: 0.30 },
  intense_storm:    { v: 0.22, a: 0.82, tension: 0.85, angularity: 0.78 },
  melancholic_rain: { v: 0.22, a: 0.22, tension: 0.30, angularity: 0.25 },
};

function syntheticSpec(durationSeconds: number, scene: SceneName): CompositionSpec {
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
    // Alternate two synthetic instruments: a snare (sharp) and a piano
    // (soft) so the emitter's ADSR vocabulary is visibly exercised.
    const isSnare = i % 2 === 0;
    onsets.push({
      t: t + 0.05,
      intensity: isSnare ? 0.55 : 0.40,
      sharpness: isSnare ? 0.85 : 0.45,
      attack_strength: isSnare ? 0.7 : 0.4,
      attack_slope: isSnare ? 0.90 : 0.30,
      attack_time_ms: isSnare ? 5 : 35,
      decay_time_ms:  isSnare ? 60 : 220,
      sustain_level:  isSnare ? 0.10 : 0.55,
      // Synthetic pitch: piano onsets cycle through pitch classes,
      // snare hits stay atonal.
      pitch_class: isSnare ? -1 : (i * 5) % 12,
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

  // Emotion timeline: 0.5s grid, V/A held at the biome's profile so
  // the renderer's V&M coefficients exercise the right range for the
  // chosen scene. (Real songs sweep through; this is a smoke test.)
  const profile = BIOME_PROFILE[scene];
  const valence = profile.v;
  const arousal = profile.a;
  const emotion: CompositionSpec["emotion_timeline"] = [];
  const samples = Math.ceil(durationSeconds / 0.5);
  for (let i = 0; i < samples; i++) {
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

  // Drop trigger at midpoint so each scene gets to show its drop response.
  const dropT = durationSeconds / 2;

  return {
    spec_version: 3,
    preset: "default",
    song_id: "sample-synthetic",
    duration_seconds: durationSeconds,
    bpm: 120,
    emotion_timeline: emotion,
    section_script: [
      {
        start: 0,
        end: durationSeconds,
        label: "chorus",
        energy_profile: "high",
        scene,
        biome_weights: serenfBlendBiomeWeights(valence, arousal),
        camera: "high_orbit",
        saturation: (0.55 + 0.45 * arousal) * 1.10, // chorus multiplier
        brightness: (0.9 - 0.15 * arousal + 0.1 * valence) * 1.05,
        tension: profile.tension,
        angularity: profile.angularity,
        hue_distance: profile.tension * 0.7 + arousal * 0.2,
        // Synthetic mode: euphoric/serene → major, intense/melancholic → minor.
        mode: valence > 0.5 ? "major" : "minor",
        mode_strength: 0.6,
      },
    ],
    beat_track: beats,
    phrase_track: phrases,
    onset_track: onsets,
    drop_triggers: [{ t: dropT, type: "section" }],
    // Synthetic frames_track: drift centroid up over time, hold harmonic
    // ratio at the profile's angularity-derived value, etc. Just enough
    // to exercise the renderer's per-frame interpolation.
    frames_track: {
      interval: 0.10,
      count: Math.ceil(durationSeconds / 0.10),
      centroid_norm:     Array.from({ length: Math.ceil(durationSeconds / 0.10) },
                                    (_, i) => 0.3 + (i / Math.max(1, durationSeconds * 10 - 1)) * 0.4),
      harmonic_ratio:    Array.from({ length: Math.ceil(durationSeconds / 0.10) },
                                    () => 1 - profile.angularity),
      chroma_strength:   Array.from({ length: Math.ceil(durationSeconds / 0.10) },
                                    () => valence > 0.5 ? 0.65 : 0.35),
      rolloff:           Array.from({ length: Math.ceil(durationSeconds / 0.10) },
                                    () => 0.5),
      zcr:               Array.from({ length: Math.ceil(durationSeconds / 0.10) },
                                    () => profile.angularity * 0.6),
      spectral_contrast: Array.from({ length: Math.ceil(durationSeconds / 0.10) },
                                    () => 0.5),
      pitch_class:       Array.from({ length: Math.ceil(durationSeconds / 0.10) },
                                    (_, i) => valence > 0.5 ? (i * 7) % 12 : -1),
    },
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

function parseArgs(argv: string[]): { scene: SceneName; audio?: string; out?: string } {
  let scene: SceneName = "serene_dawn";
  let audio: string | undefined;
  let out: string | undefined;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--scene" && argv[i + 1]) {
      const next = argv[i + 1] as SceneName;
      if (next in BIOME_PROFILE) scene = next;
      i++;
    } else if (a === "--audio" && argv[i + 1]) {
      audio = argv[i + 1]!;
      i++;
    } else if (a === "--out" && argv[i + 1]) {
      out = argv[i + 1]!;
      i++;
    }
  }
  return { scene, audio, out };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const durationSeconds = 5;

  const defaultAudio = path.resolve(__dirname, "..", "..", "soundseen-backend", "test.mp3");
  const audioPath = args.audio ?? defaultAudio;
  const outArg = args.out ?? `sample-${args.scene}.mp4`;

  try {
    await fs.access(audioPath);
  } catch {
    console.error(`audio file not found: ${audioPath}`);
    console.error(`usage: npm run sample -- <audio.mp3> [out.mp4]`);
    process.exit(2);
  }

  const spec = syntheticSpec(durationSeconds, args.scene);
  const tmpSpec = path.join(os.tmpdir(), `soundseen-sample-${Date.now()}.json`);
  await fs.writeFile(tmpSpec, JSON.stringify(spec, null, 2));

  console.log(`rendering ${durationSeconds}s sample of ${args.scene} → ${outArg}`);
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

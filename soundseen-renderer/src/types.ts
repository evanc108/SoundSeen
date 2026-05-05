// CompositionSpec types — mirrors the Python schema in
// soundseen-backend/pipeline/composition.py. Keep in sync; bump
// SPEC_VERSION on both sides whenever the layout changes.
//
// Currently in sync with backend SPEC_VERSION = 3.

export const SPEC_VERSION = 3;

export type BiomeName = "euphoric" | "serene" | "intense" | "melancholic";
export type SceneName =
  | "euphoric_bloom"
  | "serene_dawn"
  | "intense_storm"
  | "melancholic_rain";
export type CameraMove =
  | "wide_static"
  | "slow_dolly_in"
  | "rapid_zoom"
  | "explosive_zoom_out"
  | "high_orbit"
  | "off_axis_rotate"
  | "wide_pullback"
  | "slow_fade";

export interface BiomeWeights {
  euphoric: number;
  serene: number;
  intense: number;
  melancholic: number;
}

export interface EmotionSample {
  t: number;
  valence: number;
  arousal: number;
  biome_weights: BiomeWeights;
  /// Continuous V&M-derived (saturation, brightness) in [0.5, 1.0].
  /// Renderer multiplies these onto biome anchor colors.
  /// (Valdez & Mehrabian 1994 JEP:General — β=+0.60 saturation→arousal,
  /// β=−0.31 brightness→arousal, β=+0.69 brightness→pleasure scaled.)
  vm_saturation: number;
  vm_brightness: number;
}

export interface SectionDirective {
  start: number;
  end: number;
  label: string;
  energy_profile: string;
  scene: SceneName;
  biome_weights: BiomeWeights;
  camera: CameraMove;
  /// V&M baseline × section-intent multiplier.
  saturation: number;
  brightness: number;
  /// Tension scalar [0, 1]. Compounds flux + (1−harmonic_ratio)
  /// + (1−spectral_contrast). Drives hue_distance lever.
  tension: number;
  /// Bouba/Kiki angularity scalar [0, 1] — Adeli et al. 2014,
  /// Margiotoudi & Pulvermüller 2020.
  /// 0 = rounded/organic, 1 = angular/crystalline. Renderer biases
  /// shape vocabulary on this.
  angularity: number;
  /// Schloss & Palmer 2011 harmony lever in [0, 1].
  /// 0 = analogous (rest/release), 1 = complementary (tension).
  hue_distance: number;
  /// v3 — Krumhansl-Kessler mode for the section. Renderer biases
  /// hue warm for major, cool for minor (Hevner 1937, Palmer 2013).
  mode: "major" | "minor";
  /// 0..1 — how confidently the K-K templates picked this mode.
  /// Renderer scales the warm/cool bias by this so weakly-tonal
  /// passages stay closer to neutral.
  mode_strength: number;
}

export interface BeatDirective {
  t: number;
  downbeat: boolean;
  intensity: number;
  sharpness: number;
  bass_intensity: number;
}

export interface PhraseDirective {
  /// Phrase-level tier — Krumhansl 1996, Palmer & Krumhansl 1987.
  /// Listener tension/segmentation responses concentrate here, not
  /// at beat or section level. Renderer uses phrase boundaries for
  /// camera-arc completion, palette rotation, particle population
  /// turnover.
  t_start: number;
  t_end: number;
  phrase_index: number;
  bar_count: number;
}

export interface OnsetDirective {
  t: number;
  intensity: number;
  sharpness: number;
  attack_strength: number;
  /// Steep slope = kiki/sharp; soft slope = bouba/round.
  attack_slope: number;
  /// v3 — full ADSR envelope. Renderer's per-onset particle birth
  /// envelope mirrors these times so a snare's particle reads as
  /// snappy and a piano's particle reads as ringing.
  attack_time_ms: number;
  decay_time_ms: number;
  sustain_level: number;
  /// v3 — dominant pitch class (0..11) at the onset, derived from
  /// chroma vector. -1 if atonal. Used for vertical placement
  /// (Pratt 1930) and inverse size (Walker 2010).
  pitch_class: number;
}

export interface DropTrigger {
  t: number;
  type: "section" | "heuristic";
}

export interface FramesTrack {
  /// Sample interval in seconds (renderer interpolates between samples).
  interval: number;
  count: number;
  /// 0..1 normalized centroid (per-track p5/p95 mapped). Marks 1989 →
  /// visual luminance.
  centroid_norm: number[];
  /// 0..1 — high = tonal/sustained, low = percussive/noisy.
  /// Bouba/Kiki shape vocabulary per-frame.
  harmonic_ratio: number[];
  /// 0..1 — tonality confidence. Itoh 2017 — saturation lock-in
  /// factor (high = vivid, low = washed).
  chroma_strength: number[];
  /// 0..1 — high-frequency cutoff. Sky-ceiling proxy.
  rolloff: number[];
  /// 0..1 — sibilance / noise density. Drives grain.
  zcr: number[];
  /// 0..1 — peaky vs smeared spectrum. Drives edge crispness.
  spectral_contrast: number[];
  /// 0..11 dominant pitch class per sample, or -1 if atonal.
  pitch_class: number[];
}

export interface CompositionSpec {
  /// Schema version. Renderer must verify it understands the version
  /// before rendering — bumps invalidate cached MP4s.
  spec_version: number;
  preset: string;
  song_id: string;
  duration_seconds: number;
  bpm: number;
  emotion_timeline: EmotionSample[];
  section_script: SectionDirective[];
  beat_track: BeatDirective[];
  /// New in v2 — Krumhansl phrase-level tier between beat and section.
  phrase_track: PhraseDirective[];
  onset_track: OnsetDirective[];
  drop_triggers: DropTrigger[];
  /// v3 — per-frame timbre stream sampled at ~10Hz. Renderer
  /// interpolates between samples per render frame to surface
  /// AudioFrame in FrameContext.
  frames_track: FramesTrack;
}

/// Per-frame timbre at the current render time, interpolated linearly
/// from the spec's frames_track. Surfaces every visual mapping the
/// MAPPING_RESEARCH.md doc cites.
export interface AudioFrame {
  /// 0..1 — Marks 1989 brightness mapping.
  centroid: number;
  /// 0..1 — dynamic Bouba/Kiki shape vocabulary; per-frame, not
  /// just per-section.
  harmonicRatio: number;
  /// 0..1 — Itoh 2017 saturation lock-in.
  chromaStrength: number;
  /// 0..1 — sky-ceiling height.
  rolloff: number;
  /// 0..1 — grain/sibilance density.
  zcr: number;
  /// 0..1 — edge crispness.
  spectralContrast: number;
  /// -1..+1 — pitch height for vertical placement (Pratt 1930).
  /// Computed from pitch_class as ((pc/11)*2 - 1) when pitch_class >= 0.
  /// 0 (neutral) when atonal.
  pitchHeight: number;
  /// 0..11 or -1 — raw pitch class; useful for color rotation.
  pitchClass: number;
}

/// Per-frame inputs the scene receives during render. All audio-reactive
/// values are pre-resolved by the runtime so scenes don't have to
/// search timelines themselves.
export interface FrameContext {
  /// Wall time within the song, seconds.
  t: number;
  /// 0..1, normalized over the whole song.
  progress: number;
  /// Currently-active section (or null in dead time at the very start).
  section: SectionDirective | null;
  /// 0..1 position within the current section.
  sectionProgress: number;
  /// Currently-active phrase (or null between phrases).
  phrase: PhraseDirective | null;
  /// 0..1 position within the current phrase. Krumhansl-tier visual
  /// events (camera arc completion, palette rotation) drive off this.
  phraseProgress: number;
  /// Smooth biome blend (linearly interpolated between adjacent emotion
  /// samples so the renderer doesn't stutter at 0.5s boundaries).
  biomeWeights: BiomeWeights;
  /// V&M continuous palette modulation, interpolated between adjacent
  /// emotion samples. Multiply onto scene anchor S/B.
  vmSaturation: number;
  vmBrightness: number;
  /// v3 — interpolated per-frame timbre. Drives every research-backed
  /// audio→visual mapping that operates below section-level resolution.
  audio: AudioFrame;
  /// 1.0 at the moment of a beat, decays exponentially toward 0
  /// (τ ≈ 0.35×IBI per Large & Jones 1999).
  beatPulse: number;
  /// 1.0 right after a downbeat, decays the same.
  downbeatPulse: number;
  /// 1.0 right after an onset, decays.
  onsetPulse: number;
  /// >0 during a 1.3s window after a drop trigger.
  dropImpulse: number;
}

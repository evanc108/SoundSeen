// CompositionSpec types — mirrors the Python schema in
// soundseen-backend/pipeline/composition.py. Keep in sync; bump
// SPEC_VERSION on both sides whenever the layout changes.

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
}

export interface SectionDirective {
  start: number;
  end: number;
  label: string;
  energy_profile: string;
  scene: SceneName;
  biome_weights: BiomeWeights;
  camera: CameraMove;
  saturation: number;
  brightness: number;
}

export interface BeatDirective {
  t: number;
  downbeat: boolean;
  intensity: number;
  sharpness: number;
  bass_intensity: number;
}

export interface OnsetDirective {
  t: number;
  intensity: number;
  sharpness: number;
  attack_strength: number;
  attack_slope: number;
}

export interface DropTrigger {
  t: number;
  type: "section" | "heuristic";
}

export interface CompositionSpec {
  spec_version: number;
  preset: string;
  song_id: string;
  duration_seconds: number;
  bpm: number;
  emotion_timeline: EmotionSample[];
  section_script: SectionDirective[];
  beat_track: BeatDirective[];
  onset_track: OnsetDirective[];
  drop_triggers: DropTrigger[];
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
  /// Smooth biome blend (linearly interpolated between adjacent emotion
  /// samples so the renderer doesn't stutter at 0.5s boundaries).
  biomeWeights: BiomeWeights;
  /// 1.0 at the moment of a beat, decays exponentially toward 0 (~150ms
  /// half-life). Same envelope as the iOS HapticVocabulary.
  beatPulse: number;
  /// 1.0 right after a downbeat, decays the same.
  downbeatPulse: number;
  /// 1.0 right after an onset, decays.
  onsetPulse: number;
  /// >0 during a 1.3s window after a drop trigger.
  dropImpulse: number;
}

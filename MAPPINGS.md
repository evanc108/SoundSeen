# SoundSeen — Audio → Visual Mapping Reference

Every visual parameter in the renderer is driven by a librosa-derived
audio feature surfaced through the CompositionSpec JSON contract. This
document is the comprehensive index: feature → consumer → magnitude.

For the empirical research backing the *choice* of mapping (Bouba/Kiki,
Schloss-Palmer, Spence loudness↔mass, etc.), see
`soundseen-backend/pipeline/MAPPING_RESEARCH.md`. This document is
about implementation — where each feature lives in code.

---

## 1. Pipeline overview

```
audio.mp3
  │
  └─ librosa: rms, centroid, rolloff, zcr, mfcc, chroma, mel_bands,
  │           spectral_flux, spectral_contrast, beat_track, onset_detect,
  │           onset_strength, harmonic_ratio
  │
  ├─ soundseen-backend/pipeline/spectral.py       (per-frame features)
  ├─ soundseen-backend/pipeline/rhythm.py         (beats, onsets, onset_env)
  ├─ soundseen-backend/pipeline/emotion.py        (Essentia + spectral V/A)
  └─ soundseen-backend/pipeline/structure.py      (section boundaries)
            │
            ▼
  soundseen-backend/pipeline/composition.py
      ├─ _build_frames_track   → per-frame timbre stream @ 10 Hz
      ├─ _build_section_script → V/A → biome, scene, palette
      ├─ _build_beat_track     → beat events
      ├─ _build_phrase_track   → 4-beat phrase boundaries
      ├─ _build_onset_track    → onset events with ADSR
      └─ _build_drop_triggers  → arousal+flux+energy threshold events
            │
            ▼
  CompositionSpec JSON (spec_version 5)
            │
            ▼
  soundseen-renderer/src/page/runtime.ts → audioFrameAt() interpolates
  to a FrameContext per render frame, passes to scene.render(spec, ctx).
```

---

## 2. Per-frame audio features (frames_track @ 10 Hz)

The renderer's `audioFrameAt(spec, t)` linearly interpolates between
10-Hz samples to produce an `AudioFrame` for the current render time.
All ranges are normalized to `[0, 1]` unless noted.

| Spec field | AudioFrame property | Librosa source | Range | Research anchor |
|---|---|---|---|---|
| `centroid_norm` | `ctx.audio.centroid` | `librosa.feature.spectral_centroid`, p5/p95 normalized per-track | 0..1 | Marks 1989 brightness |
| `harmonic_ratio` | `ctx.audio.harmonicRatio` | HPSS `harmonic / (harmonic + percussive)` | 0..1 | Bouba/Kiki shape vocabulary |
| `chroma_strength` | `ctx.audio.chromaStrength` | Chroma vector L2 norm | 0..1 | Itoh 2017 saturation lock-in |
| `rolloff` | `ctx.audio.rolloff` | `spectral_rolloff` normalized | 0..1 | Drives particle altitude ceiling |
| `zcr` | `ctx.audio.zcr` | `zero_crossing_rate` | 0..1 | Sibilance / grain density |
| `spectral_contrast` | `ctx.audio.spectralContrast` | `spectral_contrast` mean | 0..1 | Edge crispness (peaky vs smeared) |
| `pitch_class` | `ctx.audio.pitchClass` | chroma argmax | 0..11 or -1 | Pratt 1930 pitch class |
| (derived) | `ctx.audio.pitchHeight` | `((pc/11)*2 - 1)` when pc≥0, else 0 | -1..+1 | Pratt 1930 pitch→elevation |
| `chroma_center_x/y` | `ctx.audio.chromaCenterX/Y` | Σ cos(2πj/12)·chroma[j] | -1..+1 | Chord-centroid hue rotation |
| `mel_bands[8]` | `ctx.audio.melBands[8]` | Mel spectrogram 8-band aggregation | 0..1 per band | Sub_bass..ultra_high banded placement |
| `pitch_direction` | `ctx.audio.pitchDirection` | signed centroid trend over 0.5 s | -1..+1 | Rising/falling melody bias |
| `rms` | `ctx.audio.rms` | `librosa.feature.rms` normalized | 0..1 | Spence 2011 loudness↔visual mass |
| `mfcc_warm` | `ctx.audio.mfccWarm` | MFCC[1] (spectral tilt), one-pole LP @ τ=1.5 s | -1..+1 | Warm/cool spectral tilt |
| `spectral_flux` | `ctx.audio.spectralFlux` | onset-style spectral flux | 0..1 | v5 — transient density |
| `onset_strength_env` | `ctx.audio.onsetStrengthEnv` | `librosa.onset.onset_strength`, max-normalized | 0..1 | v5 — continuous transient pressure |

---

## 3. Event tracks

| Track | Source | Surfaces | Renderer consumer |
|---|---|---|---|
| `beat_track[]` | `librosa.beat.beat_track` | `BeatDirective{t, intensity, sharpness, is_downbeat}` | `ctx.beatPulse` (150 ms half-life decay), wave-plane beat-ring buffer, ribbon beat-modulated glow |
| `phrase_track[]` | Derived: every 4 beats | `PhraseDirective{t}` | `ctx.phrasePulse` (~1.5 s exp decay), phrase swoop/sweep camera, post-FX flash |
| `onset_track[]` | `librosa.onset.onset_detect` + per-onset attack/decay/sustain measured from rms envelope | `OnsetDirective{t, intensity, attack_slope, attack_time_ms, decay_time_ms, sustain_level, pitch_class}` | Per-onset particle bursts (N=2..7 by intensity+contrast), wave-plane splash buffer |
| `drop_triggers[]` | `arousal > 0.82 && flux > 0.75 && energy > 0.70` from composition.py | `DropTrigger{t}` | `ctx.dropImpulse` (1.30 s envelope), bloom/CA/vignette boost, lightning, camera shake |

---

## 4. Section-level features

Per-section directive in `section_script[]`, ~one entry per 5–30 s section:

| Field | Source | Range | Visual consumer |
|---|---|---|---|
| `scene` | `_dominant_biome(_biome_weights(v, a + audio_arousal_boost))` | enum | Which scene class renders this section |
| `biome_weights` | softmax over V/A → quadrant distance | 4-vector summing to 1 | Cross-biome blend (future) |
| `camera` | label-keyed (`verse`, `chorus`, `drop`, `bridge`, `outro`) | named move | runtime.applyCamera (8 named moves) |
| `saturation` | V&M(v,a) × section-intent multiplier | 0..1 | Per-scene `uSaturation` |
| `brightness` | V&M(v,a) × section-intent multiplier | 0..1 | Per-scene `uBrightness` |
| `tension` | `0.5·flux + 0.3·(1-hr) + 0.2·(1-sc)` | 0..1 | Vignette darkness + post-FX, wave-plane chop, camera roll |
| `angularity` | onset peak rate × `(1 − harmonic_ratio_avg)` | 0..1 | Onset particle size scale, future shape vocabulary |
| `hue_distance` | f(v, a, tension) — Schloss & Palmer 2011 | 0..1 | CA offset multiplier, hue shift magnitude |
| `mode` | Krumhansl-Kessler chroma correlation | major\|minor | Renderer mode-warm bias (red lift on major, blue on minor) |
| `mode_strength` | KK correlation confidence | 0..1 | Magnitude of mode_warm shift |
| `energy_profile` | structure heuristic | quiet\|moderate\|build\|peak | Drives `ctx.buildIntensity` arc (0..1 over the section) |

---

## 5. Per-biome visual mappings

### Melancholic Rain (low V, low A)

| Visual | Driver | Magnitude | File:line |
|---|---|---|---|
| Background sky gradient | section.brightness × ctx.vmBrightness | full | melancholic_rain.ts BG_FRAGMENT |
| Smoothstep horizon (puddle/sky blend) | constant smoothstep 0.32→0.48 | fixed | melancholic_rain.ts:~95 |
| Wave-plane beat ring amplitude | beat events → ring buffer | 0.32 × exp(-age/1.8) | melancholic_water.ts vert |
| Wave-plane ring propagation speed | constant | 2.0 u/s | melancholic_water.ts vert |
| Wave-plane onset splash | onset.intensity → Gaussian bump | 0.22 × intensity × exp(-age/0.2) | melancholic_water.ts vert |
| Wave-plane ambient flow | uFlux × harmonic_ratio | 0.025..0.055 × (0.5+flux·0.5) | melancholic_water.ts vert |
| Wave-plane displacement clamp | safety | ±0.5 | melancholic_water.ts vert |
| Wave-plane specular intensity | crest mask + lambert | 1.1 + 1.6·crest | melancholic_water.ts frag |
| Wave-plane Fresnel rim | view·normal grazing | pow(1−V·N, 5) × 0.55 | melancholic_water.ts frag |
| Wave-plane caustic shimmer | uTime + chromaStrength | 0.18 + 0.22·chroma | melancholic_water.ts frag |
| Wave-plane foam at crests | displacement > 0.18 | mix 0.45 white | melancholic_water.ts frag |
| Rain ribbon fall speed | base × (1 + flux·0.6 + onsetEnv·0.8) | 1×–2.4× | melancholic_rain.ts:~395 |
| Rain ribbon aspect ratio | rolloff | 1:3..1:7 | melancholic_rain.ts:~390 |
| Rain ribbon density (live count) | 400 + buildIntensity·1200 | 400..1600 | melancholic_rain.ts:~390 |
| Rain ribbon glow on beat | beatPulse | +0.6 alpha, +0.4 red | melancholic_rain.ts RIBBON_FRAGMENT |
| Onset particle burst count N | 2 + intensity·4 + contrast·2 | clamped 2..7 | onset_emitter.ts:~210 |
| Onset particle fan radius | 0.15 + contrast·0.25 | 0.15..0.40 u | onset_emitter.ts:~280 |
| Onset particle Y placement | mel_bands weighted + pitch_class fine | -1.8..+1.8 + ±0.3 | onset_emitter.ts:~250 |
| Onset particle size scale | inverse pitch_class (Walker 2010) | 1.4 − 0.7·(pc/11) | onset_emitter.ts:~270 |
| Onset particle ADSR envelope | per-onset attack/decay/sustain ms | direct | onset_emitter.ts VERT |
| Per-band sparkle spawning | melBand > 0.55, 0.10 s cadence | 8 bands × 10 Hz max | onset_emitter.ts:spawnBandPulse |
| Per-band sparkle Y | -1.8 + (k/7)·3.6 | one per band | onset_emitter.ts:spawnBandPulse |
| Per-band sparkle tint | 0.6 + (k/7)·0.8 (lo bands darker) | 0.6..1.4 mult | onset_emitter.ts:spawnBandPulse |
| Camera Y dolly | -sectionProgress · 0.4 | 0..-0.4 u | melancholic_rain.ts:~420 |
| Camera bass sway X | sin(0.6t) · sub_bass · 0.18 | ±0.18 u | lib/cinematic_camera.ts |
| Camera bass sway Y | cos(0.42t) · low_bass · 0.10 | ±0.10 u | lib/cinematic_camera.ts |
| Camera Z push-in (build) | buildIntensity · 1.4 | 0..1.4 u closer | lib/cinematic_camera.ts |
| Camera Z swoop (phrase) | phrasePulse · 0.6 | 0..0.6 u closer | lib/cinematic_camera.ts |
| Camera Y crane (phrase) | phrasePulse · 0.25 | 0..0.25 u up | lib/cinematic_camera.ts |
| Camera shake amp | dropImpulse · 0.12 + phrasePulse · 0.05 | hash-jittered | lib/cinematic_camera.ts |
| Camera Z roll | (tension − 0.4) · 0.05 + phrasePulse · 0.03 | ±0.05 rad | lib/cinematic_camera.ts |
| Skyline x-drift (far) | (centroid − 0.5) · 0.02 u/s | ±0.30 u over 30 s | effects/skyline.ts |
| Skyline window glow | chromaStrength × 0.35..0.75 | 0..0.75 mult | effects/skyline.ts |
| Skyline drop lightning | dropImpulse | 0..1 flicker | effects/skyline.ts |
| God-rays intensity | 0.10 + 0.55·rms + 0.30·chroma + 0.25·build | 0.10..1.20 | effects/godrays.ts |
| God-rays spread | centroid (powers 5.0→2.5) | mix tighter↔wider | effects/godrays.ts |
| God-rays color | chromaStrength lerps silver↔warm | 2-stop | effects/godrays.ts |

### Serene Dawn (high V, low A)

| Visual | Driver | Magnitude | File:line |
|---|---|---|---|
| Sun disk vertical position | pitchHeight | 0.30 + ph·0.24 (NDC) | serene_sun.ts:~140 |
| Sun disk radius | harmonicRatio | 0.13 + hr·0.10 | serene_sun.ts:~145 |
| Sun core brightness | rms × section.brightness | (0.6 + rms·1.1) × sb | serene_sun.ts:~150 |
| Corona spread | chromaStrength | 0.4 + chs·0.7 | serene_sun.ts:~155 |
| Corona softness | harmonicRatio | 0..1 | serene_sun.ts:~157 |
| Sun color warmth | mfccWarm | RGB lerp warm↔cool | serene_sun.ts:~170 |
| Cloud band density | 1 − rms | 0.35 + (1−rms)·0.55 | serene_sun.ts:~160 |
| Cloud band drift speed | spectralFlux | 0.02 + flux·0.18 u/s | serene_sun.ts:~163 |
| Horizon glow | centroid | direct 0..1 | serene_sun.ts:~167 |
| Hills skyline drift | (centroid − 0.5) · 0.02 u/s | ±0.30 u over 30 s | effects/skyline.ts shape="hills" |
| Hills skyline flicker | disabled (Serene is calm) | 0 | serene_dawn.ts: enableFlicker=false |
| Warm god-rays | (same formula as Mel.) × 0.85 | tuned dimmer | serene_dawn.ts: intensityScale |
| Camera sway | bass × 0.5 multiplier | gentler than Mel. | cinematic_camera.ts |
| Camera shake | drop × 0.15 multiplier | near-zero (calm biome) | cinematic_camera.ts |

### Euphoric Bloom (high V, high A) — *Milestone C polish, hero pending*

| Visual | Driver | File:line |
|---|---|---|
| Background bloom | beatPulse + dropImpulse | euphoric_bloom.ts BG |
| Radial particle bloom | beatPulse boost × 1.5 + phrasePulse × 0.6 | euphoric_bloom.ts:~258 |
| Curl-noise drift | pitchDirection vertical bias | euphoric_bloom.ts:~261 |
| Onset emitter accent | tonal hits → magenta tint | euphoric_bloom.ts:~289 |
| Per-band sparkles | melBands > 0.55 | euphoric_bloom.ts:~293 |

### Intense Storm (low V, high A) — *Milestone C polish, hero pending*

| Visual | Driver | File:line |
|---|---|---|
| Lightning bolt fire | downbeatPulse > 0.85 OR dropImpulse > 0.5 | intense_storm.ts:~285 |
| Particle vertical range | rolloff (ceil/floor) | intense_storm.ts:~302 |
| Particle jitter on beats | beatPulse × 0.04 | intense_storm.ts:~305 |
| Onset emitter accent | tonal hits → red tint | intense_storm.ts:~317 |

---

## 6. Global post-FX (runtime.ts `__renderFrameAt`)

| FX channel | Formula | Range | Line |
|---|---|---|---|
| Bloom intensity | baseBloom × (1 + rms·2.2) × (1 + build·1.6) | 1×–8.96× | runtime.ts:522 |
| Bloom drop boost | × (1 + drop · 2.5) | extra ×1..3.5 | runtime.ts:546 |
| Bloom phrase flicker | × (1 + phrasePulse · 0.30) | extra ×1..1.3 | runtime.ts:558 |
| Bloom section transition | × (1 + w · 0.25), w fades over 1.5 s | extra ×1..1.25 | runtime.ts:569 |
| Chromatic aberration | 0.0006 + hue_distance · 0.018 × (1 + build · 0.5) | sub-pixel..52 px | runtime.ts:527 |
| CA drop boost | × (1 + drop · 2.5) | extra ×1..3.5 | runtime.ts:548 |
| Vignette darkness | 0.30 + tension · 0.40 + build · 0.35 | 0.30..1.05 | runtime.ts:532 |
| Vignette offset | 0.30 − build · 0.05 | 0.25..0.30 | runtime.ts:533 |
| Grain opacity | (0.04 + zcr · 0.16) × (1 − rms · 0.5) | 0.02..0.20 | runtime.ts:537 |
| Hue rotation | grade.hue + chroma_angle/π · 0.175 + mfccWarm · 0.14 | ±0.315 rad | runtime.ts:583 |
| Saturation lift | grade.sat + chromaStrength · 0.15 + phrasePulse · 0.28 | direct | runtime.ts:559, 591 |
| Contrast push (new) | grade.con + build · 0.12 + drop · 0.20 | 0..+0.32 | runtime.ts:~551 |
| Camera FOV push-in | 50° − rms · 7 − build · 7 | 36°..50° | runtime.ts:597 |

---

## 7. Biome routing logic

In `composition.py`:

```
V, A from per-section emotion average
A_corrected = A + audio_arousal_boost(frames, start, end, bpm)
  audio_arousal_boost = clamp(flux·0.18 + sub_bass·0.12 + tempo_factor·0.10, 0, 0.30)
  tempo_factor = clamp((bpm − 90) / 60, 0, 1)

biome_weights = softmax(−d² / τ) over 4 quadrant centers
  τ = 0.25 (smooth ~1 s perceptual crossfade)

scene = argmax(weights) → enum scene name
```

The audio-arousal boost was added because the V/A regression (Essentia
mood models or spectral fallback) was under-estimating arousal on
modern EDM. With it, Garrix Gravity (129 BPM) routes Euphoric Bloom
instead of Serene Dawn.

---

## 8. What's *not yet* fully wired (deferred milestones)

- **Tempogram** instantaneous tempo deviation → wave-plane ring speed modulation
- **Tonnetz** chord-distance vector → camera dolly micro-jitter
- **Percussive-only RMS** (HPSS percussive component) → rain ribbon brightness pulse
- **PLP** predominant local pulse → ambient wave displacement between beats
- **Chroma flux** (np.diff on chroma) → skyline window shimmer
- **Euphoric Bloom hero** geometry (volumetric dome + petal storm)
- **Intense Storm hero** geometry (lightning network + storm wall)
- **Texture vocabulary overlay** — halftone/scanline/iridescence/glitch keyed to dominant audio character (the "shapes + textures" axis)

---

## 9. Sanity checks for "is this mapping actually live?"

For any visual property:
1. Find it in this table.
2. Open `<file>` at the cited line — verify the formula matches.
3. Grep for the AudioFrame field used (`ctx.audio.<x>`) to confirm wiring.
4. If the magnitude looks subtle on screen, the *coefficient* in column 3
   is the lever — bump it. Don't add a new mapping for the same feature.

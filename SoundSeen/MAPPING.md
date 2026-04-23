# SoundSeen — Sound → Sense Mapping

A one-page reference of what each backend signal drives in visuals and haptics.

---

## Backend signals (live, per-frame)

| Signal | Range | Means |
|---|---|---|
| `bands[0]` sub-bass | 0–1 | 20–60 Hz pressure |
| `bands[1]` bass | 0–1 | 60–250 Hz body |
| `bands[2..4]` mids | 0–1 | melody / vocals |
| `bands[5..6]` presence/brilliance | 0–1 | air, cymbal body |
| `bands[7]` ultra-high | 0–1 | cymbal sheen, shaker |
| `currentEnergy` | 0–1 | overall loudness |
| `currentFlux` | 0–~1.5 | rate of spectral change |
| `fluxSpikeGeneration` | counter | adaptive-threshold spike fires |
| `currentCentroidNormalized` | 0–1 | spectral brightness (per-track p5/p95) |
| `currentPitchDirection` | -1..+1 | pitch rising / falling |
| `currentHue` | 0–1 | chromatic key angle |
| `currentChromaStrength` | 0–1 | how tonal (vs noise) |
| `currentHarmonicRatio` | 0–1 | harmonic vs percussive |
| `smoothedValence` | 0–1 | negative ↔ positive emotion |
| `smoothedArousal` | 0–1 | calm ↔ intense |
| `beatPulse` | 0–1 | decaying beat marker (1.0 on downbeat) |
| `onsetGeneration` / `lastOnset` | event | attack events w/ sharpness + intensity |
| `currentSectionLabel` | string | intro/verse/chorus/bridge/break/drop/outro |

---

## Visual mappings

### Scene textures (live inside the scene, can mirror/rotate per section)

| Signal | Visual | Where on screen | Why |
|---|---|---|---|
| `bands[0]` sub-bass | **SubBassRipple** — concentric rings | FLOOR corners (bottom-L, bottom-R) | Sub-bass is a physical pressure wave → expanding ring is the literal metaphor |
| `bands[1..2]` bass/low-mid | **Smoke** — blurred layered mass | FLOOR → MIDBODY | Bass = edgeless mass. Layers rise with bass, slosh laterally when noisy |
| `bands[3..5]` mids | **InkBleed** — soft spreading blobs | MIDBODY | Sustained mids bleed into each other. Panned L/R by key, lifted by valence, smeared by noise |
| `bands[6..7]` treble | **Aurora** ribbons + **Frost** specks | SKY | Brilliance flows (aurora); ultra-high is crystalline (frost) |
| `beatPulse` > 0.35 | **GlowPulse** — radial bloom | CORE (drifts slowly) | Beats are emphasis, not a shape — a "feeling of brightness" |
| `onsetGeneration` (sharp) | **Ember** — bright particles | spectral — low onsets spawn low, high onsets spawn high | Attacks are hot, kinetic, short-lived |
| `onsetGeneration` (slow) | **InkBleed** spawn | MIDBODY | Bowed/pad onsets spread rather than strike |
| `currentPitchDirection` | **LightRay** — radial streaks | origin tracks pitch (up-right rising, down-left falling) | Rays point to where the melody is going |
| `fluxSpikeGeneration` | **FluxShatter** — directional slashes | HORIZON_BAND | Flux = rupture, not shimmer — slashes read as "something broke" |
| `currentFlux` + low valence | **FilmGrain** — noise + optional cool tint | full-screen | Flux = disorder; low valence adds anxious blue |
| drop phase + high flux | **ThermalShimmer** — UV distortion | full-screen | Heat pressure distorting the air |
| drop release | **VelvetDarkness** — vignette + FLOOR breath | edges + FLOOR | Darkness has weight; breath rate scales with arousal |

### Dashboard textures (anchored to the real frame, stay readable during chorus mirror / bridge rotation)

| Signal | Visual | Where | Why |
|---|---|---|---|
| `currentHue` + `currentChromaStrength` | **KeyRail** — 12 pitch-class color stops, active one glows | GUTTER_L lower (left rail, v 0.48–0.90) | Persistent "song is in F# right now" indicator |
| `currentCentroidNormalized` + arousal | **SpectralStaircase** — 8-rung brightness ladder | GUTTER_L upper (v 0.10–0.46) | Active rung climbs as centroid rises |
| `currentHarmonicRatio` + CN + CS | **ConsonanceLattice** — hex cell mesh | GUTTER_R (right rail) | Harmonic sound = organized mesh; noise dissolves it |
| `smoothedValence` + arousal | **ValenceGradient** — warm/cool diagonal blooms | 4 corners | Happy songs light warm diagonal (TL+BR); sad songs light cool diagonal (TR+BL) |
| `currentHue` + `currentChromaStrength` (> 0.2) | **ChromaSlick** — iridescent triad wash | PERIMETER (6% frame) | Appears when tonal, disappears when atonal — see the boundary on the frame |

### Color pull (applies to every color-dynamic texture)

When `currentChromaStrength > 0.3`, every texture (Smoke, Ink, Frost, Aurora, LightRay, Ember, GlowPulse, Velvet) blends its base slot color toward the current key hue, weighted by CS × per-texture factor. Atonal moments stay in the emotional palette; tonal moments paint in the song's key.

---

## Haptic mappings

Four voices running in parallel on Core Haptics.

| Voice | Trigger | Type | Intensity formula | Why |
|---|---|---|---|---|
| **Beats** | backend `BeatEvent` at playback time | `.hapticTransient` | Downbeat: `intensity · 1.25`, sharpness `+0.20`<br>Regular: `intensity · 0.70`, sharpness `× 0.85` | Downbeats need weight; offbeats are lighter to avoid saturating the taptic |
| **Onsets** | backend `OnsetEvent` at playback time | `.hapticTransient` | `intensity · 0.45`; sharpness = `max(onset.sharpness · 0.7, attackSlope)` | Onsets overlap with beats — firing both at full strength saturates the motor. Steep attacks feel sharper |
| **Hum** | every tick | `.hapticContinuous` (single long-lived event) | `(sub_bass + bass) · 0.55`, EMA-smoothed (α=0.12) | Continuous low rumble "feels" the bass floor even between transients |
| **Patterns** | event-driven | `.ahap` file | pre-authored | Scored moments with richer envelopes |

### Pattern files
- `drop.ahap` — fires at `DropChoreography.onDropReleased` (the flash phase of the drop state machine)
- `buildup.ahap` — authored but not currently wired
- `break.ahap` — authored but not currently wired

### Global intensity
UserDefaults `soundseen.hapticIntensityMode`:
- `"subtle"` → × 0.65
- default → × 1.00
- `"intense"` → × 1.28

---

## Quick lookup: "when the music does X…"

| When this happens… | You see… | You feel… |
|---|---|---|
| Bass kick | Smoke brightens, Ember erupts low | Beat transient (heavy if downbeat) |
| Sub-bass drop (808) | SubBassRipple rings expand from FLOOR corners | Hum intensity surges |
| Snare / clap | FluxShatter slashes on HORIZON | Onset transient |
| Hi-hat / shaker | Frost shimmer in SKY | Onset transient (sharp, light) |
| Melody note sustained | InkBleed spreads in MIDBODY | Hum continues, no transient |
| Chord change (key modulates) | KeyRail marker slides; ChromaSlick triad rotates | — |
| Tonal → atonal transition | KeyRail + ChromaSlick fade out; ConsonanceLattice dissolves | — |
| Arousal rises | Aurora cycles faster; LightRay count grows; VelvetDarkness breathes faster | — |
| Valence rises | ValenceGradient warm diagonal brightens; InkBleed lifts upward | — |
| Pitch rising | LightRay origin moves up-right; Smoke drift slows ("holds") | — |
| Drop hits | Palette inverts briefly; Ember escape burst; ThermalShimmer at 100% | `drop.ahap` plays |
| Chorus | Scene mirrors horizontally; aurora gets 5 ribbons; all textures unlocked | Full-strength beats |
| Break section | Near-empty scene, VelvetDarkness + grain; only sub-bass ripple + cool mood corners | Hum continues, sparse beats |

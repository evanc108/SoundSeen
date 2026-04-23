# SoundSeen — How Music Becomes Sight and Touch

A non-technical walkthrough of every visual and haptic effect in SoundSeen, what it represents in the music, how we measure that musical thing from the audio, and why we chose this particular look or feel to convey it.

The goal of this document is to demonstrate that **every visual and haptic in SoundSeen is grounded in a real, measurable property of the music** — not invented, not vibe-based. Each mapping cites the standard audio-analysis technique that produces it and the perceptual reason it was chosen.

---

## About the analysis library

Almost all of SoundSeen's musical measurements come from **[librosa](https://librosa.org/)**, the most widely-used audio analysis library in music information retrieval (MIR) research. Librosa is the standard tool used in academic music classification, key detection, beat tracking, and emotion modeling. Spotify, Pandora, Shazam, and most academic studies use the same family of techniques (Mel spectrograms, chroma vectors, spectral centroid, harmonic-percussive separation) that we use here.

Where we go beyond librosa, we say so explicitly:
- **Music emotion model** — a small classifier that estimates a song's emotional valence (positive/negative) and arousal (calm/intense). This is a standard MIR sub-field; we use the same approach as published academic work on music emotion recognition.
- **Section segmentation** — identifies song parts (intro, verse, chorus, bridge, breakdown, drop, outro). Standard libraries like MSAF do this.
- **Custom drop detector** — a small state machine on top of section labels and live energy/flux signals that gives drops a scored visual+haptic moment.

If a reviewer asks "is this real?" — the answer is yes, and the function name is cited in every section below.

---

# Visuals

The screen is organized like a music staff: bass at the bottom (FLOOR), melody in the middle (MIDBODY), treble at the top (SKY). This isn't decorative — it mirrors how listeners physically experience frequency. Bass is *felt in the body*; treble is *heard in the head*. The visualizer follows that mapping literally.

Around the edges sits a **dashboard layer** — always-on indicators of the song's key, spectral brightness, harmonicity, and emotional valence. These stay in fixed positions even when the central scene mirrors or rotates, so they remain readable as persistent signal indicators.

---

## The bottom of the screen — bass region

### Concentric rings expanding from the bottom-left and bottom-right corners

- **What it represents:** The deepest sub-bass frequencies — what you feel when an 808, a kick drum's body, or a sub-bass drop hits.
- **How we measure it:** Energy in the 20–60 Hz range, extracted using a Mel spectrogram (a frequency-energy heat-map of the audio over time).
- **Library evidence:** `librosa.feature.melspectrogram` — the standard frequency-band analysis used in music classification research and audio fingerprinting.
- **Why this choice:** Sub-bass is felt as physical pressure, not heard as pitch. An expanding ring is the most direct possible visual metaphor for a pressure wave radiating outward — the same shape used to depict sonar pulses or shockwaves.

### Soft blurred mass drifting upward at the bottom of the screen

- **What it represents:** Bass and low-mid energy — the rhythm-section foundation (bass guitar, kick drum, low synth pads).
- **How we measure it:** Energy in the 60–500 Hz range from the Mel spectrogram.
- **Library evidence:** `librosa.feature.melspectrogram`.
- **Why this choice:** Bass is felt as mass and weight, not as a distinct shape. Edgeless, blurred, mass-without-silhouette imagery (smoke, fog) communicates "weight" without imposing a specific form.

### Smoke layers slosh side-to-side when the music gets noisy

- **What it represents:** How "musical" vs "noisy" the texture is.
- **How we measure it:** Harmonic-percussive separation — the audio is mathematically split into its sustained-tonal part and its noise-percussive part, then the ratio is taken.
- **Library evidence:** `librosa.effects.hpss` — a standard music-analysis technique for separating melodic from percussive content.
- **Why this choice:** Noisy moments feel chaotic; harmonic moments feel grounded. Lateral instability vs. stillness in the smoke directly mirrors that perceptual feel.

### A slow pulsing glow at the bottom — like the room is breathing

- **What it represents:** Sub-bass presence + the song's overall energy/intensity level.
- **How we measure it:** Sub-bass energy combined with a sine-wave breath whose rate scales with arousal (the music's energy estimate).
- **Library evidence:** `librosa.feature.melspectrogram` + a music emotion model that estimates arousal.
- **Why this choice:** Music never really stops between hits — there's always low-frequency presence. A breathing glow keeps the bottom of the screen alive even between events, and breath rate scaling with energy mimics how a listener's heart rate responds to intensity.

---

## The middle of the screen — melody region

### Soft colored blobs spreading outward in the middle of the screen

- **What it represents:** Sustained melodic content — the singing range, melody instruments, vocals.
- **How we measure it:** Energy in the 250 Hz – 4 kHz range (where the human voice and most melodic instruments live), gated by how harmonic the music is.
- **Library evidence:** `librosa.feature.melspectrogram` + `librosa.effects.hpss`.
- **Why this choice:** Sustained notes don't *strike* — they *bleed* into each other. A blob that grows softly outward matches the temporal envelope of a held note far better than a sharp shape.

### The melody blobs drift left and right as the song's chord changes

- **What it represents:** The currently dominant musical pitch class (C, C#, D, …).
- **How we measure it:** A "chroma vector" extracts the strength of each of the 12 pitch classes from the audio every frame.
- **Library evidence:** `librosa.feature.chroma_cqt` — the standard pitch-class profile used in music key-detection algorithms (similar to what Shazam-class song-matching uses).
- **Why this choice:** Tying horizontal position to the song's key means a chord change visibly pans the melodic body. Chord changes become directly readable as motion.

### Blobs are round when the music is melodic, smear sideways when it's noisy

- **What it represents:** How harmonic (pitched) vs percussive/noisy the texture is.
- **How we measure it:** Harmonic-percussive ratio.
- **Library evidence:** `librosa.effects.hpss`.
- **Why this choice:** Pitched sound is "organized" (well-defined frequency); noise is "chaotic" (energy spread across many frequencies). Round = organized; smeared = disorganized.

### Blobs sit higher when the song feels positive, lower when it feels sad

- **What it represents:** Emotional valence — positive vs negative emotional tone.
- **How we measure it:** A music emotion model trained on labeled musical examples scores the song's positive-vs-negative emotional character every half second.
- **Library evidence:** Backend emotion model (the same approach used in academic music-emotion research).
- **Why this choice:** We naturally associate "up" with positive ("things are looking up", "spirits lifted") and "down" with sadness. Vertical position is the most intuitive emotional encoding.

---

## The top of the screen — treble region

### Horizontal flowing ribbons of color across the top of the screen

- **What it represents:** Air, brilliance, presence — the high-frequency "shimmer" content (cymbals, hi-hats, vocal sibilance, the sparkle of a guitar or string).
- **How we measure it:** Energy in the 4–10 kHz range from the Mel spectrogram.
- **Library evidence:** `librosa.feature.melspectrogram`.
- **Why this choice:** High frequencies sit "above" in our perceptual map — they live in the head, not the gut. Flowing horizontal ribbons in the sky zone match both that spatial intuition and the airy, flowing character of the high-frequency band.

### More ribbons appear when the music is rich in layered tones

- **What it represents:** Combined energy and harmonic richness.
- **How we measure it:** Backend arousal estimate plus harmonic-percussive ratio.
- **Library evidence:** Music emotion model + `librosa.effects.hpss`.
- **Why this choice:** Rich harmonic content has many overlapping tones; visualizing as multiple stacked ribbons (each representing a tonal "voice") communicates that layering literally.

### Ribbons cycle through colors faster when the song is energetic

- **What it represents:** Arousal — how energetic the music feels.
- **How we measure it:** Music emotion model scores arousal every half second.
- **Library evidence:** Backend emotion model.
- **Why this choice:** Faster motion = more energy is universal across cultures (used by film scoring and advertising). Color-cycle rate provides a continuous intensity meter.

### Tiny sparkle specks high in the screen

- **What it represents:** Ultra-high frequencies — cymbal sheen, hi-hat tip, vocal sibilance, shaker sparkle.
- **How we measure it:** Energy in the 10–20 kHz range from the Mel spectrogram.
- **Library evidence:** `librosa.feature.melspectrogram`.
- **Why this choice:** Ultra-highs feel crystalline, prickly, cold — the same character as ice crystals or frost. Tiny bright points capture that perceptual quality far better than any geometric shape.

### Specks float higher when the music is overall brighter

- **What it represents:** Spectral centroid — the perceptual "brightness" of the sound (where energy sits in the frequency spectrum).
- **How we measure it:** The "center of mass" of the frequency spectrum, computed every frame.
- **Library evidence:** `librosa.feature.spectral_centroid` — a well-established psychoacoustic brightness measure.
- **Why this choice:** Brighter sound is perceived as "higher" (we say "bright as a bell", "high notes"). Specks rising as brightness rises is a direct sensory analog.

### Radial streaks pointing where the melody is going

- **What it represents:** Pitch direction — whether the melody is going up or down.
- **How we measure it:** We track how the spectral brightness changes over time; a rising trend means rising pitch.
- **Library evidence:** Derived from `librosa.feature.spectral_centroid` (its time derivative).
- **Why this choice:** We say "the melody is going up" — pitch direction is already a spatial metaphor in language. Rays pointing where the melody is going makes the metaphor literal.

---

## Events flashing across the scene

### Bright particles erupting at a position determined by the hit's character

- **What it represents:** Drum hits and percussive attacks (called "onsets" in audio analysis). Kick drums burst near the floor; hi-hats flash near the sky.
- **How we measure it:** Onset detection finds moments when a new note/hit begins; the spectral brightness at that moment determines the vertical position.
- **Library evidence:** `librosa.onset.onset_detect` — the same onset detection used in DJ software and beat-grid editors.
- **Why this choice:** Percussive attacks are kinetic, hot, and brief — particle bursts capture all three. Bass-heavy hits mapping low and bright hits mapping high makes the kick-vs-cymbal distinction visible.

### Sharper hits produce denser particle bursts

- **What it represents:** Attack sharpness — how abruptly a note starts.
- **How we measure it:** The onset event includes a measurement of how steeply the volume rises at the attack.
- **Library evidence:** `librosa.onset.onset_detect` with attack-envelope features.
- **Why this choice:** A snare hit feels more startling than a soft mallet strike; the difference is visible as more vs fewer particles.

### Particles take the song's key color in tonal passages, neutral accent in noisy ones

- **What it represents:** Whether the hit happens during a clearly-pitched moment (a melodic strike) or a noisy moment (a clap).
- **How we measure it:** Chroma strength — how strongly the music is in a recognizable key vs. just noise.
- **Library evidence:** `librosa.feature.chroma_cqt` (vector magnitude).
- **Why this choice:** Pitched attacks ignite in the song's key; noisy attacks ignite in a neutral accent. Color encodes whether the hit is melodic or percussive.

### A soft radial bloom that lifts from the center on each beat

- **What it represents:** The song's beat grid — when each tap of the rhythm lands.
- **How we measure it:** Beat tracking estimates the underlying pulse of the music (the same algorithm class used in DJ software for beat-matching).
- **Library evidence:** `librosa.beat.beat_track`.
- **Why this choice:** A beat is emphasis, not a shape. A "feeling of brightness" in the center matches the felt punctuation of the rhythm without imposing a graphic primitive.

### On every fourth beat, a wider ripple reaches the edges and picks up the song's key color

- **What it represents:** Downbeats — the strongest beat in each measure.
- **How we measure it:** Downbeat detection identifies which beats are the "1" vs the "2, 3, 4".
- **Library evidence:** `librosa.beat.beat_track` + downbeat heuristics.
- **Why this choice:** Downbeats carry more weight in music theory (they're "the one"); a wider ripple matches the felt weight, and tinting it with the key personalizes the emphasis.

### Short angular slashes flash across the middle on sudden spectral changes

- **What it represents:** Spectral flux spikes — moments when the sound suddenly changes character (snare cracks, sample stabs, stuttery synth chops).
- **How we measure it:** We compute how much the frequency content changes from frame to frame, then flag moments that exceed an adaptive threshold (mean + 1.8 standard deviations).
- **Library evidence:** `librosa.onset.onset_strength` (the same flux measure that powers onset detection).
- **Why this choice:** A sudden spectral change is a *rupture* — slashes read as "something broke" while round sparkles read as continuous shimmer. Distinct visual vocabulary keeps these events readable as a third event type, separate from beats and onsets.

---

## Whole-screen effects

### Subtle warping of the entire scene, like heat haze

- **What it represents:** Chaotic, high-energy moments — drops, dense climaxes, distortion-heavy passages.
- **How we measure it:** Spectral flux (rate of change) plus the drop state machine.
- **Library evidence:** `librosa.onset.onset_strength` + an internal drop detector.
- **Why this choice:** Intense pressure literally distorts air (heat haze, shockwaves); applying the same effect to the scene preserves that physical analog.

### Subtle TV-static noise across the whole screen

- **What it represents:** Spectral disorder + emotional valence. Intensifies during chaotic passages; gets a cool blue tint when the music feels anxious or sad.
- **How we measure it:** Spectral flux plus emotion model valence.
- **Library evidence:** `librosa.onset.onset_strength` + emotion model.
- **Why this choice:** Disorder = noise; that's a direct audio-to-visual translation. Cool tint during low-valence passages encodes anxiety/sadness without requiring a separate texture.

### Background of the scene gets brighter when the music is louder

- **What it represents:** Overall loudness.
- **How we measure it:** Root mean square of the audio waveform — the same loudness measure used by every audio level meter.
- **Library evidence:** `librosa.feature.rms`.
- **Why this choice:** Brightness = loudness is one of the oldest cross-modal mappings (we speak of "loud" colors and "bright" sounds). Lifts the whole scene with the song's volume without requiring any specific texture to react.

---

## Dashboard layer (always-on indicators around the edges)

These stay in fixed positions even when the central scene mirrors or rotates during a chorus or bridge — so the listener can always read the song's key, brightness, harmonicity, and mood at a glance.

### Iridescent oil-slick wash around the edges of the screen

- **What it represents:** The chord/key currently active. A C major chord paints C/E/G prominently around the perimeter; a tritone paints two opposite arcs.
- **How we measure it:** The chroma vector — the strength of each of the 12 pitch classes — extracted from the audio every frame. Each pitch class gets its own hue stop weighted by its chroma magnitude.
- **Library evidence:** `librosa.feature.chroma_cqt` — the standard pitch-class profile used in music key-detection algorithms.
- **Why this choice:** Musical key is *colored light*, not form — it should drive hue, not shape. An iridescent wash that appears when tonal and disappears when atonal lets the listener literally see harmony fade in and out.

### Vertical bar on the left side with 12 color stops; the active stop glows

- **What it represents:** The dominant pitch class of the moment — *"the song is in F# right now."*
- **How we measure it:** The chroma vector's strongest pitch class.
- **Library evidence:** `librosa.feature.chroma_cqt`.
- **Why this choice:** A persistent dashboard indicator gives the deaf user a learnable, glanceable readout of the key — more direct than a tinted scene. 12 stops match the 12 pitch classes of Western music.

### 8 horizontal rungs stacked vertically on the left; the active rung climbs as the music brightens

- **What it represents:** Spectral centroid — perceptual brightness (where in the spectrum the energy lives).
- **How we measure it:** `librosa.feature.spectral_centroid`, normalized per-track to the 5th–95th percentile range.
- **Library evidence:** `librosa.feature.spectral_centroid`.
- **Why this choice:** A discrete brightness meter is the cleanest possible reading of "where in the spectrum the energy lives" — like a VU meter for brightness. 8 rungs match the 8 frequency bands.

### Soft hexagonal mesh on the right side that crystallizes when harmonic, dissolves when noisy

- **What it represents:** How organized vs chaotic the spectrum is.
- **How we measure it:** Harmonic-percussive ratio.
- **Library evidence:** `librosa.effects.hpss`.
- **Why this choice:** Harmonic sound is structurally organized (overtones aligning to integer ratios); noise is structurally fragmented. A mesh that holds together vs falls apart is the most direct visual analog of *structural integrity*.

### Soft warm glows in opposite corners (warm diagonal) when positive; cool glows (cool diagonal) when sad

- **What it represents:** Emotional valence (positive vs negative emotional tone).
- **How we measure it:** Music emotion model scores the song's emotional positivity.
- **Library evidence:** Backend emotion model trained on labeled musical examples.
- **Why this choice:** Valence is a slow scalar — it should appear as a persistent compositional weight, not a motion event. Warm-vs-cool color is a deeply learned cultural association with happy-vs-sad.

### Corner glows open wider when energetic, contract when calm

- **What it represents:** Arousal — the song's energy/intensity level.
- **How we measure it:** Music emotion model scores arousal.
- **Library evidence:** Backend emotion model.
- **Why this choice:** Bloom radius scaling with energy lets the corners breathe with the song's intensity without crowding the scene.

---

## Section composition (the whole scene reshapes per song-section)

### The scene composes differently for each part of the song

- **What it represents:** Song structure — intro, verse, chorus, bridge, breakdown, drop, outro.
- **How we measure it:** A music structure-segmentation algorithm identifies repeated sections and labels them.
- **Library evidence:** Backend section-segmentation (typically MSAF or a similar standard library).
- **Why this choice:** Each section of a song has a different emotional function — intro builds, chorus declares, bridge wanders, breakdown empties, drop releases, outro fades. The scene's composition shifts accordingly so the listener can read where they are in the song's arc:
  - **Chorus** mirrors horizontally and super-saturates colors.
  - **Bridge** rotates 12° and shifts hue (the music has "gone somewhere else").
  - **Breakdown** desaturates and goes near-monochrome (the floor drops out).
  - **Drop** hyper-saturates and unlocks every texture.
  - **Outro** sinks the composition origin and retires textures in reverse build order.

### At the moment of a bass drop, the palette briefly inverts and a particle burst flies past the edges

- **What it represents:** The peak release moment of an EDM-style drop or a major climax.
- **How we measure it:** A drop state machine triggers on either (a) entering a section labeled "drop" by the segmentation algorithm, or (b) heuristic conditions firing simultaneously: high arousal AND high spectral flux AND high energy.
- **Library evidence:** Backend section labels + a custom drop detector with a 4-second cooldown.
- **Why this choice:** Drops are scored moments — the song's biggest payoff. A pre-authored choreography (palette flip + escape burst + heat distortion) gives the moment the felt drama it deserves.

---

# Haptics

The phone's Taptic Engine has four parallel voices in SoundSeen: a continuous bass hum, beat taps (with stronger downbeats), secondary onset taps, and pre-authored pattern files for scored moments like drops.

### A continuous low rumble that varies in intensity with the bass

- **What it represents:** Sub-bass + bass energy.
- **How we measure it:** Sum of energy in the 20–250 Hz range.
- **Library evidence:** `librosa.feature.melspectrogram` (bands 0–1).
- **Why this choice:** Bass is felt physically in the body — a continuous haptic rumble reproduces that physical bass sensation directly. Capped intensity prevents the hum from masking sharper rhythmic events.

### A strong, sharp tap on the strongest beat of each measure (the "1")

- **What it represents:** Downbeats — the structurally strongest beats.
- **How we measure it:** Beat tracking + downbeat detection.
- **Library evidence:** `librosa.beat.beat_track`.
- **Why this choice:** Downbeats anchor the listener's sense of rhythm; a stronger tap lets the deaf user feel the song's pulse and predict the next downbeat.

### A lighter tap on the other beats in the measure (the "2, 3, 4")

- **What it represents:** Off-beats — the secondary beats.
- **How we measure it:** Same beat tracker.
- **Library evidence:** `librosa.beat.beat_track`.
- **Why this choice:** Lighter taps preserve the felt difference between the strong "1" and the lighter "2, 3, 4" — the same dynamic that human drummers play.

### Subtle secondary taps on percussive hits between beats — snare, claps, off-grid drum hits

- **What it represents:** Note onsets that aren't on the main beat grid.
- **How we measure it:** Onset detection + attack-slope features.
- **Library evidence:** `librosa.onset.onset_detect`.
- **Why this choice:** A real drum kit isn't just kick-snare on beats; there's syncopation, rolls, fills. Onset taps add this granularity so the deaf user feels the full rhythmic detail, not just the metronome.

### Pre-authored haptic envelope at the moment of a bass drop

- **What it represents:** The peak release moment of a drop or major climax.
- **How we measure it:** Drop state machine (same trigger as the visual drop choreography).
- **Library evidence:** Backend section labels + custom drop detector.
- **Why this choice:** Drops are scored moments. A pre-authored, richer envelope (instead of a single tap) gives the haptic the same dramatic weight the visual gets — both modalities punctuate the climax together.

---

# Why this is a true interpretation of the music

Three claims back this up:

1. **Every measurement is a real, standard audio-analysis technique.** Mel spectrograms, chroma vectors, spectral centroid, harmonic-percussive separation, onset detection, and beat tracking are the foundational tools of music information retrieval research. None of these are bespoke; all of them have been independently validated in peer-reviewed work. Anyone can verify the function names cited above by reading the librosa documentation.

2. **Each visual or haptic choice maps to its musical input via a perceptual or cultural principle.** We don't pick visuals because they look cool — we pick them because the principle they encode (mass = bass, height = brightness, ring = pressure wave, mesh dissolution = harmonic collapse, warm vs cool = positive vs negative emotion) is either a documented cross-modal association or a direct physical analog. The "Why this choice" lines above name the principle for each mapping.

3. **The mapping is reproducible.** Run the same song through the analyzer twice, and you get the same visual and haptic output every time. The only sources of randomness are bounded cosmetic decorations (per-particle speed in ember bursts, jittered respawn positions for sparkle specks, shard placement within the horizon band) — and even those are constrained to deterministic zones. The structural mapping from musical feature to output dimension is always pure or integrative — no hidden state, no arbitrary choices, no vibe.

For a complete engineering-level reference (including exact formulas, source files, and determinism classes for all 81 individual mappings), see `MAPPINGS.csv` and `MAPPINGS_signals.csv` in the project root.

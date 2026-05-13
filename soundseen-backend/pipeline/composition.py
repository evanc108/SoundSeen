"""Composition spec builder.

Turns a SongAnalysis (raw analysis JSON) into a CompositionSpec — the
deterministic interpretation layer consumed by the renderer (Three.js)
and the iOS haptic engine. Pure function; no IO.

The spec is the single source of truth for "what should this song look
and feel like at time t." If you ever swap renderers, the spec is the
contract that survives.

Schema version is bumped whenever the spec layout changes in a way the
renderer must re-parse. Cached MP4s are keyed by (audio_hash, spec_version)
so a bump auto-invalidates the cache.

Research backing for all mapping coefficients lives in MAPPING_RESEARCH.md
in this directory. Short summary of who's cited where:
  - Palette (saturation, brightness): Valdez & Mehrabian (1994), JEP:General
  - Hue distance / analogous-vs-complementary: Schloss & Palmer (2011)
  - Biome from V/A quadrant: Russell (1980), Palmer et al. (2013)
  - Angularity (Bouba/Kiki): Adeli et al. (2014), Margiotoudi & Pulvermüller (2020)
  - Phrase-level visual tier: Krumhansl (1996), Palmer & Krumhansl (1987)
"""

from __future__ import annotations

import math
from typing import Any

# v3: per-frame timbre stream (frames_track) + per-onset pitch_class
# (derived from chroma at onset) + per-section mode (Krumhansl-Kessler
# major/minor with strength). Surfaces the Pratt 1930 pitch-elevation,
# Marks 1989 centroid-brightness, Itoh 2017 chroma-saturation, and
# dynamic Bouba/Kiki mappings into the renderer's per-frame inputs.
SPEC_VERSION = 5

# ---------------------------------------------------------------------------
# Biome model — a 4-quadrant emotion taxonomy.
# Russell (1980) circumplex; quadrant centers tuned for music after
# Palmer, Schloss, Xu & Prado-León (2013) PNAS.

_BIOME_CENTERS = {
    "euphoric":    (0.75, 0.75),  # high-V, high-A
    "serene":      (0.75, 0.25),  # high-V, low-A
    "intense":     (0.25, 0.75),  # low-V,  high-A
    "melancholic": (0.25, 0.25),  # low-V,  low-A
}

# Scene name per dominant biome. Renderer looks these up to pick which
# scene shader to load.
_BIOME_SCENE = {
    "euphoric":    "euphoric_bloom",
    "serene":      "serene_dawn",
    "intense":     "intense_storm",
    "melancholic": "melancholic_rain",
}

# Section label → camera language. Same camera moves apply across all
# biomes; biome only changes the scene's visual vocabulary.
_SECTION_CAMERA = {
    "intro":    "wide_static",
    "verse":    "slow_dolly_in",
    "pre-drop": "rapid_zoom",
    "buildup":  "rapid_zoom",
    "drop":     "explosive_zoom_out",
    "chorus":   "high_orbit",
    "bridge":   "off_axis_rotate",
    "break":    "wide_pullback",
    "outro":    "slow_fade",
}

# Section label → palette modulation MULTIPLIERS. These are layered on
# top of the V&M-derived continuous (saturation, brightness) values
# (see _vm_palette) — they capture section-specific intent that the
# raw V/A values don't.
#   intro/break/outro: still and contained; the multiplier dampens.
#   chorus/drop: amplifies the V&M baseline.
# Keep these conservative — most of the work should come from V&M.
_SECTION_PALETTE_MULT = {
    "intro":    (0.85, 0.90),
    "verse":    (1.00, 1.00),
    "pre-drop": (0.95, 0.95),
    "buildup":  (0.95, 0.95),
    "drop":     (1.20, 1.10),
    "chorus":   (1.10, 1.05),
    "bridge":   (1.00, 1.00),
    "break":    (0.75, 0.85),
    "outro":    (0.80, 0.85),
}


# ---------------------------------------------------------------------------
# Valdez & Mehrabian (1994) palette equations.
# JEP:General 123(4), 394–409. Standardized regression coefficients on PAD
# scales. Saturation drives arousal (β=+0.60), brightness counter-modulates
# (β=−0.31). Pleasure (~valence) loads primarily on brightness (β=+0.69)
# with a smaller saturation term (β=+0.22).
#
# We translate those into [0,1]-ranged palette controls. The renderer
# applies these continuously to the biome scene's anchor colors.

def _vm_palette(valence: float, arousal: float) -> tuple[float, float]:
    """Continuous (saturation, brightness) from V/A per Valdez & Mehrabian.

    Returns values in roughly [0.5, 1.0] — the renderer multiplies these
    onto the biome scene's anchor color saturations/brightnesses.

      saturation = 0.55 + 0.45·arousal       # V&M β=0.60 on arousal
      brightness = 0.90 − 0.15·arousal       # V&M β=−0.31 counter-modulation
                   + 0.10·valence            # V&M β=+0.69 on pleasure (scaled
                                             # because pleasure ≈ valence is
                                             # the dominant brightness driver
                                             # but the scene's biome anchor
                                             # already encodes most of it)
    """
    valence = max(0.0, min(1.0, valence))
    arousal = max(0.0, min(1.0, arousal))
    sat = 0.55 + 0.45 * arousal
    bri = 0.90 - 0.15 * arousal + 0.10 * valence
    return sat, bri


def _hue_distance(valence: float, arousal: float, tension: float) -> float:
    """Lever from Schloss & Palmer (2011): analogous palettes are perceived
    as more harmonious than complementary ones (this contradicts Itten's
    classical doctrine but is what the empirical data shows).

    Returns 0..1 where 0 = analogous (small hue interval between primary
    and accent) and 1 = complementary (180° apart). Renderer interpolates
    its accent hue along this axis.

    Drives the build-up/release feel: tension widens the interval (more
    visual conflict), rest collapses to analogous (resolution).
    """
    # Arousal alone underestimates this — a calm but tense passage (low A,
    # high tension from dissonance) should still widen the interval.
    raw = 0.55 * arousal + 0.45 * tension
    # Negative-valence (intense) biomes tend to live closer to the
    # complementary end even at moderate arousal — red+blue contrast is
    # part of their identity. Bias by valence inversion.
    raw += 0.10 * (1.0 - valence)
    return max(0.0, min(1.0, raw))


# ---------------------------------------------------------------------------
# Krumhansl-Kessler key/mode profiles. Same profiles the emotion pipeline
# uses (see pipeline/emotion.py:30-31) — major/minor templates that
# correlate against a song's average chroma to decide mode.
# Reference: Krumhansl & Kessler (1982), "Tracing the dynamic changes in
# perceived tonal organization in a spatial representation of musical keys."

_MAJOR_PROFILE = (6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88)
_MINOR_PROFILE = (6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17)


def _mean_chroma_vector(frames: dict[str, Any], start: float, end: float) -> list[float]:
    times = frames.get("time") or []
    chroma = frames.get("chroma") or []
    if not times or not chroma:
        return [0.0] * 12
    n = min(len(times), len(chroma))
    sums = [0.0] * 12
    count = 0
    for i in range(n):
        t = float(times[i])
        if t < start:
            continue
        if t >= end:
            break
        row = chroma[i]
        if not row:
            continue
        for j in range(min(12, len(row))):
            sums[j] += float(row[j])
        count += 1
    if count == 0:
        return [0.0] * 12
    return [s / count for s in sums]


def _detect_mode(frames: dict[str, Any], start: float, end: float) -> tuple[str, float]:
    """Krumhansl-Kessler mode detection over a section.

    Correlates the section's mean 12-bin chroma vector with rotated
    major and minor profiles, picks whichever wins. Returns
    (mode, strength) where strength in [0, 1] is how strongly the
    winning template fit relative to its rival (Pearson-like ratio).

    Major mode → warm hue bias in the renderer; minor → cool bias.
    Hevner (1937), Palmer (2013): major/fast → warm/light; minor/slow → cool/dark.
    """
    chroma_mean = _mean_chroma_vector(frames, start, end)
    if sum(chroma_mean) <= 0:
        return "major", 0.0

    def correlate(profile: tuple[float, ...], offset: int) -> float:
        # Rotate the profile to start at pitch class `offset`.
        rotated = profile[offset:] + profile[:offset]
        # Centered-correlation numerator only (denominators are ~constant
        # across rotations of the same profile, so we can shortcut).
        mp = sum(profile) / 12
        mc = sum(chroma_mean) / 12
        return sum((rotated[i] - mp) * (chroma_mean[i] - mc) for i in range(12))

    best_major = max(correlate(_MAJOR_PROFILE, k) for k in range(12))
    best_minor = max(correlate(_MINOR_PROFILE, k) for k in range(12))

    total = abs(best_major) + abs(best_minor)
    if total < 1e-9:
        return "major", 0.0
    if best_major >= best_minor:
        return "major", min(1.0, max(0.0, (best_major - best_minor) / total))
    return "minor", min(1.0, max(0.0, (best_minor - best_major) / total))


# ---------------------------------------------------------------------------
# Biome blending.

def _biome_weights(valence: float, arousal: float, tau: float = 0.25) -> dict[str, float]:
    """Softmax over negative squared distance to each quadrant center.

    tau=0.25 gives a smooth ~1s-perceived crossfade at typical EMA rates.
    Result is a probability vector that sums to 1.0.
    """
    logits = []
    names = list(_BIOME_CENTERS.keys())
    for name in names:
        cv, ca = _BIOME_CENTERS[name]
        dv = valence - cv
        da = arousal - ca
        d2 = dv * dv + da * da
        logits.append(-d2 / tau)

    max_logit = max(logits)
    exps = [math.exp(l - max_logit) for l in logits]
    total = sum(exps) or 1.0
    return {name: exps[i] / total for i, name in enumerate(names)}


def _dominant_biome(weights: dict[str, float]) -> str:
    return max(weights.items(), key=lambda kv: kv[1])[0]


# ---------------------------------------------------------------------------
# Sampling helpers.

def _emotion_at(emotion: dict[str, Any], t: float) -> tuple[float, float]:
    interval = float(emotion.get("interval", 0.5)) or 0.5
    valences = emotion.get("valence") or [0.5]
    arousals = emotion.get("arousal") or [0.5]

    idx = max(0, min(int(t / interval), len(valences) - 1))
    return float(valences[idx]), float(arousals[idx])


def _section_emotion_average(emotion: dict[str, Any], start: float, end: float) -> tuple[float, float]:
    interval = float(emotion.get("interval", 0.5)) or 0.5
    valences = emotion.get("valence") or [0.5]
    arousals = emotion.get("arousal") or [0.5]

    if not valences:
        return 0.5, 0.5

    i0 = max(0, min(int(start / interval), len(valences) - 1))
    i1 = max(i0, min(int(end / interval), len(valences) - 1))
    span = max(1, i1 - i0 + 1)
    v_sum = sum(valences[i0 : i1 + 1])
    a_sum = sum(arousals[i0 : i1 + 1])
    return v_sum / span, a_sum / span


def _section_frame_average(
    frames: dict[str, Any], field: str, start: float, end: float, default: float = 0.5
) -> float:
    """Average a per-frame array over [start, end). Returns `default` if the
    field is missing or empty (so optional timbre fields like spectral_contrast
    don't crash old cached analyses)."""
    times = frames.get("time") or []
    values = frames.get(field) or []
    if not times or not values:
        return default
    n = min(len(times), len(values))
    if n == 0:
        return default

    total = 0.0
    count = 0
    for i in range(n):
        t = float(times[i])
        if t < start:
            continue
        if t >= end:
            break
        total += float(values[i])
        count += 1
    return total / count if count > 0 else default


def _onset_attack_slope_average(
    onsets: list[dict[str, Any]], start: float, end: float, default: float = 0.5
) -> float:
    if not onsets:
        return default
    total = 0.0
    count = 0
    for o in onsets:
        t = float(o.get("time", 0.0))
        if t < start or t >= end:
            continue
        total += float(o.get("attack_slope", default))
        count += 1
    return total / count if count > 0 else default


# ---------------------------------------------------------------------------
# Tension & angularity (per-section scalars).

def _section_tension(frames: dict[str, Any], start: float, end: float) -> float:
    """Visual tension scalar in [0, 1].

    Compounds three signals:
      - flux  (high = transient/unstable)
      - 1 − harmonic_ratio  (low harmonic = percussive/dissonant)
      - 1 − spectral_contrast  (low contrast = smeared/noisy)

    Routed through Schloss & Palmer (2011) hue-distance lever in
    _hue_distance() above. Tension drives the renderer toward
    complementary-pair color treatment and away from analogous.
    """
    flux_avg = _section_frame_average(frames, "flux", start, end, default=0.3)
    hr_avg = _section_frame_average(frames, "harmonic_ratio", start, end, default=0.5)
    sc_avg = _section_frame_average(frames, "spectral_contrast", start, end, default=0.5)

    raw = 0.50 * flux_avg + 0.30 * (1 - hr_avg) + 0.20 * (1 - sc_avg)
    return max(0.0, min(1.0, raw))


def _section_angularity(
    frames: dict[str, Any], onsets: list[dict[str, Any]], start: float, end: float
) -> float:
    """Bouba/Kiki angularity scalar in [0, 1].

    Per Adeli et al. (2014) and Margiotoudi & Pulvermüller (2020):
      - High harmonic_ratio (sustained, tonal)  →  rounded
      - Low harmonic_ratio  (percussive, noisy) →  angular
      - Steep attack slope (kiki-like)          →  angular
      - Soft attack slope  (bouba-like)         →  rounded

    Renderer uses this to bias the shape vocabulary of particles,
    archetype geometry, and edge softness for the section.
    """
    hr_avg = _section_frame_average(frames, "harmonic_ratio", start, end, default=0.5)
    attack_avg = _onset_attack_slope_average(onsets, start, end, default=0.5)

    # Coefficients lifted from Heller et al. (2020) — small-N study so
    # treat as informed, not bulletproof.
    raw = 0.50 * (1 - hr_avg) + 0.40 * attack_avg
    return max(0.0, min(1.0, raw))


# ---------------------------------------------------------------------------
# Track builders.

def _build_emotion_timeline(emotion: dict[str, Any]) -> list[dict[str, Any]]:
    interval = float(emotion.get("interval", 0.5)) or 0.5
    valences = emotion.get("valence") or []
    arousals = emotion.get("arousal") or []

    out: list[dict[str, Any]] = []
    for i, v in enumerate(valences):
        a = arousals[i] if i < len(arousals) else 0.5
        weights = _biome_weights(v, a)
        sat, bri = _vm_palette(v, a)
        out.append(
            {
                "t": round(i * interval, 4),
                "valence": round(float(v), 4),
                "arousal": round(float(a), 4),
                "biome_weights": {k: round(w, 4) for k, w in weights.items()},
                # V&M-derived continuous palette modulation; renderer uses
                # this for between-section gradients without waiting for the
                # next section_script entry.
                "vm_saturation": round(sat, 4),
                "vm_brightness": round(bri, 4),
            }
        )
    return out


def _audio_arousal_boost(
    frames: dict[str, Any],
    start: float,
    end: float,
    bpm: float,
) -> float:
    """Correct for cases where the V/A regression under-estimates
    arousal on tracks the audio signature obviously says are high-energy.

    Three additive contributions, each capped:
      - spectral_flux avg     (transient density)
      - sub_bass band avg     (kick/bass presence)
      - tempo                 (BPM > 120 boosts; > 150 saturates)

    Returns a non-negative scalar in [0, 0.30] to add to arousal.
    """
    flux_avg = _section_frame_average(frames, "flux", start, end, default=0.0)

    # sub_bass = mel band index 0. _section_frame_average can't index
    # into a list-of-list field, so compute directly.
    times = frames.get("time") or []
    bands = frames.get("bands") or []
    sub_bass_total = 0.0
    sub_bass_n = 0
    for i, t in enumerate(times):
        ft = float(t)
        if ft < start or ft >= end:
            continue
        if i < len(bands) and bands[i]:
            sub_bass_total += float(bands[i][0])
            sub_bass_n += 1
    sub_bass_avg = sub_bass_total / sub_bass_n if sub_bass_n else 0.0

    tempo_factor = max(0.0, min(1.0, (bpm - 90.0) / 60.0))

    boost = flux_avg * 0.18 + sub_bass_avg * 0.12 + tempo_factor * 0.10
    return min(0.30, boost)


def _build_section_script(
    sections: list[dict[str, Any]],
    emotion: dict[str, Any],
    frames: dict[str, Any],
    onsets: list[dict[str, Any]],
    bpm: float = 0.0,
) -> list[dict[str, Any]]:
    """One directive per section: scene + camera + research-backed visual
    parameters (V&M palette, Schloss & Palmer hue distance, Bouba/Kiki
    angularity, tension)."""
    out: list[dict[str, Any]] = []
    for section in sections:
        start = float(section["start"])
        end = float(section["end"])
        label = str(section.get("label", "")).lower()
        energy_profile = str(section.get("energy_profile", ""))

        v_avg, a_avg = _section_emotion_average(emotion, start, end)
        # Audio-arousal boost: nudge arousal upward when bpm/flux/bass
        # indicate obvious high-energy that the V/A regression may have
        # under-estimated (common on EDM with neutral-V vocals).
        a_avg_corrected = min(1.0, a_avg + _audio_arousal_boost(frames, start, end, bpm))
        weights = _biome_weights(v_avg, a_avg_corrected)
        biome = _dominant_biome(weights)
        scene = _BIOME_SCENE[biome]

        camera = _SECTION_CAMERA.get(label, "slow_dolly_in")

        # V&M baseline palette × section-intent multiplier.
        vm_sat, vm_bri = _vm_palette(v_avg, a_avg)
        sat_mult, bri_mult = _SECTION_PALETTE_MULT.get(label, (1.0, 1.0))
        sat = vm_sat * sat_mult
        bri = vm_bri * bri_mult

        tension = _section_tension(frames, start, end)
        angularity = _section_angularity(frames, onsets, start, end)
        hue_dist = _hue_distance(v_avg, a_avg, tension)
        mode, mode_strength = _detect_mode(frames, start, end)

        out.append(
            {
                "start": round(start, 3),
                "end": round(end, 3),
                "label": label,
                "energy_profile": energy_profile,
                "scene": scene,
                "biome_weights": {k: round(w, 4) for k, w in weights.items()},
                "camera": camera,
                "saturation": round(sat, 3),
                "brightness": round(bri, 3),
                # v2 — research-backed structural fields.
                "tension": round(tension, 3),
                "angularity": round(angularity, 3),
                "hue_distance": round(hue_dist, 3),
                # v3 — Krumhansl-Kessler mode (Hevner 1937, Palmer 2013).
                # Major → renderer biases hue warm; minor → cool.
                "mode": mode,
                "mode_strength": round(mode_strength, 3),
            }
        )
    return out


def _build_drop_triggers(
    sections: list[dict[str, Any]], frames: dict[str, Any], emotion: dict[str, Any]
) -> list[dict[str, Any]]:
    """Two trigger types: explicit `drop` section starts, and the
    arousal+flux+energy heuristic from the iOS DropChoreography.
    Heuristic: arousal > 0.82 AND flux > 0.75 AND energy > 0.70.
    Saliency stacking justification: Itti & Koch (2001) — drops should
    co-fire luminance, motion, and color singletons; the renderer is
    responsible for the multi-channel response."""
    triggers: list[dict[str, Any]] = []
    seen_times: set[float] = set()

    for section in sections:
        if str(section.get("label", "")).lower() == "drop":
            t = round(float(section["start"]), 3)
            triggers.append({"t": t, "type": "section"})
            seen_times.add(t)

    times = frames.get("time") or []
    energies = frames.get("energy") or []
    fluxes = frames.get("flux") or []
    if times and energies and fluxes:
        last_fired = -1e9
        for i, t in enumerate(times):
            if i >= len(energies) or i >= len(fluxes):
                break
            if t - last_fired < 4.0:
                continue
            v, a = _emotion_at(emotion, t)
            if a > 0.82 and float(fluxes[i]) > 0.75 and float(energies[i]) > 0.70:
                tr = round(float(t), 3)
                if tr not in seen_times:
                    triggers.append({"t": tr, "type": "heuristic"})
                    seen_times.add(tr)
                    last_fired = t

    triggers.sort(key=lambda x: x["t"])
    return triggers


def _build_beat_track(beats: list[dict[str, Any]]) -> list[dict[str, Any]]:
    out = []
    for b in beats:
        out.append(
            {
                "t": round(float(b["time"]), 3),
                "downbeat": bool(b.get("is_downbeat", False)),
                "intensity": round(float(b.get("intensity", 0.5)), 4),
                "sharpness": round(float(b.get("sharpness", 0.5)), 4),
                "bass_intensity": round(float(b.get("bass_intensity", 0.0)), 4),
            }
        )
    return out


def _build_phrase_track(beats: list[dict[str, Any]], bars_per_phrase: int = 4) -> list[dict[str, Any]]:
    """Phrase-level tier — Krumhansl (1996), Palmer & Krumhansl (1987).

    Listener tension/segmentation responses are strongest at phrase
    boundaries (4–8 bars), not at beat or section level. This is the
    "missing tier" between beat-driven haptics and section-driven scene
    changes. Renderer uses phrases for camera-arc completion, palette
    rotation, and particle population turnover.

    Default: 4-bar phrases (one downbeat starting each bar in 4/4).
    """
    downbeats = [b for b in beats if bool(b.get("is_downbeat", False))]
    phrases: list[dict[str, Any]] = []
    for i in range(0, len(downbeats), bars_per_phrase):
        first = downbeats[i]
        last_idx = min(i + bars_per_phrase - 1, len(downbeats) - 1)
        last = downbeats[last_idx]
        phrases.append(
            {
                "t_start": round(float(first["time"]), 3),
                "t_end": round(float(last["time"]), 3),
                "phrase_index": i // bars_per_phrase,
                "bar_count": last_idx - i + 1,
            }
        )
    return phrases


def _pitch_class_at(frames: dict[str, Any], t: float) -> int:
    """Find the dominant pitch class (0..11) from the chroma vector at
    time `t`. Returns -1 if chroma is unavailable or all-zero (atonal).

    Pratt (1930) → high pitch maps to high vertical position; this is the
    field the renderer uses for that mapping. Walker et al. (2010) — also
    high pitch → smaller particle size.
    """
    times = frames.get("time") or []
    chroma = frames.get("chroma") or []
    if not times or not chroma:
        return -1
    n = min(len(times), len(chroma))
    if n == 0:
        return -1
    # Linear scan to nearest frame — onset count is small (~hundreds).
    idx = 0
    for i in range(n):
        if float(times[i]) > t:
            break
        idx = i
    row = chroma[idx]
    if not row:
        return -1
    best = -1
    best_v = -1.0
    for j in range(min(12, len(row))):
        v = float(row[j])
        if v > best_v:
            best_v = v
            best = j
    if best_v <= 1e-6:
        return -1
    return best


def _build_onset_track(
    onsets: list[dict[str, Any]], frames: dict[str, Any]
) -> list[dict[str, Any]]:
    out = []
    for o in onsets:
        t = float(o["time"])
        out.append(
            {
                "t": round(t, 3),
                "intensity": round(float(o.get("intensity", 0.3)), 4),
                "sharpness": round(float(o.get("sharpness", 0.5)), 4),
                "attack_strength": round(float(o.get("attack_strength", 0.0)), 4),
                "attack_slope": round(float(o.get("attack_slope", 0.0)), 4),
                # v2 ADSR fields (passthrough — already in OnsetEvent).
                "attack_time_ms": round(float(o.get("attack_time_ms", 10.0)), 2),
                "decay_time_ms":  round(float(o.get("decay_time_ms",  60.0)), 2),
                "sustain_level":  round(float(o.get("sustain_level",  0.4)), 4),
                # v3 — pitch class from chroma at onset time. -1 = atonal.
                "pitch_class": _pitch_class_at(frames, t),
            }
        )
    return out


def _build_frames_track(frames: dict[str, Any], target_hz: float = 10.0) -> dict[str, Any]:
    """Subsampled per-frame timbre stream the renderer consumes per
    render frame. Backend frames are at ~43Hz (~23ms); 10Hz is enough
    for visuals (smoothing covers the rest) and keeps payload size sane.

    Surfaced fields and their visual mappings:
      - centroid_norm:           Marks (1989) brightness ↔ visual luminance
      - harmonic_ratio:          Bouba/Kiki shape vocabulary
      - chroma_strength:         Itoh (2017) saturation lock-in
      - rolloff:                 high-frequency ceiling → particle altitude
      - zcr:                     sibilance / grain density
      - spectral_contrast:       edge crispness (smeared vs peaky)
      - pitch_class:             Pratt (1930) pitch-elevation argmax
    v4 additions:
      - chroma_center_x/y:       2-vector centroid of the 12-bin chroma
                                 distribution (Σ cos/sin bin × weight).
                                 Renderer reconstructs a ±10° hue offset
                                 via atan2 — chord-shape-aware without the
                                 Itoh (2017) pitch→hue rainbow pitfall.
      - mel_bands[8]:            sub_bass..ultra_high normalized energies.
                                 Drive frequency-banded particle behavior.
      - pitch_direction:         signed centroid-trend scalar in [-1, +1];
                                 +1 = rising over a short window, -1 = falling.
                                 Drives drift particle vertical bias.
      - rms:                     per-frame loudness (Spence 2011 loudness↔
                                 visual mass): bloom intensity, FOV push,
                                 grain washout, particle scale.
      - mfcc_warm:               one-pole low-pass of MFCC[1] (spectral
                                 tilt); shifts biome anchor warmer/cooler
                                 by ±8% based on instrumental timbre color.
    v5 additions:
      - spectral_flux:           per-frame spectral change rate (already
                                 computed at frame cadence; surfaced for
                                 the renderer's audio-reactive velocity
                                 field — drives rain fall speed, particle
                                 drift between onsets).
      - onset_strength_env:      continuous max-normalized onset envelope
                                 (max → 1.0). Stream of "transient pressure"
                                 between discrete onset events; lets the
                                 renderer modulate motion without waiting
                                 for an onset to fire.
    """
    times = frames.get("time") or []
    energy = frames.get("energy") or []
    if not times or not energy:
        return {"interval": 1.0 / target_hz, "count": 0,
                "centroid_norm": [], "harmonic_ratio": [], "chroma_strength": [],
                "rolloff": [], "zcr": [], "spectral_contrast": [],
                "pitch_class": [],
                "chroma_center_x": [], "chroma_center_y": [],
                "mel_bands": [],
                "pitch_direction": [],
                "rms": [],
                "mfcc_warm": [],
                "spectral_flux": [],
                "onset_strength_env": []}

    src_hz = 0.0
    if len(times) > 1:
        avg_dt = (float(times[-1]) - float(times[0])) / max(1, len(times) - 1)
        src_hz = (1.0 / avg_dt) if avg_dt > 1e-6 else 43.0
    else:
        src_hz = 43.0
    stride = max(1, int(round(src_hz / target_hz)))

    # Per-frame fields. Some (rolloff/zcr/spectral_contrast) are optional
    # in older analyses — fall back to a constant default rather than
    # rejecting the whole stream.
    centroid    = frames.get("centroid") or []
    flux        = frames.get("flux") or []
    harmonic    = frames.get("harmonic_ratio") or []
    chroma_s    = frames.get("chroma_strength") or []
    rolloff     = frames.get("rolloff") or []
    zcr         = frames.get("zcr") or []
    contrast    = frames.get("spectral_contrast") or []
    chroma_vec  = frames.get("chroma") or []
    bands_all   = frames.get("bands") or []
    mfcc_all    = frames.get("mfcc") or []
    onset_env   = frames.get("onset_env_norm") or []

    # Centroid is in raw Hz; normalize per-track to [0, 1] using p5/p95
    # so the renderer doesn't have to deal with absolute frequencies.
    sorted_c = sorted(float(x) for x in centroid)
    if len(sorted_c) >= 2:
        lo = sorted_c[max(0, int(len(sorted_c) * 0.05))]
        hi = sorted_c[min(len(sorted_c) - 1, int(len(sorted_c) * 0.95))]
        rng = hi - lo if hi > lo else 1.0
    else:
        lo, rng = 0.0, 1.0

    def _at(arr: list, i: int, default: float) -> float:
        return float(arr[i]) if i < len(arr) else default

    # Precompute the circular basis for chroma center — 12 bins around
    # the color wheel (Itoh-safe: a chord centroid, not a per-note hue).
    BIN_ANGLES = [(2.0 * math.pi * j / 12.0) for j in range(12)]
    BIN_COS = [math.cos(a) for a in BIN_ANGLES]
    BIN_SIN = [math.sin(a) for a in BIN_ANGLES]

    out_centroid: list[float] = []
    out_harmonic: list[float] = []
    out_chromas:  list[float] = []
    out_rolloff:  list[float] = []
    out_zcr:      list[float] = []
    out_contrast: list[float] = []
    out_pitch:    list[int]   = []
    out_cx:       list[float] = []
    out_cy:       list[float] = []
    out_bands:    list[list[float]] = []
    out_pdir:     list[float] = []
    out_rms:      list[float] = []
    out_mfcc_w:   list[float] = []
    out_flux:     list[float] = []
    out_onset_e:  list[float] = []

    n = len(times)
    # One-pole low-pass state for mfcc_warm. τ ≈ 1.5s; α at target_hz
    # gives the right smoothing window.
    dt = 1.0 / target_hz
    alpha = dt / (1.5 + dt)
    mfcc_w_state = 0.0
    # Pitch-direction smoothing window in subsampled frames (~0.5s).
    pdir_window = max(1, int(round(0.5 * target_hz)))
    last_centroids: list[float] = []
    for i in range(0, n, stride):
        c_norm = max(0.0, min(1.0, (_at(centroid, i, lo) - lo) / rng))
        out_centroid.append(round(c_norm, 4))
        out_harmonic.append(round(_at(harmonic, i, 0.5), 4))
        out_chromas.append(round(_at(chroma_s, i, 0.0), 4))
        out_rolloff.append(round(_at(rolloff, i, 0.5), 4))
        out_zcr.append(round(_at(zcr, i, 0.3), 4))
        out_contrast.append(round(_at(contrast, i, 0.5), 4))
        out_rms.append(round(_at(energy, i, 0.0), 4))
        out_flux.append(round(_at(flux, i, 0.0), 4))
        out_onset_e.append(round(_at(onset_env, i, 0.0), 4))

        pc = -1
        cx = 0.0
        cy = 0.0
        if i < len(chroma_vec):
            row = chroma_vec[i] or []
            best = -1
            best_v = -1.0
            total = 0.0
            for j in range(min(12, len(row))):
                v = float(row[j])
                total += v
                if v > best_v:
                    best_v = v
                    best = j
                cx += BIN_COS[j] * v
                cy += BIN_SIN[j] * v
            pc = best if best_v > 1e-6 else -1
            # Normalize so cx,cy are weighted-mean direction in [-1, 1]
            # (atan2 only cares about ratio, but length() conveys tonality).
            if total > 1e-6:
                cx /= total
                cy /= total
        out_pitch.append(pc)
        out_cx.append(round(cx, 4))
        out_cy.append(round(cy, 4))

        # 8-band mel — already normalized upstream. Fall back to zeros
        # for old analyses without the bands array.
        if i < len(bands_all) and bands_all[i] is not None:
            row_b = bands_all[i]
            band_row = [round(float(row_b[k]) if k < len(row_b) else 0.0, 4) for k in range(8)]
        else:
            band_row = [0.0] * 8
        out_bands.append(band_row)

        # Pitch direction: sign of centroid trend over last ~0.5s.
        # Centroid trending up correlates well with rising melody for
        # the visual purpose of "particles drift up on ascent."
        if len(last_centroids) >= pdir_window:
            delta = c_norm - last_centroids[-pdir_window]
            out_pdir.append(round(max(-1.0, min(1.0, delta * 6.0)), 3))
        else:
            out_pdir.append(0.0)
        last_centroids.append(c_norm)

        # MFCC[1] low-pass — spectral tilt coefficient. MFCC arrays are
        # normalized upstream to roughly [-1, 1]. Apply one-pole IIR.
        mfcc_1 = 0.0
        if i < len(mfcc_all) and mfcc_all[i] is not None:
            row_m = mfcc_all[i]
            if len(row_m) > 1:
                mfcc_1 = float(row_m[1])
        mfcc_w_state += alpha * (mfcc_1 - mfcc_w_state)
        out_mfcc_w.append(round(mfcc_w_state, 4))

    return {
        "interval": round(stride / src_hz, 4),
        "count": len(out_centroid),
        "centroid_norm":     out_centroid,
        "harmonic_ratio":    out_harmonic,
        "chroma_strength":   out_chromas,
        "rolloff":           out_rolloff,
        "zcr":               out_zcr,
        "spectral_contrast": out_contrast,
        "pitch_class":       out_pitch,
        # v4 additions.
        "chroma_center_x":   out_cx,
        "chroma_center_y":   out_cy,
        "mel_bands":         out_bands,
        "pitch_direction":   out_pdir,
        "rms":               out_rms,
        "mfcc_warm":         out_mfcc_w,
        # v5 additions.
        "spectral_flux":      out_flux,
        "onset_strength_env": out_onset_e,
    }


def build_composition_spec(
    analysis: dict[str, Any], preset: str = "default"
) -> dict[str, Any]:
    """Pure function: SongAnalysis dict → CompositionSpec dict.

    Same input always produces the same output (rounding to 3–4 decimals
    is intentional so float-precision drift across systems doesn't
    invalidate cached renders).
    """
    sections = list(analysis.get("sections") or [])
    emotion = dict(analysis.get("emotion") or {})
    frames = dict(analysis.get("frames") or {})
    beats = list(analysis.get("beat_events") or [])
    onsets = list(analysis.get("onset_events") or [])

    return {
        "spec_version": SPEC_VERSION,
        "preset": preset,
        "song_id": analysis.get("song_id"),
        "duration_seconds": float(analysis.get("duration_seconds") or 0.0),
        "bpm": float(analysis.get("bpm") or 0.0),
        "emotion_timeline": _build_emotion_timeline(emotion),
        "section_script": _build_section_script(
            sections, emotion, frames, onsets,
            bpm=float(analysis.get("bpm") or 0.0),
        ),
        "beat_track": _build_beat_track(beats),
        "phrase_track": _build_phrase_track(beats),
        "onset_track": _build_onset_track(onsets, frames),
        "drop_triggers": _build_drop_triggers(sections, frames, emotion),
        # v3 — per-frame timbre stream sampled at ~10Hz.
        "frames_track": _build_frames_track(frames, target_hz=10.0),
    }

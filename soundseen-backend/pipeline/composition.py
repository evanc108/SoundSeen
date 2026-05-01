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

# v2: adds vm_saturation/vm_brightness/hue_distance/tension/angularity to
# section directives (Valdez & Mehrabian + Schloss & Palmer + Bouba/Kiki),
# plus phrase_track (Krumhansl phrase-level tier).
SPEC_VERSION = 2

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


def _build_section_script(
    sections: list[dict[str, Any]],
    emotion: dict[str, Any],
    frames: dict[str, Any],
    onsets: list[dict[str, Any]],
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
        weights = _biome_weights(v_avg, a_avg)
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
                # New in v2 — research-backed structural fields.
                "tension": round(tension, 3),
                "angularity": round(angularity, 3),
                "hue_distance": round(hue_dist, 3),
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


def _build_onset_track(onsets: list[dict[str, Any]]) -> list[dict[str, Any]]:
    out = []
    for o in onsets:
        out.append(
            {
                "t": round(float(o["time"]), 3),
                "intensity": round(float(o.get("intensity", 0.3)), 4),
                "sharpness": round(float(o.get("sharpness", 0.5)), 4),
                "attack_strength": round(float(o.get("attack_strength", 0.0)), 4),
                "attack_slope": round(float(o.get("attack_slope", 0.0)), 4),
            }
        )
    return out


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
        "section_script": _build_section_script(sections, emotion, frames, onsets),
        "beat_track": _build_beat_track(beats),
        "phrase_track": _build_phrase_track(beats),
        "onset_track": _build_onset_track(onsets),
        "drop_triggers": _build_drop_triggers(sections, frames, emotion),
    }

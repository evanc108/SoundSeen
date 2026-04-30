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
"""

from __future__ import annotations

import math
from typing import Any

SPEC_VERSION = 1

# ---------------------------------------------------------------------------
# Biome model — a 4-quadrant emotion taxonomy.

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

# Section label → palette modulation. Multipliers applied to the biome
# scene's base saturation/brightness so the same biome reads differently
# across sections of the same song.
_SECTION_PALETTE = {
    # label:    (saturation, brightness)
    "intro":    (0.55, 0.75),
    "verse":    (1.00, 1.00),
    "pre-drop": (0.85, 0.95),
    "buildup":  (0.85, 0.95),
    "drop":     (1.30, 1.15),
    "chorus":   (1.20, 1.10),
    "bridge":   (1.05, 1.05),
    "break":    (0.65, 0.70),
    "outro":    (0.70, 0.75),
}


def _biome_weights(valence: float, arousal: float, tau: float = 0.25) -> dict[str, float]:
    """Softmax over negative squared distance to each quadrant center.

    Mirrors the iOS `BiomeWeights.compute` (which is being deleted) — same
    tau, same centers. Result is a probability vector that sums to 1.0.
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


def _emotion_at(emotion: dict[str, Any], t: float) -> tuple[float, float]:
    """Sample (valence, arousal) at time `t` from the emotion timeline.

    Falls back to (0.5, 0.5) if the timeline is empty (defensive — the
    pipeline should always produce one).
    """
    interval = float(emotion.get("interval", 0.5)) or 0.5
    valences = emotion.get("valence") or [0.5]
    arousals = emotion.get("arousal") or [0.5]

    idx = max(0, min(int(t / interval), len(valences) - 1))
    return float(valences[idx]), float(arousals[idx])


def _section_emotion_average(emotion: dict[str, Any], start: float, end: float) -> tuple[float, float]:
    """Mean (valence, arousal) across the section's timespan.

    Used to pick the scene for a section based on its overall mood, not
    the instantaneous mood at section entry — which can be misleading
    right after a transition.
    """
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


def _build_emotion_timeline(emotion: dict[str, Any]) -> list[dict[str, Any]]:
    """Flatten emotion to one row per sample with biome weights baked in."""
    interval = float(emotion.get("interval", 0.5)) or 0.5
    valences = emotion.get("valence") or []
    arousals = emotion.get("arousal") or []

    out: list[dict[str, Any]] = []
    for i, v in enumerate(valences):
        a = arousals[i] if i < len(arousals) else 0.5
        weights = _biome_weights(v, a)
        out.append(
            {
                "t": round(i * interval, 4),
                "valence": round(float(v), 4),
                "arousal": round(float(a), 4),
                "biome_weights": {k: round(w, 4) for k, w in weights.items()},
            }
        )
    return out


def _build_section_script(
    sections: list[dict[str, Any]], emotion: dict[str, Any]
) -> list[dict[str, Any]]:
    """One directive per section: scene + camera + palette modulation.

    Scene is picked from the section's *average* mood, not its entry
    instant — short transient moods at section boundaries shouldn't
    flip the visual vocabulary for the whole chorus.
    """
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
        sat, bri = _SECTION_PALETTE.get(label, (1.0, 1.0))

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
            }
        )
    return out


def _build_drop_triggers(
    sections: list[dict[str, Any]], frames: dict[str, Any], emotion: dict[str, Any]
) -> list[dict[str, Any]]:
    """Two trigger types: explicit `drop` section starts, and the
    arousal+flux+energy heuristic from the iOS DropChoreography.

    Heuristic: arousal > 0.82 AND flux > 0.75 AND energy > 0.70. The same
    rule that worked client-side for unlabeled drops.
    """
    triggers: list[dict[str, Any]] = []
    seen_times: set[float] = set()

    # Section-driven triggers — anything labeled "drop" starts a trigger.
    for section in sections:
        if str(section.get("label", "")).lower() == "drop":
            t = round(float(section["start"]), 3)
            triggers.append({"t": t, "type": "section"})
            seen_times.add(t)

    # Heuristic triggers — scan frames, dedupe within 4s windows so a
    # single sustained release doesn't fire repeatedly.
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
        "section_script": _build_section_script(sections, emotion),
        "beat_track": _build_beat_track(beats),
        "onset_track": _build_onset_track(onsets),
        "drop_triggers": _build_drop_triggers(sections, frames, emotion),
    }

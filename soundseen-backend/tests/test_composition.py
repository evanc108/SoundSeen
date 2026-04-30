"""Tests for pipeline.composition.

Verifies the CompositionSpec builder is deterministic and produces a
sensible structure from a synthetic SongAnalysis. Does not exercise
the full analysis pipeline — that's covered elsewhere.
"""

from __future__ import annotations

import math

from pipeline.composition import (
    SPEC_VERSION,
    build_composition_spec,
    _biome_weights,
    _dominant_biome,
)


def _fixture_analysis() -> dict:
    """Synthetic SongAnalysis: 6s track, 3 sections, 6 emotion samples."""
    return {
        "song_id": "test-song-001",
        "filename": "test.mp3",
        "storage_path": "songs/test-song-001/test.mp3",
        "duration_seconds": 6.0,
        "bpm": 120.0,
        "band_names": [
            "sub_bass", "bass", "low_mid", "mid",
            "upper_mid", "presence", "brilliance", "ultra_high",
        ],
        "beat_events": [
            {"time": 0.5, "intensity": 0.6, "sharpness": 0.5,
             "bass_intensity": 0.3, "is_downbeat": True},
            {"time": 1.0, "intensity": 0.4, "sharpness": 0.4,
             "bass_intensity": 0.2, "is_downbeat": False},
        ],
        "onset_events": [
            {"time": 0.7, "intensity": 0.3, "sharpness": 0.6,
             "attack_strength": 0.5, "attack_time_ms": 5.0,
             "decay_time_ms": 30.0, "sustain_level": 0.4, "attack_slope": 0.7},
        ],
        "sections": [
            {"start": 0.0, "end": 2.0, "label": "intro", "energy_profile": "building"},
            {"start": 2.0, "end": 4.0, "label": "chorus", "energy_profile": "high"},
            {"start": 4.0, "end": 6.0, "label": "drop", "energy_profile": "intense"},
        ],
        "emotion": {
            "interval": 1.0,
            "valence":  [0.30, 0.40, 0.70, 0.80, 0.55, 0.50],
            "arousal":  [0.20, 0.30, 0.70, 0.90, 0.95, 0.85],
        },
        "frames": {
            "frame_duration_ms": 23.2,
            "count": 6,
            "time":   [0.0, 1.0, 2.0, 3.0, 4.0, 5.0],
            "energy": [0.10, 0.20, 0.50, 0.85, 0.92, 0.60],
            "bands": [[0.1] * 8 for _ in range(6)],
            "centroid": [1000, 1500, 2000, 2500, 3000, 2200],
            "flux":    [0.1, 0.2, 0.4, 0.85, 0.90, 0.40],
            "hue":     [0.0] * 6,
            "chroma_strength":  [0.5] * 6,
            "harmonic_ratio":   [0.5] * 6,
        },
        "processing_time_seconds": 1.0,
    }


def test_biome_weights_normalize():
    w = _biome_weights(valence=0.5, arousal=0.5)
    assert math.isclose(sum(w.values()), 1.0, rel_tol=1e-6)
    assert set(w.keys()) == {"euphoric", "serene", "intense", "melancholic"}


def test_biome_weights_quadrant_corners():
    """At each quadrant center, that biome should dominate."""
    cases = [
        (0.75, 0.75, "euphoric"),
        (0.75, 0.25, "serene"),
        (0.25, 0.75, "intense"),
        (0.25, 0.25, "melancholic"),
    ]
    for v, a, expected in cases:
        weights = _biome_weights(v, a)
        assert _dominant_biome(weights) == expected, (
            f"({v}, {a}) should dominate {expected}, got {weights}"
        )


def test_spec_top_level_shape():
    spec = build_composition_spec(_fixture_analysis())
    assert spec["spec_version"] == SPEC_VERSION
    assert spec["preset"] == "default"
    assert spec["song_id"] == "test-song-001"
    assert spec["duration_seconds"] == 6.0
    assert spec["bpm"] == 120.0
    for key in (
        "emotion_timeline", "section_script", "beat_track",
        "onset_track", "drop_triggers",
    ):
        assert key in spec
        assert isinstance(spec[key], list)


def test_emotion_timeline_includes_biome_weights():
    spec = build_composition_spec(_fixture_analysis())
    timeline = spec["emotion_timeline"]
    assert len(timeline) == 6
    first = timeline[0]
    assert set(first.keys()) == {"t", "valence", "arousal", "biome_weights"}
    assert math.isclose(sum(first["biome_weights"].values()), 1.0, rel_tol=1e-3)
    # First sample is low V (0.30), low A (0.20) → melancholic should win.
    assert _dominant_biome(first["biome_weights"]) == "melancholic"


def test_section_script_picks_scene_per_section():
    spec = build_composition_spec(_fixture_analysis())
    script = spec["section_script"]
    assert len(script) == 3

    intro, chorus, drop = script
    # Intro is low V/A → melancholic_rain scene.
    assert intro["scene"] == "melancholic_rain"
    assert intro["camera"] == "wide_static"

    # Chorus is high V (0.7+) high A (0.7+) → euphoric_bloom.
    assert chorus["scene"] == "euphoric_bloom"
    assert chorus["camera"] == "high_orbit"

    # Drop section averaged is mid-V high-A → intense_storm or euphoric_bloom.
    assert drop["scene"] in {"euphoric_bloom", "intense_storm"}
    assert drop["camera"] == "explosive_zoom_out"


def test_beat_track_passes_through():
    spec = build_composition_spec(_fixture_analysis())
    beats = spec["beat_track"]
    assert len(beats) == 2
    assert beats[0]["downbeat"] is True
    assert beats[0]["t"] == 0.5
    assert beats[1]["downbeat"] is False


def test_drop_triggers_include_section_and_heuristic():
    spec = build_composition_spec(_fixture_analysis())
    triggers = spec["drop_triggers"]
    types = {tr["type"] for tr in triggers}
    # The "drop" section at t=4.0 must produce a section trigger.
    assert "section" in types
    section_triggers = [tr for tr in triggers if tr["type"] == "section"]
    assert section_triggers[0]["t"] == 4.0


def test_deterministic():
    """Same input → byte-identical output (modulo dict ordering)."""
    a = build_composition_spec(_fixture_analysis())
    b = build_composition_spec(_fixture_analysis())
    assert a == b


def test_handles_missing_optional_fields():
    """Backward-compat: minimal SongAnalysis without timbre fields still parses."""
    minimal = _fixture_analysis()
    minimal["frames"].pop("flux", None)
    minimal["onset_events"] = []
    spec = build_composition_spec(minimal)
    assert spec["onset_track"] == []
    # No flux = no heuristic triggers, only section ones.
    assert all(tr["type"] == "section" for tr in spec["drop_triggers"])

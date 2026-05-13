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
    _vm_palette,
    _hue_distance,
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
        "phrase_track", "onset_track", "drop_triggers",
    ):
        assert key in spec
        assert isinstance(spec[key], list)
    # v3: frames_track is a dict, not a list.
    assert "frames_track" in spec
    assert isinstance(spec["frames_track"], dict)


def test_v3_section_includes_mode():
    """Each section directive carries Krumhansl-Kessler mode + strength."""
    spec = build_composition_spec(_fixture_analysis())
    for section in spec["section_script"]:
        assert section["mode"] in {"major", "minor"}
        assert 0.0 <= section["mode_strength"] <= 1.0


def test_v3_onset_includes_pitch_and_adsr():
    """Each onset carries pitch_class (or -1) plus ADSR passthrough."""
    spec = build_composition_spec(_fixture_analysis())
    onset = spec["onset_track"][0]
    assert "pitch_class" in onset
    assert -1 <= onset["pitch_class"] <= 11
    for key in ("attack_time_ms", "decay_time_ms", "sustain_level"):
        assert key in onset


def test_v3_frames_track_is_subsampled_columnar():
    """frames_track is a dict-of-arrays at ~10Hz with all timbre fields."""
    spec = build_composition_spec(_fixture_analysis())
    ft = spec["frames_track"]
    assert ft["count"] == len(ft["centroid_norm"])
    for key in (
        "centroid_norm", "harmonic_ratio", "chroma_strength",
        "rolloff", "zcr", "spectral_contrast", "pitch_class",
    ):
        assert key in ft
        assert len(ft[key]) == ft["count"]
    for v in ft["centroid_norm"]:
        assert 0.0 <= v <= 1.0


def test_emotion_timeline_includes_biome_weights_and_vm_palette():
    spec = build_composition_spec(_fixture_analysis())
    timeline = spec["emotion_timeline"]
    assert len(timeline) == 6
    first = timeline[0]
    # v2: emotion samples carry V&M-derived continuous palette modulation.
    assert set(first.keys()) == {
        "t", "valence", "arousal", "biome_weights",
        "vm_saturation", "vm_brightness",
    }
    assert math.isclose(sum(first["biome_weights"].values()), 1.0, rel_tol=1e-3)
    # First sample is low V (0.30), low A (0.20) → melancholic should win.
    assert _dominant_biome(first["biome_weights"]) == "melancholic"
    # First sample low arousal → low saturation, brightness near peak (V&M).
    assert first["vm_saturation"] < 0.7
    assert first["vm_brightness"] > 0.85


def test_vm_palette_research_anchors():
    """Verify Valdez & Mehrabian regression equations are honored at the
    quadrant centers. β=0.60 saturation→arousal, β=−0.31 brightness→arousal,
    β=+0.69 brightness→pleasure (scaled into our coefficient as 0.10)."""
    # Euphoric (V=0.75, A=0.75): high S, mid B (high arousal counter-mods B).
    s, b = _vm_palette(0.75, 0.75)
    assert s > 0.85, f"Euphoric should be highly saturated, got {s}"
    assert b < 0.92, f"Euphoric brightness should be moderated by arousal, got {b}"

    # Serene (V=0.75, A=0.25): low-mid S, high B.
    s, b = _vm_palette(0.75, 0.25)
    assert s < 0.75
    assert b > 0.90

    # Melancholic (V=0.25, A=0.25): low-mid S, lowest B.
    s, b = _vm_palette(0.25, 0.25)
    assert s < 0.75
    # Lowest brightness in the quadrant set (low V → no pleasure boost).
    s_serene, b_serene = _vm_palette(0.75, 0.25)
    assert b < b_serene

    # Intense (V=0.25, A=0.75): high S, low B.
    s, b = _vm_palette(0.25, 0.75)
    assert s > 0.85
    assert b < 0.85


def test_hue_distance_widens_with_tension():
    """Schloss & Palmer (2011): tension lever should widen hue distance
    toward complementary; rest collapses to analogous."""
    rest  = _hue_distance(valence=0.7, arousal=0.2, tension=0.1)
    storm = _hue_distance(valence=0.3, arousal=0.9, tension=0.8)
    assert storm > rest
    assert rest < 0.40   # near analogous
    assert storm > 0.70  # near complementary


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


def test_section_directives_carry_research_fields():
    """v2 schema: tension, angularity, hue_distance per section."""
    spec = build_composition_spec(_fixture_analysis())
    for section in spec["section_script"]:
        assert "tension" in section
        assert "angularity" in section
        assert "hue_distance" in section
        for key in ("tension", "angularity", "hue_distance"):
            assert 0.0 <= section[key] <= 1.0, f"{key} out of range: {section[key]}"


def test_phrase_track_groups_downbeats():
    """Phrase tier (Krumhansl): groups downbeats into 4-bar phrases."""
    # Inject 8 downbeats so we get 2 full 4-bar phrases.
    fixture = _fixture_analysis()
    fixture["beat_events"] = [
        {"time": 0.5 * i, "intensity": 0.6, "sharpness": 0.5,
         "bass_intensity": 0.3, "is_downbeat": True}
        for i in range(8)
    ]
    spec = build_composition_spec(fixture)
    phrases = spec["phrase_track"]
    assert len(phrases) == 2
    assert phrases[0]["phrase_index"] == 0
    assert phrases[0]["bar_count"] == 4
    assert phrases[1]["phrase_index"] == 1
    assert phrases[0]["t_start"] == 0.0
    assert phrases[1]["t_start"] == 2.0  # 5th downbeat at 0.5*4 = 2.0


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

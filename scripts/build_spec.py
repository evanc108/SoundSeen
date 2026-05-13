#!/usr/bin/env python3
"""Run analysis + composition pipeline locally — produce a CompositionSpec
JSON without going through HTTP/Supabase. Used for local renderer testing.

Usage:
  scripts/build_spec.py path/to/audio.mp3 path/to/out-spec.json [--preset default]
"""

from __future__ import annotations

import argparse
import json
import os
import sys

# Make backend imports work from any cwd.
HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.abspath(os.path.join(HERE, "..", "soundseen-backend"))
sys.path.insert(0, BACKEND)

from pipeline.composition import build_composition_spec  # noqa: E402
from pipeline.emotion import analyze_emotion  # noqa: E402
from pipeline.loader import load_audio  # noqa: E402
from pipeline.rhythm import analyze_rhythm  # noqa: E402
from pipeline.segmenter import build_emotion_timeline, build_frames  # noqa: E402
from pipeline.spectral import BAND_NAMES, analyze_spectral  # noqa: E402
from pipeline.structure import analyze_structure  # noqa: E402


def run(audio_path: str, preset: str) -> dict:
    with open(audio_path, "rb") as f:
        file_bytes = f.read()
    ext = "." + audio_path.rsplit(".", 1)[-1].lower()
    y, sr, duration = load_audio(file_bytes, suffix=ext)
    spectral = analyze_spectral(y, sr)
    rhythm = analyze_rhythm(y, sr, spectral)
    emotion_segments = analyze_emotion(y, sr, duration, spectral=spectral)
    sections = analyze_structure(y, sr, spectral)
    emotion = build_emotion_timeline(duration, emotion_segments)
    frames = build_frames(spectral, duration)
    # Mirror main.py: thread the continuous onset envelope onto frames
    # so _build_frames_track can subsample it into the v5 spec.
    frames["onset_env_norm"] = rhythm.get("onset_env_norm", [])
    analysis = {
        "duration_seconds": round(duration, 1),
        "bpm": rhythm["bpm"],
        "band_names": list(BAND_NAMES),
        "beat_events": rhythm["beat_events"],
        "onset_events": rhythm["onset_events"],
        "sections": sections,
        "emotion": emotion,
        "frames": frames,
    }
    return build_composition_spec(analysis, preset=preset)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("audio")
    ap.add_argument("out_spec")
    ap.add_argument("--preset", default="default")
    args = ap.parse_args()

    spec = run(args.audio, args.preset)
    with open(args.out_spec, "w") as f:
        json.dump(spec, f)
    n_sections = len(spec.get("section_script") or [])
    n_beats = len(spec.get("beat_track") or [])
    n_onsets = len(spec.get("onset_track") or [])
    print(f"wrote {args.out_spec}  "
          f"({spec.get('duration_seconds'):.1f}s, "
          f"{round(spec.get('bpm') or 0)} BPM, "
          f"{n_sections} sections, {n_beats} beats, {n_onsets} onsets)")


if __name__ == "__main__":
    main()

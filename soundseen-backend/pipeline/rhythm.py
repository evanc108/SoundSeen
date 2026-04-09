import numpy as np
import librosa


def _frame_value_at_time(t: float, arr: np.ndarray, sr: int, hop_length: int) -> float:
    """Get the interpolated value of a frame-level array at a given time."""
    frame = librosa.time_to_frames(t, sr=sr, hop_length=hop_length)
    frame = min(frame, len(arr) - 1)
    return float(arr[frame])


def _compute_envelope(
    rms: np.ndarray,
    onset_time: float,
    sr: int,
    hop_length: int,
    window_ms: float = 200.0,
) -> dict:
    """Compute attack/decay envelope shape around an onset.

    Returns attack_time_ms, decay_time_ms, sustain_level, attack_slope.
    """
    onset_frame = librosa.time_to_frames(onset_time, sr=sr, hop_length=hop_length)
    onset_frame = min(onset_frame, len(rms) - 1)

    # Window size in frames
    window_frames = int((window_ms / 1000.0) * sr / hop_length)
    ms_per_frame = (hop_length / sr) * 1000.0

    # Search for peak after onset (within window)
    end_search = min(onset_frame + window_frames, len(rms))
    if onset_frame >= end_search:
        return {"attack_time_ms": 0.0, "decay_time_ms": 0.0, "sustain_level": 0.0, "attack_slope": 0.0}

    segment = rms[onset_frame:end_search]
    peak_offset = int(np.argmax(segment))
    peak_value = float(segment[peak_offset])
    onset_value = float(rms[onset_frame])

    # Attack time: onset to peak
    attack_time_ms = round(peak_offset * ms_per_frame, 1)

    # Attack slope: how steep the rise is (0 = flat, 1 = instantaneous)
    if attack_time_ms > 0 and peak_value > onset_value:
        # Normalize: slope of 1.0 means full amplitude in 1 frame
        raw_slope = (peak_value - onset_value) / (peak_offset + 1)
        attack_slope = float(np.clip(raw_slope / 0.3, 0.0, 1.0))  # 0.3 is steep reference
    else:
        attack_slope = 1.0  # instantaneous attack

    # Decay: from peak to half-peak (or end of window)
    post_peak = rms[onset_frame + peak_offset:end_search]
    half_peak = peak_value * 0.5
    decay_frames = 0
    for j, val in enumerate(post_peak):
        if val < half_peak:
            decay_frames = j
            break
    else:
        decay_frames = len(post_peak)
    decay_time_ms = round(decay_frames * ms_per_frame, 1)

    # Sustain level: average energy in the latter half of the window (relative to peak)
    latter_half = rms[onset_frame + window_frames // 2:end_search]
    if len(latter_half) > 0 and peak_value > 1e-10:
        sustain_level = float(np.clip(np.mean(latter_half) / peak_value, 0.0, 1.0))
    else:
        sustain_level = 0.0

    return {
        "attack_time_ms": attack_time_ms,
        "decay_time_ms": decay_time_ms,
        "sustain_level": round(sustain_level, 4),
        "attack_slope": round(attack_slope, 4),
    }


def analyze_rhythm(y: np.ndarray, sr: int, spectral: dict) -> dict:
    """Beat tracking, onset detection, and per-event haptic features.

    Returns bpm, beats, onsets, beat_events, onset_events.
    beat_events and onset_events carry per-event intensity/sharpness for
    precise CoreHaptics event construction on iOS.
    onset_events also include envelope shape (attack/decay) for haptic curves.
    """
    tempo, beat_frames = librosa.beat.beat_track(y=y, sr=sr)
    beat_times = librosa.frames_to_time(beat_frames, sr=sr)
    onset_times = librosa.onset.onset_detect(y=y, sr=sr, units="time")

    # Onset strength envelope for per-event intensity weighting
    onset_env = librosa.onset.onset_strength(y=y, sr=sr)
    onset_env_norm = onset_env / (onset_env.max() + 1e-10)

    hop = spectral["hop_length"]
    rms_norm = spectral["rms_norm"]
    rms_raw = spectral["rms_raw"]
    centroid_norm = spectral["spectral_centroid_norm"]
    bass_norm = spectral["bass_energy_norm"]

    bpm = round(float(np.atleast_1d(tempo)[0]), 1)

    beat_events = []
    for idx, t in enumerate(beat_times):
        intensity = _frame_value_at_time(t, rms_norm, sr, hop)
        sharpness = _frame_value_at_time(t, centroid_norm, sr, hop)
        bass = _frame_value_at_time(t, bass_norm, sr, hop)
        beat_events.append({
            "time": round(float(t), 3),
            "intensity": round(intensity, 4),
            "sharpness": round(sharpness, 4),
            "bass_intensity": round(bass, 4),
            "is_downbeat": idx % 4 == 0,
        })

    onset_events = []
    for t in onset_times:
        intensity = _frame_value_at_time(t, rms_norm, sr, hop)
        sharpness = _frame_value_at_time(t, centroid_norm, sr, hop)
        onset_frame = librosa.time_to_frames(t, sr=sr, hop_length=hop)
        onset_frame = min(onset_frame, len(onset_env_norm) - 1)
        attack_strength = float(onset_env_norm[onset_frame])

        # Envelope analysis for haptic curve shaping
        envelope = _compute_envelope(rms_raw, t, sr, hop)

        onset_events.append({
            "time": round(float(t), 3),
            "intensity": round(intensity, 4),
            "sharpness": round(sharpness, 4),
            "attack_strength": round(attack_strength, 4),
            **envelope,
        })

    return {
        "bpm": bpm,
        "beats": [round(float(t), 3) for t in beat_times],
        "onsets": [round(float(t), 3) for t in onset_times],
        "beat_events": beat_events,
        "onset_events": onset_events,
    }

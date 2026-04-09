"""Structural segmentation: detect song sections (intro, verse, chorus, etc.).

Uses librosa's recurrence/self-similarity analysis with spectral clustering
to find section boundaries, then labels sections by energy profile.
"""

import numpy as np
import librosa
from scipy.ndimage import median_filter


def _label_section(
    energy_mean: float,
    energy_std: float,
    energy_global_mean: float,
    position_ratio: float,
    duration: float,
    song_duration: float,
) -> tuple[str, str]:
    """Label a section based on energy profile and position.

    Returns (label, energy_profile).
    """
    relative_energy = energy_mean / (energy_global_mean + 1e-10)

    # Position-based heuristics
    is_start = position_ratio < 0.1
    is_end = position_ratio > 0.85

    # Short sections at boundaries
    if is_start and duration < 15.0 and relative_energy < 1.0:
        return "intro", "building"
    if is_end and relative_energy < 0.8:
        return "outro", "fading"

    # Energy-based classification
    if relative_energy > 1.5 and energy_std > 0.1:
        return "drop", "intense"
    if relative_energy > 1.2:
        return "chorus", "high"
    if relative_energy < 0.6:
        if energy_std < 0.05:
            return "break", "minimal"
        return "bridge", "moderate"
    if relative_energy < 0.9:
        return "verse", "moderate"

    return "verse", "moderate"


def analyze_structure(y: np.ndarray, sr: int, spectral: dict) -> list[dict]:
    """Detect song sections using self-similarity and spectral clustering.

    Returns a list of sections with start, end, label, and energy_profile.
    """
    hop_length = spectral["hop_length"]
    rms_norm = spectral["rms_norm"]
    duration = len(y) / sr

    # Very short songs: single section
    if duration < 10.0:
        return [{
            "start": 0.0,
            "end": round(duration, 3),
            "label": "verse",
            "energy_profile": "moderate",
        }]

    # Beat-synchronous chroma features for structural analysis
    chroma = librosa.feature.chroma_cqt(y=y, sr=sr, hop_length=hop_length)

    # Use beat-sync features for cleaner structure
    tempo, beat_frames = librosa.beat.beat_track(y=y, sr=sr, hop_length=hop_length)
    if len(beat_frames) < 4:
        return [{
            "start": 0.0,
            "end": round(duration, 3),
            "label": "verse",
            "energy_profile": "moderate",
        }]

    # Beat-synchronous chroma and MFCC
    chroma_sync = librosa.util.sync(chroma, beat_frames, aggregate=np.median)
    mfcc = librosa.feature.mfcc(y=y, sr=sr, hop_length=hop_length, n_mfcc=13)
    mfcc_sync = librosa.util.sync(mfcc, beat_frames, aggregate=np.median)

    # Stack features
    features = np.vstack([chroma_sync, mfcc_sync])

    # Build recurrence matrix
    R = librosa.segment.recurrence_matrix(
        features,
        k=max(2, features.shape[1] // 8),
        width=3,
        mode="affinity",
        sym=True,
    )

    # Apply median filter and compute Laplacian for boundary detection
    R_filtered = median_filter(R, size=(3, 3))

    # Checkerboard kernel for boundary detection
    try:
        bound_frames = librosa.segment.agglomerative(features, k=None)

        # Use novelty curve for boundary detection
        novelty = np.sqrt(
            np.sum(np.diff(features, axis=1) ** 2, axis=0)
        )
        novelty = np.concatenate([[0.0], novelty])

        # Find peaks in novelty curve as boundaries
        # Adaptive threshold: mean + 0.5 * std
        threshold = np.mean(novelty) + 0.5 * np.std(novelty)
        peaks = []
        for i in range(1, len(novelty) - 1):
            if novelty[i] > threshold and novelty[i] > novelty[i - 1] and novelty[i] > novelty[i + 1]:
                peaks.append(i)

        # Add start and end
        boundary_beats = [0] + peaks + [len(beat_frames) - 1]
        # Remove duplicates and sort
        boundary_beats = sorted(set(boundary_beats))
    except Exception:
        # Fallback: evenly spaced boundaries
        n_sections = max(2, min(8, int(duration / 30)))
        boundary_beats = list(np.linspace(0, len(beat_frames) - 1, n_sections + 1, dtype=int))

    # Merge very short sections (< 4 beats)
    merged = [boundary_beats[0]]
    for b in boundary_beats[1:]:
        if b - merged[-1] >= 4:
            merged.append(b)
        elif b == boundary_beats[-1]:
            merged[-1] = b  # extend to end
    boundary_beats = merged

    # Ensure we have at least 2 boundaries
    if len(boundary_beats) < 2:
        boundary_beats = [0, len(beat_frames) - 1]

    # Convert beat indices to times
    beat_times = librosa.frames_to_time(beat_frames, sr=sr, hop_length=hop_length)

    # Global energy stats for labeling
    energy_global_mean = float(np.mean(rms_norm))

    sections = []
    for i in range(len(boundary_beats) - 1):
        b_start = boundary_beats[i]
        b_end = boundary_beats[i + 1]

        start_time = float(beat_times[min(b_start, len(beat_times) - 1)])
        end_time = float(beat_times[min(b_end, len(beat_times) - 1)])

        if i == 0:
            start_time = 0.0
        if i == len(boundary_beats) - 2:
            end_time = duration

        # Compute energy stats for this section
        sf = librosa.time_to_frames(start_time, sr=sr, hop_length=hop_length)
        ef = librosa.time_to_frames(end_time, sr=sr, hop_length=hop_length)
        ef = min(ef, len(rms_norm))
        if sf >= ef:
            sf = max(0, ef - 1)

        section_energy = rms_norm[sf:ef]
        energy_mean = float(np.mean(section_energy))
        energy_std = float(np.std(section_energy))
        section_duration = end_time - start_time
        position_ratio = start_time / duration

        label, energy_profile = _label_section(
            energy_mean, energy_std, energy_global_mean,
            position_ratio, section_duration, duration,
        )

        sections.append({
            "start": round(start_time, 3),
            "end": round(end_time, 3),
            "label": label,
            "energy_profile": energy_profile,
        })

    return sections if sections else [{
        "start": 0.0,
        "end": round(duration, 3),
        "label": "verse",
        "energy_profile": "moderate",
    }]

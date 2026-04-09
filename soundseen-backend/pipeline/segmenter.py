import numpy as np
import librosa

from pipeline.spectral import BAND_NAMES


def build_emotion_timeline(
    duration: float,
    emotion_segments: list[dict],
) -> dict:
    """Build compact emotion timeline — just valence/arousal arrays at 0.5s intervals.

    Everything else that was in segments is either in frames (higher res)
    or derivable from sections/events on the client.
    """
    interval = emotion_segments[1]["start"] - emotion_segments[0]["start"] if len(emotion_segments) > 1 else 0.5
    return {
        "interval": interval,
        "valence": [round(e["valence"], 2) for e in emotion_segments],
        "arousal": [round(e["arousal"], 2) for e in emotion_segments],
    }


def build_frames(spectral: dict, duration: float) -> dict:
    """Build per-frame data in columnar format (~23ms resolution).

    Returns parallel arrays instead of array-of-objects
    to minimize JSON size.
    """
    hop_length = spectral["hop_length"]
    sr = spectral["sr"]
    n_frames = len(spectral["rms_norm"])

    rms = spectral["rms_norm"]
    centroid = spectral["spectral_centroid_norm"]
    flux = spectral["spectral_flux_norm"]
    hue = spectral["chroma_hue"]
    chroma_str = spectral["chroma_strength_norm"]
    harmonic = spectral["harmonic_ratio"]
    band_norms = spectral["band_energies_norm"]

    times = []
    energies = []
    bands_all = []
    centroids = []
    fluxes = []
    hues = []
    chroma_strengths = []
    harmonic_ratios = []

    for i in range(n_frames):
        t = librosa.frames_to_time(i, sr=sr, hop_length=hop_length)
        if t > duration:
            break

        times.append(round(float(t), 3))
        energies.append(round(float(rms[i]), 2))
        bands_all.append([round(float(band_norms[name][i]), 2) for name in BAND_NAMES])
        centroids.append(round(float(centroid[i]), 2))
        fluxes.append(round(float(flux[i]) if i < len(flux) else 0.0, 2))
        hues.append(round(float(hue[i]) if i < len(hue) else 0.0, 1))
        chroma_strengths.append(round(float(chroma_str[i]), 2))
        harmonic_ratios.append(round(float(harmonic[i]) if i < len(harmonic) else 0.5, 2))

    return {
        "frame_duration_ms": round(hop_length / sr * 1000, 1),
        "count": len(times),
        "time": times,
        "energy": energies,
        "bands": bands_all,
        "centroid": centroids,
        "flux": fluxes,
        "hue": hues,
        "chroma_strength": chroma_strengths,
        "harmonic_ratio": harmonic_ratios,
    }

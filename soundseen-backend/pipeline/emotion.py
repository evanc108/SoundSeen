"""Emotion classification using spectral-derived heuristics.

Computes valence and arousal per segment from spectral features without
requiring external ML models. When Essentia models are available, they
take priority for more accurate classification.
"""

import logging
from pathlib import Path

import numpy as np
import librosa

logger = logging.getLogger(__name__)

MOOD_MODELS = [
    "mood_happy",
    "mood_sad",
    "mood_aggressive",
    "mood_relaxed",
    "mood_party",
    "mood_acoustic",
    "mood_electronic",
]

_loaded_models: dict | None = None

# Major and minor chroma profiles for mode detection
# Krumhansl-Kessler key profiles
_MAJOR_PROFILE = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
_MINOR_PROFILE = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])


def load_models(model_dir: str) -> bool:
    """Load all Essentia mood models from model_dir. Returns True if successful."""
    global _loaded_models
    model_path = Path(model_dir)

    missing = []
    for name in MOOD_MODELS:
        pb_file = model_path / f"{name}-musicnn-msd-2.pb"
        if not pb_file.exists():
            missing.append(str(pb_file))

    if missing:
        logger.warning(
            "Essentia models not found, using spectral-derived emotion. Missing: %s",
            missing,
        )
        _loaded_models = None
        return False

    try:
        from essentia.standard import TensorflowPredictMusiCNN

        _loaded_models = {}
        for name in MOOD_MODELS:
            pb_file = model_path / f"{name}-musicnn-msd-2.pb"
            _loaded_models[name] = TensorflowPredictMusiCNN(
                graphFilename=str(pb_file), output="model/Sigmoid"
            )
        logger.info("Loaded %d Essentia mood models from %s", len(_loaded_models), model_dir)
        return True
    except Exception:
        logger.exception("Failed to load Essentia models")
        _loaded_models = None
        return False


def models_loaded() -> bool:
    return _loaded_models is not None


def _compute_valence_arousal(mood_scores: dict[str, float]) -> tuple[float, float]:
    """Compute valence and arousal from mood scores."""
    valence = (
        mood_scores["mood_happy"] * 0.5
        + mood_scores["mood_relaxed"] * 0.3
        + mood_scores["mood_acoustic"] * 0.2
    ) - (
        mood_scores["mood_sad"] * 0.5
        + mood_scores["mood_aggressive"] * 0.3
    )
    valence = float(np.clip(valence, 0.0, 1.0))

    arousal = (
        mood_scores["mood_party"] * 0.4
        + mood_scores["mood_aggressive"] * 0.3
        + mood_scores["mood_electronic"] * 0.3
    ) - (
        mood_scores["mood_relaxed"] * 0.5
        + mood_scores["mood_acoustic"] * 0.3
    )
    arousal = float(np.clip(arousal, 0.0, 1.0))

    return valence, arousal


def _detect_mode(chroma_segment: np.ndarray) -> float:
    """Detect major vs minor mode from chroma. Returns 0-1 (0=minor, 1=major)."""
    # Average chroma across frames in this segment
    chroma_avg = np.mean(chroma_segment, axis=1)  # shape: (12,)
    if chroma_avg.sum() < 1e-10:
        return 0.5

    # Correlate with major and minor profiles for all 12 possible keys
    best_major = -1.0
    best_minor = -1.0
    for shift in range(12):
        rolled = np.roll(chroma_avg, -shift)
        major_corr = np.corrcoef(rolled, _MAJOR_PROFILE)[0, 1]
        minor_corr = np.corrcoef(rolled, _MINOR_PROFILE)[0, 1]
        best_major = max(best_major, major_corr)
        best_minor = max(best_minor, minor_corr)

    # Normalize to 0-1 range: higher = more major
    if best_major + best_minor < 1e-10:
        return 0.5
    return float(best_major / (best_major + best_minor))


def _spectral_emotion(
    y: np.ndarray,
    sr: int,
    duration: float,
    spectral: dict,
) -> list[dict]:
    """Derive emotion from spectral features using research-backed heuristics.

    Uses:
    - Mode detection (major/minor) for valence
    - Spectral brightness for valence
    - RMS energy for arousal
    - Onset density for arousal
    - Spectral flux for arousal
    - Spectral centroid for valence modulation
    """
    segment_duration = 0.5  # Match segment resolution
    num_segments = int(np.ceil(duration / segment_duration))
    hop_length = spectral["hop_length"]

    rms_norm = spectral["rms_norm"]
    centroid_norm = spectral["spectral_centroid_norm"]
    flux_norm = spectral["spectral_flux_norm"]
    chroma = spectral["chroma"]

    # Onset density per segment
    onset_env = librosa.onset.onset_strength(y=y, sr=sr, hop_length=hop_length)
    onset_env_norm = onset_env / (onset_env.max() + 1e-10)

    results = []
    for i in range(num_segments):
        start = i * segment_duration
        end = min((i + 1) * segment_duration, duration)

        sf = librosa.time_to_frames(start, sr=sr, hop_length=hop_length)
        ef = librosa.time_to_frames(end, sr=sr, hop_length=hop_length)
        ef = min(ef, len(rms_norm))
        if sf >= ef:
            sf = max(0, ef - 1)
        sl = slice(sf, ef)

        # Arousal components
        energy = float(np.mean(rms_norm[sl]))
        onset_density = float(np.mean(onset_env_norm[sf:min(ef, len(onset_env_norm))]))
        brightness = float(np.mean(centroid_norm[sl]))
        flux = float(np.mean(flux_norm[sf:min(ef, len(flux_norm))]))

        arousal = (
            energy * 0.30
            + onset_density * 0.25
            + brightness * 0.20
            + flux * 0.25
        )
        arousal = float(np.clip(arousal, 0.0, 1.0))

        # Valence components
        chroma_seg = chroma[:, sf:ef] if ef <= chroma.shape[1] else chroma[:, sf:]
        mode_score = _detect_mode(chroma_seg) if chroma_seg.shape[1] > 0 else 0.5

        valence = (
            mode_score * 0.40
            + brightness * 0.30
            + (1.0 - flux * 0.5) * 0.15  # low flux = more calm/positive
            + energy * 0.15  # some energy contributes to positive feel
        )
        valence = float(np.clip(valence, 0.0, 1.0))

        results.append({
            "start": round(start, 3),
            "end": round(end, 3),
            "valence": round(valence, 4),
            "arousal": round(arousal, 4),
        })

    return results


def analyze_chunk(y: np.ndarray, sr: int) -> tuple[float, float]:
    """Compute (valence, arousal) for a short (~2s) chunk.

    Lightweight path for live microphone input — skips HPSS and Essentia
    to keep per-call cost <100ms and memory <20MB. Uses the same weightings
    as `_spectral_emotion` but on a single window, with chunk-local
    normalization (no whole-song context available).
    """
    hop_length = 512
    frame_length = 2048

    rms = librosa.feature.rms(y=y, frame_length=frame_length, hop_length=hop_length)[0]
    centroid = librosa.feature.spectral_centroid(y=y, sr=sr, hop_length=hop_length)[0]

    S = np.abs(librosa.stft(y=y, hop_length=hop_length, n_fft=frame_length))
    flux = np.sqrt(np.sum(np.diff(S, axis=1) ** 2, axis=0))
    flux = np.concatenate([[0.0], flux])
    del S

    onset_env = librosa.onset.onset_strength(y=y, sr=sr, hop_length=hop_length)
    chroma = librosa.feature.chroma_stft(y=y, sr=sr, hop_length=hop_length, n_fft=frame_length)

    # Chunk-local scaling: map each feature into [0, 1] using its own
    # min/max over the window. Not identical to whole-song normalization,
    # but the weightings below read correctly in relative terms.
    def _scale(a: np.ndarray) -> float:
        if a.size == 0:
            return 0.0
        lo, hi = float(a.min()), float(a.max())
        if hi - lo < 1e-10:
            return 0.5
        return float(np.clip((a.mean() - lo) / (hi - lo), 0.0, 1.0))

    # Absolute-energy tempered by RMS mean (prevents a silent chunk from
    # reading as "high energy" just because _scale always centers on 0.5).
    rms_abs = float(np.clip(np.mean(rms) * 4.0, 0.0, 1.0))
    onset_env_max = float(onset_env.max())
    onset_density = (
        float(np.mean(onset_env) / onset_env_max) if onset_env_max > 1e-10 else 0.0
    )
    brightness = _scale(centroid)
    flux_mean = _scale(flux)

    arousal = (
        rms_abs * 0.30
        + onset_density * 0.25
        + brightness * 0.20
        + flux_mean * 0.25
    )
    arousal = float(np.clip(arousal, 0.0, 1.0))

    mode_score = _detect_mode(chroma) if chroma.size > 0 else 0.5
    valence = (
        mode_score * 0.40
        + brightness * 0.30
        + (1.0 - flux_mean * 0.5) * 0.15
        + rms_abs * 0.15
    )
    valence = float(np.clip(valence, 0.0, 1.0))

    return valence, arousal


def analyze_emotion(
    y: np.ndarray,
    sr: int,
    duration: float,
    spectral: dict | None = None,
) -> list[dict]:
    """Run emotion classification. Returns per-segment valence/arousal.

    If Essentia models are loaded, uses them (2s resolution).
    Otherwise, uses spectral-derived heuristics (0.5s resolution).
    """
    # Use spectral-derived emotion when models aren't available
    if _loaded_models is None:
        if spectral is not None:
            return _spectral_emotion(y, sr, duration, spectral)
        # Fallback stub if no spectral data provided
        segment_duration = 0.5
        num_segments = int(np.ceil(duration / segment_duration))
        return [
            {
                "start": round(i * segment_duration, 3),
                "end": round(min((i + 1) * segment_duration, duration), 3),
                "valence": 0.5,
                "arousal": 0.4,
            }
            for i in range(num_segments)
        ]

    # Real Essentia inference at 2s resolution
    segment_duration = 2.0
    num_segments = int(np.ceil(duration / segment_duration))
    results = []

    from essentia.standard import MonoLoader
    import tempfile, os

    for i in range(num_segments):
        start = i * segment_duration
        end = min((i + 1) * segment_duration, duration)
        start_sample = int(start * sr)
        end_sample = min(int(end * sr), len(y))
        chunk = y[start_sample:end_sample]

        if len(chunk) < sr:
            chunk = np.pad(chunk, (0, sr - len(chunk)))

        import soundfile as sf

        tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".wav")
        try:
            sf.write(tmp.name, chunk, sr)
            tmp.close()

            mood_scores = {}
            for name, model in _loaded_models.items():
                prediction = model(tmp.name)
                mood_scores[name] = float(np.mean(prediction))
        finally:
            os.unlink(tmp.name)

        valence, arousal = _compute_valence_arousal(mood_scores)
        results.append({
            "start": round(start, 3),
            "end": round(end, 3),
            "valence": round(valence, 4),
            "arousal": round(arousal, 4),
        })

    return results

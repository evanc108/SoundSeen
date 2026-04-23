import numpy as np
import librosa


def _min_max_normalize(arr: np.ndarray) -> np.ndarray:
    """Min-max normalize an array to [0, 1]."""
    mn, mx = arr.min(), arr.max()
    if mx - mn < 1e-10:
        return np.zeros_like(arr)
    return (arr - mn) / (mx - mn)


# 8 perceptual frequency bands for granular haptic/visual mapping
BAND_EDGES = [
    ("sub_bass", 20, 60),
    ("bass", 60, 250),
    ("low_mid", 250, 500),
    ("mid", 500, 1000),
    ("upper_mid", 1000, 2000),
    ("presence", 2000, 4000),
    ("brilliance", 4000, 8000),
    ("ultra_high", 8000, 16000),
]

BAND_NAMES = [b[0] for b in BAND_EDGES]


def analyze_spectral(y: np.ndarray, sr: int) -> dict:
    """Compute frame-level spectral features, all normalized per-song.

    Returns frame-level arrays plus metadata for time alignment.
    """
    hop_length = 512
    frame_length = 2048

    # Core features
    rms = librosa.feature.rms(y=y, frame_length=frame_length, hop_length=hop_length)[0]
    centroid = librosa.feature.spectral_centroid(y=y, sr=sr, hop_length=hop_length)[0]
    rolloff = librosa.feature.spectral_rolloff(y=y, sr=sr, hop_length=hop_length)[0]
    zcr = librosa.feature.zero_crossing_rate(y=y, frame_length=frame_length, hop_length=hop_length)[0]

    # --- 8-band frequency decomposition via mel spectrogram ---
    n_mels = 128
    mel_spec = librosa.feature.melspectrogram(
        y=y, sr=sr, n_mels=n_mels, hop_length=hop_length, fmax=sr / 2,
    )
    mel_db = librosa.power_to_db(mel_spec, ref=np.max)
    mel_linear = librosa.db_to_power(mel_db)
    mel_freqs = librosa.mel_frequencies(n_mels=n_mels, fmax=sr / 2)

    band_energies = {}
    band_energies_norm = {}
    for name, lo, hi in BAND_EDGES:
        mask = (mel_freqs >= lo) & (mel_freqs < hi)
        if mask.any():
            energy = np.mean(mel_linear[mask, :], axis=0)
        else:
            energy = np.zeros(mel_linear.shape[1])
        band_energies[name] = energy
        band_energies_norm[name] = _min_max_normalize(energy)

    # Legacy 3-band (kept for backward compat in segments)
    bass_energy = band_energies_norm["sub_bass"] * 0.3 + band_energies_norm["bass"] * 0.7
    mid_energy = (
        band_energies_norm["low_mid"] * 0.3
        + band_energies_norm["mid"] * 0.4
        + band_energies_norm["upper_mid"] * 0.3
    )
    treble_energy = (
        band_energies_norm["presence"] * 0.4
        + band_energies_norm["brilliance"] * 0.4
        + band_energies_norm["ultra_high"] * 0.2
    )

    # --- Spectral contrast (7 bands) → single perceptual "texture" value ---
    contrast = librosa.feature.spectral_contrast(y=y, sr=sr, hop_length=hop_length)
    spectral_contrast = np.mean(contrast, axis=0)

    # --- Spectral flux (frame-to-frame spectral change) ---
    S = np.abs(librosa.stft(y=y, hop_length=hop_length, n_fft=frame_length))
    spectral_flux = np.sqrt(np.sum(np.diff(S, axis=1) ** 2, axis=0))
    # Pad to match frame count (diff reduces length by 1)
    spectral_flux = np.concatenate([[0.0], spectral_flux])

    # --- HPSS: harmonic vs percussive separation ratio ---
    H, P = librosa.decompose.hpss(S)
    harmonic_energy = np.sum(H ** 2, axis=0)
    percussive_energy = np.sum(P ** 2, axis=0)
    # Ratio: 1.0 = fully harmonic, 0.0 = fully percussive
    harmonic_ratio = harmonic_energy / (harmonic_energy + percussive_energy + 1e-10)

    # --- Chromagram → dominant pitch class for color hue ---
    chroma = librosa.feature.chroma_cqt(y=y, sr=sr, hop_length=hop_length)
    dominant_chroma = np.argmax(chroma, axis=0).astype(float)
    chroma_hue = dominant_chroma * 30.0
    chroma_strength = np.max(chroma, axis=0)

    # --- MFCC (first 4 coefficients) → timbre descriptors ---
    # coef 0: overall spectral energy (redundant with RMS)
    # coef 1..3: spectral shape — drives brushstroke/stroke-weight in visuals
    # Normalized per-coefficient so each reads as a [0, 1] signal at the UI.
    mfcc_4 = librosa.feature.mfcc(y=y, sr=sr, hop_length=hop_length, n_mfcc=4)
    mfcc_norm = np.stack([_min_max_normalize(mfcc_4[i]) for i in range(4)], axis=0)

    # --- Pitch direction (frame-to-frame dominant chroma movement) ---
    # +1 = pitch rising, -1 = pitch falling, 0 = static
    chroma_diff = np.diff(dominant_chroma)
    # Wrap around (e.g., 11->0 is actually +1, not -11)
    chroma_diff = np.where(chroma_diff > 6, chroma_diff - 12, chroma_diff)
    chroma_diff = np.where(chroma_diff < -6, chroma_diff + 12, chroma_diff)
    pitch_direction = np.sign(chroma_diff)
    pitch_direction = np.concatenate([[0.0], pitch_direction])

    return {
        "rms_norm": _min_max_normalize(rms),
        "spectral_centroid_norm": _min_max_normalize(centroid),
        "spectral_rolloff_norm": _min_max_normalize(rolloff),
        "zcr_norm": _min_max_normalize(zcr),
        # 8-band energies (normalized)
        "band_energies_norm": band_energies_norm,
        # Legacy 3-band (for backward compat)
        "bass_energy_norm": bass_energy,
        "mid_energy_norm": mid_energy,
        "treble_energy_norm": treble_energy,
        # Texture and tonality
        "spectral_contrast_norm": _min_max_normalize(spectral_contrast),
        "spectral_flux_norm": _min_max_normalize(spectral_flux),
        "harmonic_ratio": harmonic_ratio,
        "pitch_direction": pitch_direction,
        # Chroma
        "chroma": chroma,
        "chroma_hue": chroma_hue,
        "chroma_strength_norm": _min_max_normalize(chroma_strength),
        # Per-coefficient normalized MFCC (4 x n_frames).
        "mfcc_norm": mfcc_norm,
        # Raw values
        "rms_raw": rms,
        "centroid_raw": centroid,
        "hop_length": hop_length,
        "sr": sr,
    }

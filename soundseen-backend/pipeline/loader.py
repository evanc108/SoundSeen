import tempfile
import os
import logging

import librosa
import numpy as np

logger = logging.getLogger(__name__)


def load_audio(file_bytes: bytes, suffix: str = ".wav") -> tuple[np.ndarray, int, float]:
    """Load audio from raw bytes. Returns (waveform, sample_rate, duration_seconds)."""
    tmp = tempfile.NamedTemporaryFile(delete=False, suffix=suffix)
    try:
        tmp.write(file_bytes)
        tmp.flush()
        tmp.close()
        y, sr = librosa.load(tmp.name, sr=22050, mono=True)
        duration = float(librosa.get_duration(y=y, sr=sr))
        logger.info("Loaded audio: %.1fs, sr=%d, samples=%d", duration, sr, len(y))
        return y, sr, duration
    finally:
        os.unlink(tmp.name)

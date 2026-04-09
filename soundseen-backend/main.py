import asyncio
import logging
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from functools import partial

from fastapi import FastAPI, File, HTTPException, UploadFile
from pydantic import BaseModel

from config import settings
from db import supabase_client
from pipeline.emotion import analyze_emotion, load_models, models_loaded
from pipeline.loader import load_audio
from pipeline.rhythm import analyze_rhythm
from pipeline.segmenter import build_frames, build_emotion_timeline
from pipeline.spectral import analyze_spectral, BAND_NAMES
from pipeline.structure import analyze_structure

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)

ALLOWED_EXTENSIONS = {".mp3", ".wav", ".m4a"}
ALLOWED_CONTENT_TYPES = {
    "audio/mpeg",
    "audio/wav",
    "audio/x-wav",
    "audio/mp4",
    "audio/x-m4a",
    "audio/m4a",
}

_executor = ThreadPoolExecutor(max_workers=2)


# --- Pydantic response models ---


class BeatEvent(BaseModel):
    time: float
    intensity: float
    sharpness: float
    bass_intensity: float
    is_downbeat: bool


class OnsetEvent(BaseModel):
    time: float
    intensity: float
    sharpness: float
    attack_strength: float
    attack_time_ms: float
    decay_time_ms: float
    sustain_level: float
    attack_slope: float


class Frames(BaseModel):
    """Per-frame data in columnar format (~23ms resolution)."""
    frame_duration_ms: float
    count: int
    time: list[float]
    energy: list[float]
    bands: list[list[float]]
    centroid: list[float]
    flux: list[float]
    hue: list[float]
    chroma_strength: list[float]
    harmonic_ratio: list[float]


class Emotion(BaseModel):
    """Valence/arousal at regular intervals."""
    interval: float
    valence: list[float]
    arousal: list[float]


class Section(BaseModel):
    start: float
    end: float
    label: str
    energy_profile: str


class SongAnalysis(BaseModel):
    song_id: str
    filename: str
    storage_path: str
    duration_seconds: float
    bpm: float
    band_names: list[str]
    beat_events: list[BeatEvent]
    onset_events: list[OnsetEvent]
    sections: list[Section]
    emotion: Emotion
    frames: Frames
    processing_time_seconds: float


class HealthResponse(BaseModel):
    status: str
    models_loaded: bool


# --- Lifespan ---


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Loading Essentia models from %s", settings.model_dir)
    success = load_models(settings.model_dir)
    if success:
        logger.info("All Essentia mood models loaded successfully")
    else:
        logger.warning("Running without Essentia models — using spectral-derived emotion")
    yield
    _executor.shutdown(wait=False)


app = FastAPI(title="SoundSeen Backend", lifespan=lifespan)


# --- Pipeline runner (blocking, runs in executor) ---


def _run_pipeline(file_bytes: bytes, suffix: str) -> dict:
    y, sr, duration = load_audio(file_bytes, suffix=suffix)
    spectral = analyze_spectral(y, sr)
    rhythm = analyze_rhythm(y, sr, spectral)
    emotion_segments = analyze_emotion(y, sr, duration, spectral=spectral)
    sections = analyze_structure(y, sr, spectral)
    emotion = build_emotion_timeline(duration, emotion_segments)
    frames = build_frames(spectral, duration)
    return {
        "duration_seconds": round(duration, 1),
        "bpm": rhythm["bpm"],
        "band_names": list(BAND_NAMES),
        "beat_events": rhythm["beat_events"],
        "onset_events": rhythm["onset_events"],
        "sections": sections,
        "emotion": emotion,
        "frames": frames,
    }


# --- Routes ---


@app.get("/health", response_model=HealthResponse)
async def health():
    return HealthResponse(status="ok", models_loaded=models_loaded())


@app.post("/analyze", response_model=SongAnalysis)
async def analyze(file: UploadFile = File(...)):
    filename = file.filename or "upload.wav"
    ext = "." + filename.rsplit(".", 1)[-1].lower() if "." in filename else ""
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(
            status_code=400,
            detail="Unsupported audio format. Please upload .mp3, .wav, or .m4a",
        )

    file_bytes = await file.read()
    max_bytes = settings.max_file_size_mb * 1024 * 1024
    if len(file_bytes) > max_bytes:
        raise HTTPException(
            status_code=413,
            detail=f"File too large. Max size is {settings.max_file_size_mb}MB",
        )

    song_id = str(uuid.uuid4())
    logger.info("Analyzing song %s (%s, %d bytes)", song_id, filename, len(file_bytes))

    content_type = file.content_type or "audio/mpeg"
    try:
        storage_path = await supabase_client.upload_audio(
            song_id, filename, file_bytes, content_type
        )
    except Exception:
        raise HTTPException(status_code=500, detail="Failed to upload audio file")

    start_time = time.monotonic()
    try:
        loop = asyncio.get_running_loop()
        result = await loop.run_in_executor(
            _executor, partial(_run_pipeline, file_bytes, ext)
        )
    except Exception:
        logger.exception("Pipeline failed for song %s", song_id)
        if settings.env == "development":
            raise
        raise HTTPException(status_code=500, detail="Analysis pipeline failed")

    processing_time = round(time.monotonic() - start_time, 1)

    analysis = SongAnalysis(
        song_id=song_id,
        filename=filename,
        storage_path=storage_path,
        processing_time_seconds=processing_time,
        **result,
    )

    try:
        await supabase_client.insert_song(
            song_id, filename, storage_path, analysis.model_dump()
        )
    except Exception:
        raise HTTPException(status_code=500, detail="Failed to persist analysis results")

    logger.info("Song %s analyzed in %.1fs", song_id, processing_time)
    return analysis


@app.get("/song/{song_id}", response_model=SongAnalysis)
async def get_song(song_id: str):
    try:
        data = await supabase_client.fetch_song(song_id)
    except Exception:
        logger.exception("Failed to fetch song %s", song_id)
        raise HTTPException(status_code=500, detail="Database error")

    if data is None:
        raise HTTPException(status_code=404, detail="Song not found")

    return data

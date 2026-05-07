import asyncio
import gc
import logging
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from functools import partial

from collections import defaultdict

from fastapi import FastAPI, File, HTTPException, Header, Request, UploadFile
from pydantic import BaseModel

from config import settings
from db import supabase_client
from pipeline.composition import SPEC_VERSION, build_composition_spec
from pipeline.emotion import analyze_chunk, analyze_emotion, load_models, models_loaded
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

# Serialize analyses: the pipeline peaks at hundreds of MB per track (STFT +
# HPSS), and concurrent runs on a small Railway container OOM. Queue instead.
_executor = ThreadPoolExecutor(max_workers=1)

# Separate pool for /analyze_chunk — 2s windows peak at ~10MB and must not
# starve behind a 5–15s full analysis.
_chunk_executor = ThreadPoolExecutor(max_workers=2)
_chunk_max_bytes = 400 * 1024
_chunk_inflight: dict[str, int] = defaultdict(int)
_chunk_inflight_lock = asyncio.Lock()


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
    # Round-3 timbre signals (optional so older cached analyses still parse).
    rolloff: list[float] = []
    zcr: list[float] = []
    spectral_contrast: list[float] = []
    mfcc: list[list[float]] = []       # 4 coefficients per frame
    chroma: list[list[float]] = []     # 12 pitch classes per frame


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


class ChunkEmotion(BaseModel):
    valence: float
    arousal: float


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
    _chunk_executor.shutdown(wait=False)


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
    finally:
        del file_bytes
        gc.collect()

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


def _run_chunk(file_bytes: bytes, suffix: str) -> tuple[float, float]:
    y, sr, _ = load_audio(file_bytes, suffix=suffix)
    return analyze_chunk(y, sr)


@app.post("/analyze_chunk", response_model=ChunkEmotion)
async def analyze_chunk_route(
    request: Request,
    x_client_id: str | None = Header(default=None),
):
    body = await request.body()
    if not body:
        raise HTTPException(status_code=400, detail="Empty request body")
    if len(body) > _chunk_max_bytes:
        raise HTTPException(status_code=413, detail="Chunk too large")

    client_id = x_client_id or request.client.host if request.client else "anon"

    async with _chunk_inflight_lock:
        if _chunk_inflight[client_id] >= 2:
            raise HTTPException(status_code=429, detail="Too many chunks in flight")
        _chunk_inflight[client_id] += 1

    try:
        loop = asyncio.get_running_loop()
        valence, arousal = await loop.run_in_executor(
            _chunk_executor, partial(_run_chunk, body, ".wav")
        )
    except Exception:
        logger.exception("Chunk analysis failed")
        raise HTTPException(status_code=500, detail="Chunk analysis failed")
    finally:
        async with _chunk_inflight_lock:
            _chunk_inflight[client_id] = max(0, _chunk_inflight[client_id] - 1)

    return ChunkEmotion(valence=valence, arousal=arousal)


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


@app.get("/song/{song_id}/composition")
async def get_song_composition(song_id: str, preset: str = "default"):
    """Return the deterministic CompositionSpec for a song.

    Built fresh from the cached SongAnalysis on each call. Cheap (<10ms
    for a 4-min track) so no need to cache the spec itself — caching the
    rendered MP4 keyed by (audio_hash, spec_version) is what actually
    matters downstream.
    """
    try:
        data = await supabase_client.fetch_song(song_id)
    except Exception:
        logger.exception("Failed to fetch song %s", song_id)
        raise HTTPException(status_code=500, detail="Database error")

    if data is None:
        raise HTTPException(status_code=404, detail="Song not found")

    # `data` may be a Pydantic model or dict depending on the supabase
    # client's hydration path; coerce defensively.
    payload = data.model_dump() if hasattr(data, "model_dump") else dict(data)
    spec = build_composition_spec(payload, preset=preset)
    return spec


@app.get("/composition/version")
async def get_composition_version():
    """Cheap probe so the renderer can detect schema bumps without
    fetching a full spec."""
    return {"spec_version": SPEC_VERSION}


# ---------------------------------------------------------------------------
# Render dispatch — backend → Modal (soundseen-renderer)

import json as _json
try:
    import modal as _modal  # optional dependency: backend can run without
                            # the renderer wired up; /render returns
                            # status="unavailable" in that case.
except ImportError:
    _modal = None  # type: ignore[assignment]

_MODAL_APP_NAME = "soundseen-renderer"
_MODAL_FUNCTION_NAME = "render_song"


class RenderJobStatus(BaseModel):
    job_id: str
    song_id: str
    status: str          # queued | rendering | complete | failed | unavailable
    progress: float = 0.0
    video_url: str | None = None
    error: str | None = None


# Maps modal call id → song_id so /render/:job_id can find the right
# song to upload the rendered MP4 against. In-memory; production should
# back this with Postgres so jobs survive container restarts.
_render_jobs: dict[str, dict] = {}


def _modal_render_function():
    """Resolve the deployed Modal function. Returns None if Modal isn't
    installed or the function hasn't been deployed yet."""
    if _modal is None:
        return None
    try:
        return _modal.Function.from_name(_MODAL_APP_NAME, _MODAL_FUNCTION_NAME)
    except Exception:
        logger.exception("Could not resolve Modal function %s.%s",
                         _MODAL_APP_NAME, _MODAL_FUNCTION_NAME)
        return None


@app.post("/render", response_model=RenderJobStatus)
async def start_render(song_id: str, preset: str = "default"):
    """Kick off an MP4 render. Returns a job_id immediately; caller
    polls GET /render/:job_id for status.

    Cache hit fast-path: if a render already exists for (song, preset,
    spec_version) tuple, returns status=complete with the video URL
    without spawning a new Modal job."""
    try:
        analysis = await supabase_client.fetch_song(song_id)
    except Exception:
        logger.exception("Failed to fetch song %s", song_id)
        raise HTTPException(status_code=500, detail="Database error")

    if analysis is None:
        raise HTTPException(status_code=404, detail="Song not found")

    payload = analysis.model_dump() if hasattr(analysis, "model_dump") else dict(analysis)
    spec = build_composition_spec(payload, preset=preset)

    # Cache hit fast-path. Spec_version invalidates when the layout
    # bumps, so a v3-rendered MP4 is correctly skipped after a v4 bump.
    cached = await supabase_client.get_video_url(song_id, SPEC_VERSION)
    if cached:
        job_id = f"cached-{song_id}-v{SPEC_VERSION}"
        job = RenderJobStatus(
            job_id=job_id, song_id=song_id, status="complete",
            progress=1.0, video_url=cached,
        )
        _render_jobs[job_id] = {"song_id": song_id, "status": job.status, "video_url": cached}
        return job

    fn = _modal_render_function()
    if fn is None:
        return RenderJobStatus(
            job_id="unavailable",
            song_id=song_id,
            status="unavailable",
            error="Renderer not deployed (modal package missing or app not found)",
        )

    # Pull the audio bytes Modal will use to mux the final MP4.
    storage_path = payload.get("storage_path")
    if not storage_path:
        raise HTTPException(status_code=500, detail="Song has no storage_path")
    try:
        audio_bytes = await supabase_client.download_audio(storage_path)
    except Exception:
        raise HTTPException(status_code=500, detail="Failed to fetch source audio")

    audio_ext = "." + storage_path.rsplit(".", 1)[-1].lower() if "." in storage_path else ".mp3"

    try:
        call = fn.spawn(
            song_id=song_id,
            spec_json=_json.dumps(spec),
            audio_bytes=audio_bytes,
            audio_extension=audio_ext,
        )
    except Exception as e:
        logger.exception("Failed to spawn Modal render for %s", song_id)
        return RenderJobStatus(
            job_id="failed-spawn",
            song_id=song_id,
            status="failed",
            error=f"Modal spawn failed: {e}",
        )

    job_id = call.object_id
    _render_jobs[job_id] = {"song_id": song_id, "status": "queued"}
    logger.info("Spawned Modal render %s for song %s", job_id, song_id)
    return RenderJobStatus(job_id=job_id, song_id=song_id, status="queued")


@app.get("/render/{job_id}", response_model=RenderJobStatus)
async def get_render_status(job_id: str):
    """Poll a render job. Reconstructs the Modal FunctionCall by id,
    probes for completion, and on success uploads the MP4 to Supabase
    and returns the public URL."""
    state = _render_jobs.get(job_id)
    if state is None:
        raise HTTPException(status_code=404, detail="Render job not found")

    # Cached hit — already returned a URL on /render. Just echo state.
    if state.get("status") == "complete" and state.get("video_url"):
        return RenderJobStatus(
            job_id=job_id, song_id=state["song_id"], status="complete",
            progress=1.0, video_url=state["video_url"],
        )

    if _modal is None:
        return RenderJobStatus(
            job_id=job_id, song_id=state["song_id"], status="unavailable",
            error="Modal not installed on backend",
        )

    try:
        call = _modal.FunctionCall.from_id(job_id)
    except Exception as e:
        return RenderJobStatus(
            job_id=job_id, song_id=state["song_id"], status="failed",
            error=f"Could not reconstitute Modal call: {e}",
        )

    # Probe with a tiny timeout — if the function is still running,
    # this raises TimeoutError; if complete, it returns the bytes.
    try:
        result = call.get(timeout=0)
    except Exception as e:
        # Modal's actual exception class for "not done yet" varies by
        # version (TimeoutError, FunctionTimeoutError). Treat any
        # timeout-like exception as "still rendering".
        msg = str(e).lower()
        if "timeout" in msg or "not finished" in msg or "still running" in msg:
            return RenderJobStatus(
                job_id=job_id, song_id=state["song_id"], status="rendering",
                progress=state.get("progress", 0.5),
            )
        # Anything else is a real failure.
        logger.exception("Modal render %s failed", job_id)
        state["status"] = "failed"
        return RenderJobStatus(
            job_id=job_id, song_id=state["song_id"], status="failed",
            error=str(e),
        )

    # Result is bytes (the MP4). Upload to Supabase and return URL.
    if not isinstance(result, (bytes, bytearray)):
        return RenderJobStatus(
            job_id=job_id, song_id=state["song_id"], status="failed",
            error=f"Renderer returned non-bytes ({type(result).__name__})",
        )

    try:
        url = await supabase_client.upload_video(state["song_id"], SPEC_VERSION, bytes(result))
    except Exception as e:
        logger.exception("Failed to upload rendered video for %s", state["song_id"])
        return RenderJobStatus(
            job_id=job_id, song_id=state["song_id"], status="failed",
            error=f"Upload failed: {e}",
        )

    state["status"] = "complete"
    state["video_url"] = url
    logger.info("Render %s complete: %s", job_id, url)
    return RenderJobStatus(
        job_id=job_id, song_id=state["song_id"], status="complete",
        progress=1.0, video_url=url,
    )

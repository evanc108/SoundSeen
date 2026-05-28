import asyncio
from typing import Optional
import gc
import logging
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from functools import partial

from collections import defaultdict

from fastapi import Depends, FastAPI, File, HTTPException, Header, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from auth import current_user_id, optional_user_id
from config import settings
from db import render_jobs_repo, songs_repo, supabase_client
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

_cors_origins = [
    o.strip() for o in settings.cors_origins.split(",") if o.strip()
]
app.add_middleware(
    CORSMiddleware,
    allow_origins=_cors_origins,
    allow_origin_regex=settings.cors_origin_regex or None,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# --- Pipeline runner (blocking, runs in executor) ---


def _run_pipeline(file_bytes: bytes, suffix: str) -> dict:
    y, sr, duration = load_audio(file_bytes, suffix=suffix)
    spectral = analyze_spectral(y, sr)
    rhythm = analyze_rhythm(y, sr, spectral)
    emotion_segments = analyze_emotion(y, sr, duration, spectral=spectral)
    sections = analyze_structure(y, sr, spectral)
    emotion = build_emotion_timeline(duration, emotion_segments)
    frames = build_frames(spectral, duration)
    # Plumb the continuous onset-strength envelope onto frames so
    # _build_frames_track can subsample it alongside the spectral signals.
    frames["onset_env_norm"] = rhythm.get("onset_env_norm", [])
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
async def analyze(
    file: UploadFile = File(...),
    user_id: str = Depends(current_user_id),
):
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
            song_id, filename, storage_path, analysis.model_dump(), user_id=user_id
        )
    except Exception:
        raise HTTPException(status_code=500, detail="Failed to persist analysis results")

    logger.info("Song %s analyzed in %.1fs", song_id, processing_time)
    asyncio.create_task(_auto_kickoff_render(song_id, analysis.model_dump()))
    return analysis


def _run_chunk(file_bytes: bytes, suffix: str) -> tuple[float, float]:
    y, sr, _ = load_audio(file_bytes, suffix=suffix)
    return analyze_chunk(y, sr)


@app.post("/analyze_chunk", response_model=ChunkEmotion)
async def analyze_chunk_route(
    request: Request,
    x_client_id: Optional[str] = Header(default=None),
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


@app.get("/gallery")
async def get_gallery(limit: int = 24, offset: int = 0):
    """Public list of songs with completed renders. Newest first.

    Returns a slim row shape (no full SongAnalysis) so the gallery loads
    fast even with hundreds of cards."""
    limit = max(1, min(limit, 100))
    offset = max(0, offset)
    return await songs_repo.gallery(limit=limit, offset=offset)


@app.get("/me/songs")
async def get_my_songs(
    user_id: str = Depends(current_user_id),
    limit: int = 50,
    offset: int = 0,
):
    """Auth-gated: every song this user has uploaded, including
    in-flight render rows so the client can show progress."""
    limit = max(1, min(limit, 100))
    offset = max(0, offset)
    return await songs_repo.list_for_user(user_id, limit=limit, offset=offset)


@app.get("/song/{song_id}/owner")
async def get_song_owner(song_id: str):
    """Cheap probe: who owns this song? Returns {user_id, exists}. The
    web client uses this on /song/[id] to decide whether to render the
    delete button."""
    owner = await supabase_client.fetch_song_owner(song_id)
    if owner is None:
        return {"exists": False, "user_id": None}
    return {"exists": True, "user_id": owner[0]}


@app.delete("/song/{song_id}")
async def delete_song(
    song_id: str,
    user_id: str = Depends(current_user_id),
):
    """Owner-only hard delete. Removes the song row (cascades render_jobs
    via FK), source audio, and every rendered MP4 in storage."""
    owner = await supabase_client.fetch_song_owner(song_id)
    if owner is None:
        raise HTTPException(status_code=404, detail="Song not found")
    owner_id, storage_path = owner
    if owner_id != user_id:
        # Don't leak existence to non-owners; 404 instead of 403.
        raise HTTPException(status_code=404, detail="Song not found")
    try:
        await supabase_client.delete_song(song_id, storage_path)
    except Exception:
        raise HTTPException(status_code=500, detail="Delete failed")
    return {"deleted": song_id}


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
    video_url: Optional[str] = None
    error: Optional[str] = None


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


# Auto-render preview cap. Headless Chrome falls back to software WebGL
# in our Modal container, so each rendered second of output costs roughly
# 4–6 seconds of wall time on an A10G. 60 seconds of output lands a
# render in 3–5 minutes — long enough for the user to see the drop /
# motif but inside Modal's timeout with room to spare. If you want
# full-length renders, hit /render?song_id=… directly without max_seconds.
_AUTO_RENDER_MAX_SECONDS = 60.0


async def _auto_kickoff_render(song_id: str, analysis_payload: dict) -> None:
    """Best-effort detached task. Spawns Modal render right after a
    successful /analyze, persists the resulting job_id. Failures log and
    swallow so the /analyze response is never affected."""
    try:
        spec = build_composition_spec(analysis_payload, preset="default")
        fn = _modal_render_function()
        if fn is None:
            await render_jobs_repo.insert_job(
                job_id=f"unavailable-{song_id}",
                song_id=song_id, status="unavailable",
                spec_version=SPEC_VERSION, preset="default", max_seconds=None,
                error="Renderer not deployed (modal package missing or app not found)",
            )
            return
        storage_path = analysis_payload.get("storage_path")
        if not storage_path:
            logger.warning("Auto-render skipped: song %s has no storage_path", song_id)
            return
        audio_bytes = await supabase_client.download_audio(storage_path)
        audio_ext = "." + storage_path.rsplit(".", 1)[-1].lower() if "." in storage_path else ".mp3"
        call = fn.spawn(
            song_id=song_id,
            spec_json=_json.dumps(spec),
            audio_bytes=audio_bytes,
            audio_extension=audio_ext,
            max_seconds=_AUTO_RENDER_MAX_SECONDS,
        )
        await render_jobs_repo.insert_job(
            job_id=call.object_id, song_id=song_id, status="queued",
            spec_version=SPEC_VERSION, preset="default",
            max_seconds=_AUTO_RENDER_MAX_SECONDS,
        )
        logger.info("Auto-spawned render %s for song %s", call.object_id, song_id)
    except Exception:
        logger.exception("Auto-render kickoff failed for %s", song_id)


@app.post("/render", response_model=RenderJobStatus)
async def start_render(
    song_id: str,
    preset: str = "default",
    max_seconds: Optional[float] = None,
):
    """Kick off an MP4 render. Returns a job_id immediately; caller
    polls GET /render/:job_id for status.

    `max_seconds` clamps the rendered output length — handy for fast
    smoke tests (e.g. ?max_seconds=15) before committing the GPU time
    for a full track. None = render full duration.

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

    # Cache hit fast-path. Prefer an existing render_jobs row so a
    # returning client resumes the same job_id; fall back to probing the
    # bucket for legacy mp4s that predate the table.
    existing = await render_jobs_repo.latest_complete_for_song(song_id, SPEC_VERSION)
    if existing and existing.get("video_url"):
        return RenderJobStatus(
            job_id=existing["job_id"], song_id=song_id, status="complete",
            progress=1.0, video_url=existing["video_url"],
        )
    cached = await supabase_client.get_video_url(song_id, SPEC_VERSION)
    if cached:
        job_id = f"cached-{song_id}-v{SPEC_VERSION}"
        await render_jobs_repo.insert_job(
            job_id=job_id, song_id=song_id, status="complete",
            spec_version=SPEC_VERSION, preset=preset, max_seconds=max_seconds,
            video_url=cached,
        )
        return RenderJobStatus(
            job_id=job_id, song_id=song_id, status="complete",
            progress=1.0, video_url=cached,
        )

    fn = _modal_render_function()
    if fn is None:
        job_id = f"unavailable-{song_id}"
        await render_jobs_repo.insert_job(
            job_id=job_id, song_id=song_id, status="unavailable",
            spec_version=SPEC_VERSION, preset=preset, max_seconds=max_seconds,
            error="Renderer not deployed (modal package missing or app not found)",
        )
        return RenderJobStatus(
            job_id=job_id, song_id=song_id, status="unavailable",
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
            max_seconds=max_seconds,
        )
    except Exception as e:
        logger.exception("Failed to spawn Modal render for %s", song_id)
        job_id = f"spawn-fail-{uuid.uuid4()}"
        await render_jobs_repo.insert_job(
            job_id=job_id, song_id=song_id, status="failed",
            spec_version=SPEC_VERSION, preset=preset, max_seconds=max_seconds,
            error=f"Modal spawn failed: {e}",
        )
        return RenderJobStatus(
            job_id=job_id, song_id=song_id, status="failed",
            error=f"Modal spawn failed: {e}",
        )

    job_id = call.object_id
    await render_jobs_repo.insert_job(
        job_id=job_id, song_id=song_id, status="queued",
        spec_version=SPEC_VERSION, preset=preset, max_seconds=max_seconds,
    )
    logger.info("Spawned Modal render %s for song %s", job_id, song_id)
    return RenderJobStatus(job_id=job_id, song_id=song_id, status="queued")


async def _probe_and_serialize(row: dict) -> RenderJobStatus:
    """Take a render_jobs row and return its current RenderJobStatus,
    making at most one Modal probe + upload round-trip on the way.

    Terminal rows (complete/failed/unavailable) short-circuit. Non-
    terminal rows that the iOS client sentinel-prefixes can't be probed
    via FunctionCall.from_id and are returned as-is."""
    job_id = row["job_id"]
    song_id = row["song_id"]
    status = row["status"]
    video_url = row.get("video_url")
    error = row.get("error")

    if status == "complete" and video_url:
        return RenderJobStatus(
            job_id=job_id, song_id=song_id, status="complete",
            progress=1.0, video_url=video_url,
        )
    if status in ("failed", "unavailable"):
        return RenderJobStatus(
            job_id=job_id, song_id=song_id, status=status,
            error=error,
        )

    # Non-Modal sentinel job_ids can't be reconstituted.
    if _modal is None or job_id.startswith(("cached-", "unavailable-", "spawn-fail-")):
        return RenderJobStatus(
            job_id=job_id, song_id=song_id, status=status,
            progress=0.0, video_url=video_url, error=error,
        )

    try:
        call = _modal.FunctionCall.from_id(job_id)
    except Exception as e:
        msg = f"Could not reconstitute Modal call: {e}"
        await render_jobs_repo.mark_failed(job_id, msg)
        return RenderJobStatus(
            job_id=job_id, song_id=song_id, status="failed",
            error=msg,
        )

    # Probe with timeout=0. Modal raises stdlib `TimeoutError` when the
    # call is still running. EVERY other exception is terminal — Modal's
    # own `FunctionTimeoutError` (function exceeded its wall budget) is
    # NOT the same thing as the stdlib TimeoutError and must surface as
    # a failure, not as a "still pending" state.
    try:
        result = call.get(timeout=0)
    except TimeoutError:
        await render_jobs_repo.mark_rendering(job_id)
        return RenderJobStatus(
            job_id=job_id, song_id=song_id, status="rendering",
            progress=0.0,
        )
    except Exception as e:
        logger.exception("Modal render %s failed", job_id)
        msg = f"{type(e).__name__}: {e}".strip(": ")
        await render_jobs_repo.mark_failed(job_id, msg)
        return RenderJobStatus(
            job_id=job_id, song_id=song_id, status="failed",
            error=msg,
        )

    # Result is bytes (the MP4). Upload to Supabase and return URL.
    if not isinstance(result, (bytes, bytearray)):
        msg = f"Renderer returned non-bytes ({type(result).__name__})"
        await render_jobs_repo.mark_failed(job_id, msg)
        return RenderJobStatus(
            job_id=job_id, song_id=song_id, status="failed",
            error=msg,
        )

    try:
        url = await supabase_client.upload_video(song_id, SPEC_VERSION, bytes(result))
    except Exception as e:
        logger.exception("Failed to upload rendered video for %s", song_id)
        msg = f"Upload failed: {e}"
        await render_jobs_repo.mark_failed(job_id, msg)
        return RenderJobStatus(
            job_id=job_id, song_id=song_id, status="failed",
            error=msg,
        )

    await render_jobs_repo.mark_complete(job_id, url)
    logger.info("Render %s complete: %s", job_id, url)
    return RenderJobStatus(
        job_id=job_id, song_id=song_id, status="complete",
        progress=1.0, video_url=url,
    )


@app.get("/render/{job_id}", response_model=RenderJobStatus)
async def get_render_status(job_id: str):
    """Poll a render job. Reconstructs the Modal FunctionCall by id,
    probes for completion, and on success uploads the MP4 to Supabase
    and returns the public URL."""
    row = await render_jobs_repo.get_job(job_id)
    if row is None:
        raise HTTPException(status_code=404, detail="Render job not found")
    return await _probe_and_serialize(row)


@app.get("/jobs", response_model=list[RenderJobStatus])
async def list_jobs(song_ids: str):
    """Batch poll for app-launch resume. Comma-separated song_ids;
    returns the latest render_jobs row per song that the client knows
    about, probing Modal once for any still-running rows.

    Cap at 100 ids to keep the Modal-probe blast radius bounded — a
    cold app launch with a 500-track library is the worst case."""
    ids = [s.strip() for s in song_ids.split(",") if s.strip()]
    if not ids:
        return []
    if len(ids) > 100:
        raise HTTPException(status_code=400, detail="max 100 song_ids per request")
    rows = await render_jobs_repo.get_jobs_for_songs(ids)
    # get_jobs_for_songs orders by updated_at desc — collapse to the
    # most-recent row per song_id so the client sees one job per track.
    latest_by_song: dict[str, dict] = {}
    for row in rows:
        sid = row["song_id"]
        if sid not in latest_by_song:
            latest_by_song[sid] = row
    return [await _probe_and_serialize(row) for row in latest_by_song.values()]

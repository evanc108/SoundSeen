import logging
from typing import Optional
from datetime import datetime, timezone

from db.supabase_client import get_client

logger = logging.getLogger(__name__)


_TABLE = "render_jobs"


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


async def insert_job(
    job_id: str,
    song_id: str,
    status: str,
    spec_version: int,
    preset: str = "default",
    max_seconds: Optional[float] = None,
    video_url: Optional[str] = None,
    error: Optional[str] = None,
) -> None:
    """Insert a fresh render job row. Upserts on job_id so the cached
    fast-path can re-synthesize a row without conflicting on a re-poll."""
    client = get_client()
    try:
        client.table(_TABLE).upsert({
            "job_id": job_id,
            "song_id": song_id,
            "status": status,
            "preset": preset,
            "spec_version": spec_version,
            "max_seconds": max_seconds,
            "video_url": video_url,
            "error": error,
            "updated_at": _now_iso(),
        }, on_conflict="job_id").execute()
    except Exception:
        logger.exception("Failed to insert render_job %s", job_id)


async def mark_rendering(job_id: str) -> None:
    """Idempotent: only promotes queued → rendering, never demotes."""
    client = get_client()
    try:
        client.table(_TABLE).update({
            "status": "rendering",
            "updated_at": _now_iso(),
        }).eq("job_id", job_id).eq("status", "queued").execute()
    except Exception:
        logger.exception("Failed to mark render_job %s rendering", job_id)


async def mark_complete(job_id: str, video_url: str) -> None:
    client = get_client()
    try:
        client.table(_TABLE).update({
            "status": "complete",
            "video_url": video_url,
            "error": None,
            "updated_at": _now_iso(),
        }).eq("job_id", job_id).execute()
    except Exception:
        logger.exception("Failed to mark render_job %s complete", job_id)


async def mark_failed(job_id: str, error: str) -> None:
    client = get_client()
    try:
        client.table(_TABLE).update({
            "status": "failed",
            "error": error,
            "updated_at": _now_iso(),
        }).eq("job_id", job_id).execute()
    except Exception:
        logger.exception("Failed to mark render_job %s failed", job_id)


async def get_job(job_id: str) -> Optional[dict]:
    client = get_client()
    try:
        result = (
            client.table(_TABLE)
            .select("*")
            .eq("job_id", job_id)
            .limit(1)
            .execute()
        )
        rows = result.data or []
        return rows[0] if rows else None
    except Exception:
        logger.exception("Failed to fetch render_job %s", job_id)
        return None


async def get_jobs_for_songs(song_ids: list[str]) -> list[dict]:
    if not song_ids:
        return []
    client = get_client()
    try:
        result = (
            client.table(_TABLE)
            .select("*")
            .in_("song_id", song_ids)
            .order("updated_at", desc=True)
            .execute()
        )
        return result.data or []
    except Exception:
        logger.exception("Failed to fetch render_jobs for songs")
        return []


async def latest_complete_for_song(song_id: str, spec_version: int) -> Optional[dict]:
    """Find the most recent completed render for this (song, spec_version)
    so a returning client resumes the same row instead of seeing a fresh
    cached-* sentinel each launch."""
    client = get_client()
    try:
        result = (
            client.table(_TABLE)
            .select("*")
            .eq("song_id", song_id)
            .eq("spec_version", spec_version)
            .eq("status", "complete")
            .order("updated_at", desc=True)
            .limit(1)
            .execute()
        )
        rows = result.data or []
        return rows[0] if rows else None
    except Exception:
        logger.exception("Failed to lookup latest complete render for %s", song_id)
        return None

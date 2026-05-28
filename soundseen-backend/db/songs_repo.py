"""Read-side queries for the web app. Gallery + per-user lists.

Both endpoints join songs ↔ render_jobs in Python rather than via a
PostgREST `select=`. Two queries is fewer surprises than wrestling the
nested-resource syntax for a filter-by-spec_version + status case.
"""

import logging
from typing import Optional

from db.supabase_client import get_client
from pipeline.composition import SPEC_VERSION

logger = logging.getLogger(__name__)


# PostgREST JSON-path projection — pull just the two summary fields we
# need from `analysis` instead of the whole blob. Cuts the gallery
# response from ~10 MB (48 songs × full SongAnalysis) to ~10 KB.
_SONGS_COLUMNS = (
    "id, filename, user_id, created_at, "
    "duration_seconds:analysis->duration_seconds, "
    "bpm:analysis->bpm"
)


def _shape_song_row(song: dict, job: Optional[dict]) -> dict:
    return {
        "song_id": song["id"],
        "filename": song.get("filename"),
        "user_id": song.get("user_id"),
        "created_at": song.get("created_at"),
        "duration_seconds": song.get("duration_seconds"),
        "bpm": song.get("bpm"),
        "video_url": (job or {}).get("video_url"),
        "render_status": (job or {}).get("status"),
    }


async def gallery(limit: int = 24, offset: int = 0) -> list[dict]:
    """Public list, completed renders only, newest first."""
    client = get_client()
    try:
        # Pull songs ordered newest first; we'll filter to those with a
        # complete render after joining.
        # Over-fetch a bit so the post-filter still yields ~limit rows.
        # In practice nearly every song has a render so this is fine.
        result = (
            client.table("songs")
            .select(_SONGS_COLUMNS)
            .order("created_at", desc=True)
            .range(offset, offset + limit * 2 - 1)
            .execute()
        )
        songs = result.data or []
    except Exception:
        logger.exception("Failed to fetch gallery songs")
        return []

    return await _hydrate_with_jobs(songs, limit=limit, require_complete=True)


async def list_for_user(
    user_id: str, limit: int = 50, offset: int = 0
) -> list[dict]:
    """All songs for a user, including in-flight renders so the UI can
    surface queued/rendering rows on /me."""
    client = get_client()
    try:
        result = (
            client.table("songs")
            .select(_SONGS_COLUMNS)
            .eq("user_id", user_id)
            .order("created_at", desc=True)
            .range(offset, offset + limit - 1)
            .execute()
        )
        songs = result.data or []
    except Exception:
        logger.exception("Failed to fetch songs for user %s", user_id)
        return []

    return await _hydrate_with_jobs(songs, limit=limit, require_complete=False)


async def _hydrate_with_jobs(
    songs: list[dict], limit: int, require_complete: bool
) -> list[dict]:
    if not songs:
        return []
    song_ids = [s["id"] for s in songs]
    client = get_client()
    try:
        job_rows = (
            client.table("render_jobs")
            .select("song_id, status, video_url, spec_version, updated_at")
            .in_("song_id", song_ids)
            .eq("spec_version", SPEC_VERSION)
            .order("updated_at", desc=True)
            .execute()
            .data
        ) or []
    except Exception:
        logger.exception("Failed to fetch render_jobs for hydration")
        job_rows = []

    # Most-recent job per song.
    job_by_song: dict[str, dict] = {}
    for j in job_rows:
        sid = j["song_id"]
        if sid not in job_by_song:
            job_by_song[sid] = j

    out: list[dict] = []
    for s in songs:
        job = job_by_song.get(s["id"])
        if require_complete and (not job or job.get("status") != "complete"):
            continue
        out.append(_shape_song_row(s, job))
        if len(out) >= limit:
            break
    return out

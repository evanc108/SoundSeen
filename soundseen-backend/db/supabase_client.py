import logging

from supabase import create_client, Client

from config import settings

logger = logging.getLogger(__name__)

_client: Client | None = None


def get_client() -> Client:
    global _client
    if _client is None:
        _client = create_client(settings.supabase_url, settings.supabase_key)
    return _client


async def insert_song(
    song_id: str,
    filename: str,
    storage_path: str,
    analysis: dict,
    user_id: str | None = None,
):
    client = get_client()
    row = {
        "id": song_id,
        "filename": filename,
        "storage_path": storage_path,
        "analysis": analysis,
    }
    if user_id is not None:
        row["user_id"] = user_id
    try:
        client.table("songs").insert(row).execute()
    except Exception:
        logger.exception("Failed to insert song %s", song_id)
        raise


async def fetch_song(song_id: str) -> dict | None:
    client = get_client()
    result = client.table("songs").select("analysis").eq("id", song_id).single().execute()
    return result.data["analysis"] if result.data else None


async def fetch_song_owner(song_id: str) -> tuple[str | None, str | None] | None:
    """Return (user_id, storage_path) for a song, or None if it doesn't
    exist. Used by DELETE /song/{id} to authorize the caller and clean
    up the associated audio file."""
    client = get_client()
    try:
        result = (
            client.table("songs")
            .select("user_id, storage_path")
            .eq("id", song_id)
            .single()
            .execute()
        )
    except Exception:
        return None
    if not result.data:
        return None
    return result.data.get("user_id"), result.data.get("storage_path")


async def delete_song(song_id: str, storage_path: str | None) -> None:
    """Delete the song row + its stored audio + every rendered video.
    render_jobs rows cascade via the FK; storage objects we delete
    explicitly because Supabase Storage doesn't cascade on table deletes."""
    client = get_client()
    # Storage cleanup first — if the row delete fails we'd otherwise orphan
    # the files. The video bucket can have multiple spec versions; list
    # whatever's in the song's prefix and remove all of it.
    try:
        listing = client.storage.from_(_VIDEO_BUCKET).list(song_id) or []
        if listing:
            client.storage.from_(_VIDEO_BUCKET).remove(
                [f"{song_id}/{item['name']}" for item in listing if item.get("name")]
            )
    except Exception:
        logger.exception("Failed to clean visualizations for %s", song_id)
    if storage_path:
        try:
            client.storage.from_("audio-uploads").remove([storage_path])
        except Exception:
            logger.exception("Failed to remove source audio %s", storage_path)
    # Row delete (cascades to render_jobs).
    try:
        client.table("songs").delete().eq("id", song_id).execute()
    except Exception:
        logger.exception("Failed to delete song row %s", song_id)
        raise


async def upload_audio(song_id: str, filename: str, file_bytes: bytes, content_type: str) -> str:
    client = get_client()
    path = f"{song_id}/{filename}"
    try:
        client.storage.from_("audio-uploads").upload(path, file_bytes, {"content-type": content_type})
    except Exception:
        logger.exception("Failed to upload audio for song %s", song_id)
        raise
    return path


async def download_audio(storage_path: str) -> bytes:
    """Pull the original audio file back out of Supabase storage so we
    can ship it to the renderer. The path is what `upload_audio` returned
    and what's stored on the songs table."""
    client = get_client()
    try:
        return client.storage.from_("audio-uploads").download(storage_path)
    except Exception:
        logger.exception("Failed to download audio at %s", storage_path)
        raise


# Bucket name for rendered MP4s. Must exist in Supabase storage —
# create it with `public` access so the iOS client can stream from
# the public URL without needing per-request auth.
_VIDEO_BUCKET = "visualizations"


async def upload_video(song_id: str, spec_version: int, mp4_bytes: bytes) -> str:
    """Upload the rendered MP4 and return its public URL.

    Path includes spec_version so a SPEC_VERSION bump auto-invalidates
    the previous render at a different path — both old and new can
    coexist while older devices are still on the prior spec.
    """
    client = get_client()
    path = f"{song_id}/v{spec_version}.mp4"
    try:
        client.storage.from_(_VIDEO_BUCKET).upload(
            path,
            mp4_bytes,
            {"content-type": "video/mp4", "upsert": "true"},
        )
    except Exception:
        logger.exception("Failed to upload video for song %s", song_id)
        raise
    # Public URL — bucket must be configured for public reads for this
    # to work without a signed URL per request.
    return client.storage.from_(_VIDEO_BUCKET).get_public_url(path)


async def get_video_url(song_id: str, spec_version: int) -> str | None:
    """Return the public URL for a previously-rendered video, or None
    if no render exists yet for this (song, spec_version) pair."""
    client = get_client()
    path = f"{song_id}/v{spec_version}.mp4"
    try:
        # Listing the song's prefix and checking for the file is the
        # cheapest existence-probe. `head_object` would be cleaner if
        # the supabase-py client exposed it.
        listing = client.storage.from_(_VIDEO_BUCKET).list(song_id)
        if not any(item.get("name") == f"v{spec_version}.mp4" for item in (listing or [])):
            return None
        return client.storage.from_(_VIDEO_BUCKET).get_public_url(path)
    except Exception:
        logger.exception("Failed to probe video for song %s", song_id)
        return None

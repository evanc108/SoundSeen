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


async def insert_song(song_id: str, filename: str, storage_path: str, analysis: dict):
    client = get_client()
    try:
        client.table("songs").insert({
            "id": song_id,
            "filename": filename,
            "storage_path": storage_path,
            "analysis": analysis,
        }).execute()
    except Exception:
        logger.exception("Failed to insert song %s", song_id)
        raise


async def fetch_song(song_id: str) -> dict | None:
    client = get_client()
    result = client.table("songs").select("analysis").eq("id", song_id).single().execute()
    return result.data["analysis"] if result.data else None


async def upload_audio(song_id: str, filename: str, file_bytes: bytes, content_type: str) -> str:
    client = get_client()
    path = f"{song_id}/{filename}"
    try:
        client.storage.from_("audio-uploads").upload(path, file_bytes, {"content-type": content_type})
    except Exception:
        logger.exception("Failed to upload audio for song %s", song_id)
        raise
    return path

#!/usr/bin/env python3
"""End-to-end SoundSeen render: upload → analyze → render → open MP4.

Usage:
  scripts/render_and_play.py path/to/song.mp3
  scripts/render_and_play.py path/to/song.mp3 --backend https://soundseen-api-production.up.railway.app
  scripts/render_and_play.py path/to/song.mp3 --preset rave

Pure-stdlib so it runs against system Python without the venv.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request
from urllib.parse import urlencode


def post_multipart(url: str, file_path: str) -> dict:
    """Upload a single audio file as multipart/form-data; return parsed JSON."""
    boundary = "soundseenboundary"
    filename = os.path.basename(file_path)
    ext = filename.rsplit(".", 1)[-1].lower() if "." in filename else "mp3"
    content_type = {
        "mp3": "audio/mpeg",
        "wav": "audio/wav",
        "m4a": "audio/mp4",
    }.get(ext, "audio/mpeg")

    with open(file_path, "rb") as f:
        file_data = f.read()

    pre = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'
        f"Content-Type: {content_type}\r\n\r\n"
    ).encode()
    post = f"\r\n--{boundary}--\r\n".encode()
    body = pre + file_data + post

    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=600) as resp:
        return json.loads(resp.read())


def get_json(url: str, timeout: int = 30) -> dict:
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return json.loads(resp.read())


def post_json(url: str, timeout: int = 30) -> dict:
    req = urllib.request.Request(url, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("audio", help="Path to .mp3/.wav/.m4a")
    ap.add_argument("--backend", default="http://localhost:8000",
                    help="Backend base URL (default: localhost:8000)")
    ap.add_argument("--preset", default="default", help="Renderer preset")
    ap.add_argument("--max-seconds", type=float, default=None,
                    help="Clamp render length (smoke-test 10–20s before "
                         "committing GPU time for a full track).")
    ap.add_argument("--no-open", action="store_true",
                    help="Print URL but don't open it automatically")
    ap.add_argument("--poll-interval", type=int, default=4,
                    help="Seconds between status polls (default: 4)")
    ap.add_argument("--timeout", type=int, default=1800,
                    help="Total seconds to wait before giving up. First run "
                         "needs ~5min for Modal to build the renderer image; "
                         "subsequent runs are ~1min. Default: 1800 (30 min).")
    args = ap.parse_args()

    audio_path = os.path.abspath(args.audio)
    if not os.path.isfile(audio_path):
        print(f"audio file not found: {audio_path}", file=sys.stderr)
        sys.exit(1)
    backend = args.backend.rstrip("/")

    # ---- 1. Analyze
    print(f"[1/4] uploading + analyzing {os.path.basename(audio_path)}…")
    t0 = time.time()
    try:
        analysis = post_multipart(f"{backend}/analyze", audio_path)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace") if hasattr(e, "read") else ""
        print(f"      analyze HTTP {e.code}: {body}", file=sys.stderr)
        sys.exit(2)
    except urllib.error.URLError as e:
        print(f"      could not reach backend at {backend}: {e}", file=sys.stderr)
        print( "      is uvicorn running? "
               "(cd soundseen-backend && venv/bin/uvicorn main:app --port 8000)",
               file=sys.stderr)
        sys.exit(2)
    song_id = analysis["song_id"]
    duration = analysis.get("duration_seconds", 0)
    bpm = round(float(analysis.get("bpm") or 0))
    n_sections = len(analysis.get("sections") or [])
    n_beats = len(analysis.get("beat_events") or [])
    print(f"      → song_id={song_id}")
    print(f"      → {duration:.0f}s, {bpm} BPM, "
          f"{n_sections} sections, {n_beats} beats "
          f"(took {time.time()-t0:.1f}s)")

    # ---- 2. Kick render
    print("[2/4] requesting render…")
    qs_params = {"song_id": song_id, "preset": args.preset}
    if args.max_seconds is not None:
        qs_params["max_seconds"] = str(args.max_seconds)
    qs = urlencode(qs_params)
    try:
        job = post_json(f"{backend}/render?{qs}", timeout=60)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace") if hasattr(e, "read") else ""
        print(f"      render HTTP {e.code}: {body}", file=sys.stderr)
        sys.exit(2)
    job_id = job["job_id"]
    status = job["status"]
    print(f"      → job_id={job_id}, status={status}")

    if status == "unavailable":
        print(f"      renderer not deployed: {job.get('error')}", file=sys.stderr)
        sys.exit(3)
    if status == "failed":
        print(f"      spawn failed: {job.get('error')}", file=sys.stderr)
        sys.exit(3)
    if status == "complete":
        video_url = job["video_url"]
        print(f"      → cache hit, video_url={video_url}")
    else:
        # ---- 3. Poll
        print(f"[3/4] polling /render/{job_id} every {args.poll_interval}s "
              f"(can take 1–3 min on a cold Modal worker)…")
        start = time.time()
        last_status = status
        while True:
            elapsed = time.time() - start
            if elapsed > args.timeout:
                print(f"      timed out after {args.timeout}s", file=sys.stderr)
                sys.exit(4)
            time.sleep(args.poll_interval)
            try:
                job = get_json(f"{backend}/render/{job_id}", timeout=30)
            except Exception as e:
                # Transient failure — log and keep polling.
                print(f"      [{elapsed:5.0f}s] poll error: {e}")
                continue
            status = job.get("status", "?")
            progress = job.get("progress") or 0
            if status != last_status:
                print(f"      [{elapsed:5.0f}s] status: {last_status} → {status}")
                last_status = status
            elif progress > 0:
                print(f"      [{elapsed:5.0f}s] {status} ({progress*100:.0f}%)")
            else:
                # Don't fake a percentage. Just show elapsed.
                print(f"      [{elapsed:5.0f}s] {status}")

            if status == "complete":
                video_url = job["video_url"]
                break
            if status in ("failed", "unavailable"):
                print(f"      render {status}: {job.get('error')}", file=sys.stderr)
                sys.exit(5)

    # ---- 4. Play
    print(f"[4/4] done → {video_url}")
    if args.no_open:
        return
    if sys.platform == "darwin":
        subprocess.run(["open", video_url], check=False)
    elif sys.platform.startswith("linux"):
        subprocess.run(["xdg-open", video_url], check=False)
    else:
        print("(open the URL in your browser to watch)")


if __name__ == "__main__":
    # Late import so --help doesn't fail on missing urllib.error elsewhere.
    import urllib.error  # noqa: F401
    main()

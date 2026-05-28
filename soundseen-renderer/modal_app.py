"""Modal deployment for the SoundSeen renderer.

Exposes a single function `render_song` that:
  1. Pulls the audio + composition spec from Supabase storage
  2. Invokes the Node-based Three.js renderer
  3. Uploads the resulting MP4 back to Supabase
  4. Returns the public URL

Wire this up after creating a Modal account:
  $ modal deploy modal_app.py
  $ modal run modal_app.py::render_song --song-id <uuid>

The Railway-hosted backend hits this via Modal's webhook URL — implemented
as a synchronous job in Phase 3, can be promoted to a queue later.
"""

import os
from typing import Optional
import shlex
import subprocess
import tempfile
from pathlib import Path

import modal

# GPU choice: A10G is the cheapest "real GPU" option on Modal that can
# drive WebGL via ANGLE. T4 also works. CPU-only (swiftshader fallback)
# is an order of magnitude slower — don't use it in production.
GPU_KIND = os.environ.get("RENDERER_GPU", "A10G")

image = (
    modal.Image.from_registry(
        "mcr.microsoft.com/playwright:v1.49.0-jammy",
        add_python="3.11",
    )
    .apt_install("ffmpeg")
    # Modal 1.x: copy_local_dir was renamed to add_local_dir.
    # copy=True bakes the files into the image at build time so the
    # subsequent run_commands can see them; without copy=True they'd
    # be mounted only at function-invocation time.
    .add_local_dir(
        "./",
        "/app",
        ignore=["node_modules", "dist", ".git", "*.mp4", "venv", "__pycache__"],
        copy=True,
    )
    .run_commands(
        "cd /app && npm install --no-audit --no-fund",
        # iife matches the local dev build (avoids file:// CORS for
        # ES modules even though Modal serves the page differently;
        # consistent dev/prod is worth the few KB).
        "cd /app && npx tsc -p .",
        "cd /app && npx esbuild src/page/runtime.ts --bundle --format=iife "
        "--outfile=dist/page/runtime.js",
        "cp /app/src/page/host.html /app/dist/page/host.html",
    )
)

app = modal.App("soundseen-renderer", image=image)


# Function timeout: software-rendered WebGL screenshotting at 60fps
# is ~130ms/frame, which means a 4-min song needs ~30min wall time
# even on a GPU instance. (The A10G doesn't help much here because
# headless Chrome's WebGL still uses swiftshader on Linux unless
# you set up ANGLE/Vulkan, which is finicky.) 1800s gives headroom
# for short clips; pass max_seconds to clamp the render length when
# iterating.
@app.function(gpu=GPU_KIND, timeout=3000)
def render_song(
    song_id: str,
    spec_json: str,
    audio_bytes: bytes,
    audio_extension: str = ".mp3",
    max_seconds: Optional[float] = None,
) -> bytes:
    """Render a song's CompositionSpec to MP4. Returns the MP4 bytes.

    The caller (Railway backend) is responsible for fetching `audio_bytes`
    and `spec_json` from Supabase before invoking. The renderer only
    handles GPU work — keeps Modal's job ephemeral.
    """
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        spec_path = tmp_path / "spec.json"
        audio_path = tmp_path / f"audio{audio_extension}"
        out_path = tmp_path / "out.mp4"

        spec_path.write_text(spec_json)
        audio_path.write_bytes(audio_bytes)

        cmd = [
            "node",
            "/app/dist/render.js",
            str(spec_path),
            str(audio_path),
            str(out_path),
        ]
        if max_seconds is not None:
            cmd.append(str(max_seconds))

        env = {**os.environ, "RENDERER_SONG_ID": song_id}

        proc = subprocess.run(cmd, env=env, capture_output=True, text=True)
        if proc.returncode != 0:
            raise RuntimeError(
                f"renderer failed for {song_id}: {proc.stderr}\nstdout: {proc.stdout}"
            )

        return out_path.read_bytes()


@app.local_entrypoint()
def main(spec_json_path: str, audio_path: str, out_path: str, max_seconds: float = 30.0):
    """Local sanity check:  modal run modal_app.py::main --spec ... --audio ... --out out.mp4"""
    spec_json = Path(spec_json_path).read_text()
    audio_bytes = Path(audio_path).read_bytes()
    audio_ext = Path(audio_path).suffix or ".mp3"
    mp4 = render_song.remote(
        song_id="local-test",
        spec_json=spec_json,
        audio_bytes=audio_bytes,
        audio_extension=audio_ext,
        max_seconds=max_seconds,
    )
    Path(out_path).write_bytes(mp4)
    print(f"wrote {out_path} ({len(mp4) / 1024 / 1024:.1f} MB)")

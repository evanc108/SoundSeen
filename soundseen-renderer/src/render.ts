// Node-side orchestrator. Loads the scene host page in headless Chrome
// via Playwright, steps frames at fixed dt, reads each frame back as
// raw PNG bytes, and pipes them to FFmpeg for H.264 encoding.
//
// Audio is muxed into the final MP4 in a second FFmpeg pass with -c copy
// so it stays bit-identical to the source upload.

import { spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { chromium, type Browser, type Page } from "playwright";
import type { CompositionSpec } from "./types.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const FPS = 60;
const WIDTH = 1920;
const HEIGHT = 1080;

interface RenderOptions {
  specPath: string;
  audioPath: string;
  outputPath: string;
  /// Optional cap so dev iterations don't render full 4-min tracks.
  maxSeconds?: number;
}

async function readSpec(specPath: string): Promise<CompositionSpec> {
  const raw = await fs.readFile(specPath, "utf-8");
  return JSON.parse(raw) as CompositionSpec;
}

async function launchPage(): Promise<{ browser: Browser; page: Page }> {
  // GL backend selection. Default = swiftshader (matches Modal's headless
  // Chrome WebGL fallback so renders are bit-identical across local + cloud).
  // Set RENDERER_GL=angle for real GPU on local dev — much faster + works
  // with composer HalfFloat MRTs that swiftshader struggles to allocate.
  const glBackend = process.env.RENDERER_GL || "swiftshader";
  const browser = await chromium.launch({
    args: [
      "--disable-gpu-vsync",
      "--disable-background-timer-throttling",
      "--disable-renderer-backgrounding",
      "--enable-gpu-rasterization",
      "--enable-webgl",
      `--use-gl=${glBackend}`,
    ],
  });
  const context = await browser.newContext({
    viewport: { width: WIDTH, height: HEIGHT },
  });
  const page = await context.newPage();

  // Surface page-side errors and console output so silent runtime
  // failures don't show up only as "waitForFunction timeout."
  page.on("console", (msg) => {
    process.stderr.write(`[page:${msg.type()}] ${msg.text()}\n`);
  });
  page.on("pageerror", (err) => {
    process.stderr.write(`[page:error] ${err.message}\n${err.stack ?? ""}\n`);
  });

  return { browser, page };
}

async function renderVideoTrack(
  spec: CompositionSpec,
  page: Page,
  videoOnlyPath: string,
  maxSeconds: number,
): Promise<void> {
  // FFmpeg child reads PNGs from stdin, encodes H.264.
  const ffmpeg = spawn(
    "ffmpeg",
    [
      "-y",
      "-f", "image2pipe",
      "-vcodec", "png",
      "-r", String(FPS),
      "-i", "-",
      "-vcodec", "libx264",
      "-pix_fmt", "yuv420p",
      "-preset", "veryfast",
      "-crf", "20",
      "-r", String(FPS),
      videoOnlyPath,
    ],
    { stdio: ["pipe", "inherit", "inherit"] },
  );
  ffmpeg.on("error", (err: NodeJS.ErrnoException) => {
    if (err.code === "ENOENT") {
      console.error(
        "\n[error] ffmpeg not found on PATH. Install it:\n" +
        "  macOS:  brew install ffmpeg\n" +
        "  Linux:  apt install ffmpeg  (or your distro's equivalent)\n",
      );
    }
  });

  const totalFrames = Math.floor(maxSeconds * FPS);
  for (let frame = 0; frame < totalFrames; frame++) {
    const t = frame / FPS;
    await page.evaluate((time) => (window as any).__renderFrameAt(time), t);
    const png = await page.locator("canvas").screenshot({ type: "png", omitBackground: false });
    if (!ffmpeg.stdin.write(png)) {
      await new Promise<void>((resolve) => ffmpeg.stdin.once("drain", () => resolve()));
    }
    if (frame % FPS === 0) {
      const sec = (frame / FPS).toFixed(1);
      process.stderr.write(`rendered ${sec}s / ${maxSeconds.toFixed(1)}s\n`);
    }
  }

  ffmpeg.stdin.end();
  await new Promise<void>((resolve, reject) => {
    ffmpeg.on("exit", (code) => (code === 0 ? resolve() : reject(new Error(`ffmpeg exit ${code}`))));
    ffmpeg.on("error", reject);
  });
}

function muxAudio(videoPath: string, audioPath: string, outputPath: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const ffmpeg = spawn(
      "ffmpeg",
      [
        "-y",
        "-i", videoPath,
        "-i", audioPath,
        "-c:v", "copy",
        "-c:a", "aac",
        "-b:a", "192k",
        "-shortest",
        outputPath,
      ],
      { stdio: "inherit" },
    );
    ffmpeg.on("exit", (code) => (code === 0 ? resolve() : reject(new Error(`ffmpeg mux exit ${code}`))));
    ffmpeg.on("error", reject);
  });
}

export async function renderComposition(opts: RenderOptions): Promise<void> {
  const spec = await readSpec(opts.specPath);
  const maxSeconds = Math.min(
    opts.maxSeconds ?? Number.POSITIVE_INFINITY,
    spec.duration_seconds,
  );

  const { browser, page } = await launchPage();
  try {
    const hostHtml = pathToFileURL(path.join(__dirname, "page", "host.html")).toString();
    await page.goto(hostHtml);
    await page.waitForFunction(() => (window as any).__ready === true);
    await page.evaluate((s) => (window as any).__loadSpec(s), spec as any);

    const tmpVideo = `${opts.outputPath}.video.mp4`;
    await renderVideoTrack(spec, page, tmpVideo, maxSeconds);
    await muxAudio(tmpVideo, opts.audioPath, opts.outputPath);
    await fs.unlink(tmpVideo).catch(() => undefined);
  } finally {
    await browser.close();
  }
}

// CLI entrypoint: `node dist/render.js <spec.json> <audio.mp3> <out.mp4> [maxSeconds]`
if (process.argv[1] && process.argv[1].endsWith("render.js")) {
  const [, , specPath, audioPath, outputPath, maxSecondsArg] = process.argv;
  if (!specPath || !audioPath || !outputPath) {
    console.error("usage: render <spec.json> <audio.mp3> <out.mp4> [maxSeconds]");
    process.exit(2);
  }
  const maxSeconds = maxSecondsArg ? Number(maxSecondsArg) : undefined;
  renderComposition({ specPath, audioPath, outputPath, maxSeconds }).catch((err) => {
    console.error(err);
    process.exit(1);
  });
}

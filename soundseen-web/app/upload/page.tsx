"use client";

import { useRef, useState, useEffect, useCallback } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { AnimatePresence, motion } from "framer-motion";

import { createClient } from "@/lib/supabase/client";
import { api, type RenderStatus } from "@/lib/api";

const ALLOWED_EXT = [".mp3", ".wav", ".m4a"];
const MAX_BYTES = 50 * 1024 * 1024;
const PREVIEW_DURATION = 90;

type Phase =
  | { kind: "idle" }
  | { kind: "decoding"; filename: string }
  | { kind: "preview"; file: File; duration: number; startSeconds: number }
  | { kind: "uploading"; filename: string }
  | { kind: "analyzing"; filename: string }
  | {
      kind: "rendering";
      filename: string;
      songId: string;
      status: RenderStatus;
    }
  | { kind: "failed"; message: string };

const SPRING = { type: "spring" as const, stiffness: 140, damping: 22 };

function fmt(s: number) {
  const m = Math.floor(s / 60);
  const sec = Math.floor(s % 60);
  return `${m}:${sec.toString().padStart(2, "0")}`;
}

export default function UploadPage() {
  const router = useRouter();
  const inputRef = useRef<HTMLInputElement>(null);
  const [phase, setPhase] = useState<Phase>({ kind: "idle" });
  const [dragOver, setDragOver] = useState(false);

  async function prepareFile(file: File) {
    const ext = "." + (file.name.split(".").pop() ?? "").toLowerCase();
    if (!ALLOWED_EXT.includes(ext)) {
      setPhase({ kind: "failed", message: `Unsupported file type (${ext || "unknown"}). Use mp3, wav, or m4a.` });
      return;
    }
    if (file.size > MAX_BYTES) {
      setPhase({ kind: "failed", message: `File is ${Math.round(file.size / 1024 / 1024)} MB. The 50 MB limit keeps renders fast.` });
      return;
    }

    setPhase({ kind: "decoding", filename: file.name });

    try {
      const arrayBuffer = await file.arrayBuffer();
      const audioCtx = new (window.AudioContext || (window as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext!)();
      const audioBuffer = await audioCtx.decodeAudioData(arrayBuffer);
      await audioCtx.close();
      const duration = audioBuffer.duration;

      if (duration <= PREVIEW_DURATION) {
        // Short song — skip selector, go straight to upload
        void startUpload(file, 0);
      } else {
        setPhase({ kind: "preview", file, duration, startSeconds: 0 });
      }
    } catch {
      // Fallback: if decode fails just upload with no start offset
      void startUpload(file, 0);
    }
  }

  async function startUpload(file: File, startSeconds: number) {
    const supabase = createClient();
    const { data: { session } } = await supabase.auth.getSession();
    if (!session) {
      setPhase({ kind: "failed", message: "Your session expired. Sign in again to upload." });
      return;
    }

    setPhase({ kind: "uploading", filename: file.name });
    await new Promise((r) => setTimeout(r, 0));
    setPhase({ kind: "analyzing", filename: file.name });

    let songId: string;
    try {
      const result = await api.analyze(file, session.access_token, startSeconds);
      songId = result.songId;
    } catch (e) {
      setPhase({ kind: "failed", message: (e as Error).message });
      return;
    }

    setPhase({ kind: "rendering", filename: file.name, songId, status: "queued" });
    pollUntilComplete(songId, file.name);
  }

  async function pollUntilComplete(songId: string, filename: string) {
    while (true) {
      try {
        const [job] = await api.jobsForSongs([songId]);
        if (!job) { await new Promise((r) => setTimeout(r, 1500)); continue; }
        if (job.status === "complete") { router.push(`/song/${songId}`); return; }
        if (job.status === "failed" || job.status === "unavailable") {
          setPhase({ kind: "failed", message: job.error ?? `Render ${job.status}.` });
          return;
        }
        setPhase({ kind: "rendering", filename, songId, status: job.status });
      } catch (e) {
        const msg = (e as Error).message;
        if (msg.startsWith("HTTP 401") || msg.startsWith("HTTP 403")) {
          setPhase({ kind: "failed", message: msg });
          return;
        }
      }
      await new Promise((r) => setTimeout(r, 3000));
    }
  }

  function onFile(file: File | undefined) {
    if (file) void prepareFile(file);
  }

  const isDropzone = phase.kind === "idle" || phase.kind === "failed" || phase.kind === "decoding";

  return (
    <div className="mx-auto max-w-[920px] px-8 py-16">
      <header className="mb-10">
        <p className="font-mono text-[10px] uppercase tracking-[0.28em] text-[var(--color-text-3)]">
          New visualization
        </p>
        <h1 className="mt-2 text-3xl font-medium tracking-tight">Upload</h1>
        <p className="mt-3 max-w-[58ch] text-[14px] leading-relaxed text-[var(--color-text-2)]">
          mp3, wav, or m4a — up to 50 MB. Pick a{" "}
          <span className="text-[var(--color-text)]">90-second</span> window
          to visualize. Renders keep going on our servers even if you close this
          tab — check{" "}
          <Link
            href="/me"
            className="text-[var(--color-text)] underline decoration-[var(--color-hairline-2)] underline-offset-4 hover:decoration-[var(--color-text)]"
          >
            My uploads
          </Link>{" "}
          when you come back.
        </p>
      </header>

      <AnimatePresence mode="wait" initial={false}>
        {isDropzone ? (
          <motion.div
            key="dropzone"
            initial={{ opacity: 0, y: 6 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -6 }}
            transition={SPRING}
          >
            <DropZone
              loading={phase.kind === "decoding"}
              dragOver={dragOver}
              onDragOver={(e) => { e.preventDefault(); setDragOver(true); }}
              onDragLeave={() => setDragOver(false)}
              onDrop={(e) => { e.preventDefault(); setDragOver(false); onFile(e.dataTransfer.files?.[0]); }}
              onClick={() => inputRef.current?.click()}
            />
            {phase.kind === "failed" && (
              <p className="mt-5 rounded-2xl border border-red-500/20 bg-red-500/5 px-5 py-4 text-[13px] text-red-200/90">
                <span className="block font-medium text-red-200">Couldn&rsquo;t start that upload.</span>
                <span className="mt-1 block font-mono text-[11px] text-red-200/60">{phase.message}</span>
              </p>
            )}
          </motion.div>
        ) : phase.kind === "preview" ? (
          <motion.div
            key="preview"
            initial={{ opacity: 0, y: 6 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -6 }}
            transition={SPRING}
          >
            <PreviewSelector
              file={phase.file}
              duration={phase.duration}
              startSeconds={phase.startSeconds}
              onChange={(s) => setPhase({ ...phase, startSeconds: s })}
              onConfirm={() => void startUpload(phase.file, phase.startSeconds)}
              onBack={() => setPhase({ kind: "idle" })}
            />
          </motion.div>
        ) : (
          <motion.div
            key="progress"
            initial={{ opacity: 0, y: 6 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -6 }}
            transition={SPRING}
          >
            <ProgressPanel phase={phase as Exclude<Phase, { kind: "idle" } | { kind: "failed" } | { kind: "preview" } | { kind: "decoding" }>} />
          </motion.div>
        )}
      </AnimatePresence>

      <input
        ref={inputRef}
        type="file"
        accept={ALLOWED_EXT.join(",")}
        className="hidden"
        onChange={(e) => onFile(e.target.files?.[0] ?? undefined)}
      />
    </div>
  );
}

/* ─── Waveform preview selector ─────────────────────────────────────────── */

function PreviewSelector({
  file,
  duration,
  startSeconds,
  onChange,
  onConfirm,
  onBack,
}: {
  file: File;
  duration: number;
  startSeconds: number;
  onChange: (s: number) => void;
  onConfirm: () => void;
  onBack: () => void;
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const trackRef = useRef<HTMLDivElement>(null);
  const dragging = useRef(false);

  // Audio playback refs
  const audioBufRef = useRef<AudioBuffer | null>(null);
  const audioCtxRef = useRef<AudioContext | null>(null);
  const sourceRef = useRef<AudioBufferSourceNode | null>(null);
  const playStartCtxTimeRef = useRef<number>(0);
  const rafRef = useRef<number>(0);

  const [playing, setPlaying] = useState(false);
  const [playheadFrac, setPlayheadFrac] = useState<number | null>(null); // 0–1 within window

  const windowFrac = PREVIEW_DURATION / duration;
  const maxStart = duration - PREVIEW_DURATION;
  const leftFrac = startSeconds / duration;
  const endSeconds = Math.min(startSeconds + PREVIEW_DURATION, duration);

  // Decode audio once, draw waveform, keep buffer for playback
  useEffect(() => {
    let cancelled = false;
    async function init() {
      const ab = await file.arrayBuffer();
      if (cancelled) return;
      const ctx = new (window.AudioContext || (window as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext!)();
      const buf = await ctx.decodeAudioData(ab.slice(0));
      if (cancelled) { await ctx.close(); return; }

      audioBufRef.current = buf;
      audioCtxRef.current = ctx;

      // Draw waveform
      const canvas = canvasRef.current;
      if (!canvas) return;
      const c = canvas.getContext("2d");
      if (!c) return;
      const data = buf.getChannelData(0);
      const W = canvas.width;
      const H = canvas.height;
      const samplesPerBar = Math.floor(data.length / W);
      c.clearRect(0, 0, W, H);
      for (let i = 0; i < W; i++) {
        let max = 0;
        for (let j = 0; j < samplesPerBar; j++) {
          const v = Math.abs(data[i * samplesPerBar + j] ?? 0);
          if (v > max) max = v;
        }
        const barH = Math.max(2, max * H * 0.9);
        c.fillStyle = "rgba(255,255,255,0.18)";
        c.fillRect(i, (H - barH) / 2, 1, barH);
      }
    }
    void init();
    return () => {
      cancelled = true;
      stopPlayback();
      audioCtxRef.current?.close();
      audioCtxRef.current = null;
      audioBufRef.current = null;
    };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [file]);

  function stopPlayback() {
    cancelAnimationFrame(rafRef.current);
    try { sourceRef.current?.stop(); } catch { /* already stopped */ }
    sourceRef.current = null;
    setPlaying(false);
    setPlayheadFrac(null);
  }

  function togglePlay() {
    if (playing) { stopPlayback(); return; }
    const buf = audioBufRef.current;
    const ctx = audioCtxRef.current;
    if (!buf || !ctx) return;

    // Resume AudioContext if suspended (browser autoplay policy)
    if (ctx.state === "suspended") ctx.resume();

    const src = ctx.createBufferSource();
    src.buffer = buf;
    src.connect(ctx.destination);
    const clipDuration = Math.min(PREVIEW_DURATION, duration - startSeconds);
    src.start(0, startSeconds, clipDuration);
    src.onended = () => { setPlaying(false); setPlayheadFrac(null); };
    sourceRef.current = src;
    playStartCtxTimeRef.current = ctx.currentTime;
    setPlaying(true);
    setPlayheadFrac(0);

    function tick() {
      const elapsed = (audioCtxRef.current?.currentTime ?? 0) - playStartCtxTimeRef.current;
      const frac = Math.min(1, elapsed / clipDuration);
      setPlayheadFrac(frac);
      if (frac < 1) rafRef.current = requestAnimationFrame(tick);
    }
    rafRef.current = requestAnimationFrame(tick);
  }

  const posFromEvent = useCallback((clientX: number) => {
    const track = trackRef.current;
    if (!track) return;
    const rect = track.getBoundingClientRect();
    const frac = Math.max(0, Math.min(1 - windowFrac, (clientX - rect.left) / rect.width));
    onChange(Math.round(frac * duration));
  }, [duration, onChange, windowFrac]);

  const onMouseDown = (e: React.MouseEvent) => {
    stopPlayback();
    dragging.current = true;
    posFromEvent(e.clientX);
    const onMove = (ev: MouseEvent) => { if (dragging.current) posFromEvent(ev.clientX); };
    const onUp = () => { dragging.current = false; window.removeEventListener("mousemove", onMove); window.removeEventListener("mouseup", onUp); };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
  };

  const onTouchStart = (e: React.TouchEvent) => {
    stopPlayback();
    posFromEvent(e.touches[0].clientX);
    const onMove = (ev: TouchEvent) => posFromEvent(ev.touches[0].clientX);
    const onEnd = () => { window.removeEventListener("touchmove", onMove); window.removeEventListener("touchend", onEnd); };
    window.addEventListener("touchmove", onMove);
    window.addEventListener("touchend", onEnd);
  };

  return (
    <div className="overflow-hidden rounded-3xl border border-[var(--color-hairline)] bg-[var(--color-surface)]">
      <div className="px-8 pt-8 pb-6 border-b border-[var(--color-hairline)]">
        <p className="font-mono text-[10px] uppercase tracking-[0.28em] text-[var(--color-text-3)]">
          Pick a 90-second clip
        </p>
        <h2 className="mt-2 truncate text-xl font-medium tracking-tight text-[var(--color-text)]">
          {file.name.replace(/\.(mp3|wav|m4a)$/i, "")}
        </h2>
        <p className="mt-1 font-mono text-[11px] text-[var(--color-text-3)]">
          Total: {fmt(duration)}
        </p>
      </div>

      <div className="px-8 py-7 space-y-5">
        {/* Waveform + draggable window */}
        <div
          ref={trackRef}
          className="relative h-20 cursor-pointer select-none rounded-2xl overflow-hidden bg-[var(--color-bg-2)]"
          onMouseDown={onMouseDown}
          onTouchStart={onTouchStart}
        >
          <canvas
            ref={canvasRef}
            width={800}
            height={80}
            className="absolute inset-0 w-full h-full"
          />
          {/* Dimmed sides */}
          <div className="absolute inset-y-0 left-0 bg-black/50 pointer-events-none" style={{ width: `${leftFrac * 100}%` }} />
          <div className="absolute inset-y-0 right-0 bg-black/50 pointer-events-none" style={{ width: `${(1 - leftFrac - windowFrac) * 100}%` }} />

          {/* Selection window */}
          <div
            className="absolute inset-y-0 pointer-events-none border-2 border-white/80 rounded-lg"
            style={{ left: `${leftFrac * 100}%`, width: `${windowFrac * 100}%` }}
          >
            {/* Playhead */}
            {playheadFrac !== null && (
              <div
                className="absolute inset-y-0 w-px bg-white/90 pointer-events-none"
                style={{ left: `${playheadFrac * 100}%` }}
              />
            )}
            {/* Drag handle dots — hidden while playing */}
            {playheadFrac === null && (
              <div className="absolute inset-y-0 left-1/2 -translate-x-1/2 flex items-center justify-center gap-0.5 opacity-60">
                <span className="w-px h-5 bg-white rounded-full" />
                <span className="w-px h-5 bg-white rounded-full" />
                <span className="w-px h-5 bg-white rounded-full" />
              </div>
            )}
          </div>
        </div>

        {/* Time row with play button in the middle */}
        <div className="flex items-center justify-between gap-3">
          <span className="font-mono text-[11px] text-[var(--color-text-3)] w-10 shrink-0">{fmt(0)}</span>

          <div className="flex flex-1 items-center justify-center gap-4">
            {/* Play / Pause button */}
            <button
              onClick={togglePlay}
              className="tactile flex h-10 w-10 shrink-0 items-center justify-center rounded-full border border-[var(--color-hairline-2)] bg-[var(--color-surface-2)] hover:bg-[var(--color-bg-2)] text-[var(--color-text)]"
              title={playing ? "Pause" : "Preview clip"}
            >
              {playing ? (
                /* Pause icon */
                <svg aria-hidden viewBox="0 0 14 14" width="12" height="12" fill="currentColor">
                  <rect x="2.5" y="2" width="3" height="10" rx="1" />
                  <rect x="8.5" y="2" width="3" height="10" rx="1" />
                </svg>
              ) : (
                /* Play icon */
                <svg aria-hidden viewBox="0 0 14 14" width="12" height="12" fill="currentColor">
                  <path d="M3.5 2.5l8 4.5-8 4.5V2.5z" />
                </svg>
              )}
            </button>

            <div className="text-center">
              <p className="font-mono text-[13px] font-medium text-[var(--color-text)]">
                {fmt(startSeconds)} — {fmt(endSeconds)}
              </p>
              <p className="font-mono text-[10px] text-[var(--color-text-3)] mt-0.5">
                {playing ? "Playing preview…" : "Drag to reposition · 90 s clip"}
              </p>
            </div>
          </div>

          <span className="font-mono text-[11px] text-[var(--color-text-3)] w-10 shrink-0 text-right">{fmt(duration)}</span>
        </div>

        {/* Range slider for fine control */}
        <input
          type="range"
          min={0}
          max={Math.round(maxStart)}
          value={Math.round(startSeconds)}
          onChange={(e) => { stopPlayback(); onChange(Number(e.target.value)); }}
          className="w-full accent-white h-px appearance-none bg-[var(--color-hairline-2)] cursor-pointer"
        />
      </div>

      <div className="flex items-center justify-between px-8 pb-8 gap-4">
        <button
          onClick={() => { stopPlayback(); onBack(); }}
          className="tactile inline-flex h-10 items-center rounded-full border border-[var(--color-hairline-2)] px-4 text-[13px] text-[var(--color-text-2)] hover:text-[var(--color-text)] hover:bg-[var(--color-surface-2)]"
        >
          Choose different file
        </button>
        <button
          onClick={() => { stopPlayback(); onConfirm(); }}
          className="tactile inline-flex h-10 items-center gap-2 rounded-full bg-white px-5 text-[13px] font-medium text-black"
        >
          Render this clip
          <svg aria-hidden viewBox="0 0 14 14" width="11" height="11" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
            <path d="M2.5 7h9M7 2.5L11.5 7 7 11.5" />
          </svg>
        </button>
      </div>
    </div>
  );
}

/* ─── Drop zone ──────────────────────────────────────────────────────────── */

function DropZone(props: {
  loading: boolean;
  dragOver: boolean;
  onDragOver: React.DragEventHandler<HTMLButtonElement>;
  onDragLeave: () => void;
  onDrop: React.DragEventHandler<HTMLButtonElement>;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={props.onClick}
      onDragOver={props.onDragOver}
      onDragLeave={props.onDragLeave}
      onDrop={props.onDrop}
      disabled={props.loading}
      className={[
        "relative flex w-full flex-col items-start justify-end gap-3 overflow-hidden rounded-3xl border-2 border-dashed px-10 py-20 text-left transition-all duration-300",
        props.dragOver
          ? "border-white/30 bg-[var(--color-surface)]"
          : "border-[var(--color-hairline-2)] hover:border-white/20 hover:bg-[var(--color-surface)]",
      ].join(" ")}
    >
      {props.dragOver && <span className="pointer-events-none absolute inset-0 shimmer opacity-40" />}
      {props.loading && <span className="pointer-events-none absolute inset-0 shimmer opacity-20" />}
      <span className="relative font-mono text-[10px] uppercase tracking-[0.28em] text-[var(--color-text-3)]">
        {props.loading ? "Reading audio…" : "Drop zone"}
      </span>
      <span className="relative text-2xl font-medium tracking-tight text-[var(--color-text)]">
        {props.loading ? "Analyzing waveform" : "Drop an audio file"}
      </span>
      <span className="relative text-[13px] text-[var(--color-text-2)]">
        {props.loading ? "This only takes a second." : "or click to choose · mp3 · wav · m4a · up to 50 MB"}
      </span>
    </button>
  );
}

/* ─── Progress panel ─────────────────────────────────────────────────────── */

const STEPS: Array<{ kind: Exclude<Phase["kind"], "idle" | "failed" | "preview" | "decoding">; label: string }> = [
  { kind: "uploading", label: "Upload" },
  { kind: "analyzing", label: "Analyze" },
  { kind: "rendering", label: "Render" },
];

function ProgressPanel({
  phase,
}: {
  phase: Exclude<Phase, { kind: "idle" } | { kind: "failed" } | { kind: "preview" } | { kind: "decoding" }>;
}) {
  const activeIdx = STEPS.findIndex((s) => s.kind === phase.kind);
  return (
    <div className="overflow-hidden rounded-3xl border border-[var(--color-hairline)] bg-[var(--color-surface)]">
      <div className="px-8 pt-8 pb-6">
        <p className="font-mono text-[10px] uppercase tracking-[0.28em] text-[var(--color-text-3)]">
          {phase.kind === "rendering" && phase.status === "queued" ? "Queued" : "In progress"}
        </p>
        <h2 className="mt-2 truncate text-2xl font-medium tracking-tight">{phase.filename}</h2>
      </div>

      <ol className="flex border-y border-[var(--color-hairline)]">
        {STEPS.map((step, i) => {
          const isActive = i === activeIdx;
          const isDone = i < activeIdx;
          return (
            <li key={step.kind} className={["relative flex-1 px-6 py-5", i > 0 && "border-l border-[var(--color-hairline)]"].filter(Boolean).join(" ")}>
              <div className="flex items-center gap-2.5">
                <StepDot active={isActive} done={isDone} />
                <span className={`font-mono text-[10px] uppercase tracking-[0.22em] ${isActive || isDone ? "text-[var(--color-text)]" : "text-[var(--color-text-3)]"}`}>
                  {step.label}
                </span>
              </div>
              <div className="mt-3 h-px overflow-hidden bg-[var(--color-hairline)]">
                {(isActive || isDone) && (
                  <motion.div
                    initial={{ scaleX: 0 }}
                    animate={{ scaleX: 1 }}
                    transition={{ duration: isDone ? 0.4 : 1.4, ease: "easeOut" }}
                    style={{ originX: 0 }}
                    className="h-full bg-[var(--color-text)]"
                  />
                )}
              </div>
            </li>
          );
        })}
      </ol>

      <div className="px-8 py-7">
        <PhaseDescription phase={phase} />
      </div>
    </div>
  );
}

function StepDot({ active, done }: { active: boolean; done: boolean }) {
  if (done) {
    return (
      <span className="flex h-4 w-4 items-center justify-center rounded-full bg-[var(--color-text)]">
        <svg aria-hidden viewBox="0 0 10 10" width="8" height="8" fill="none" stroke="black" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
          <path d="M2 5l2 2 4-4.5" />
        </svg>
      </span>
    );
  }
  if (active) {
    return (
      <span className="relative h-4 w-4">
        <span className="absolute inset-0 rounded-full bg-white/15" />
        <span className="absolute inset-[3px] rounded-full bg-white breathe" />
      </span>
    );
  }
  return <span className="h-4 w-4 rounded-full border border-[var(--color-hairline-2)]" />;
}

function PhaseDescription({ phase }: { phase: Phase }) {
  if (phase.kind === "uploading" || phase.kind === "analyzing") {
    return (
      <div className="space-y-2">
        <p className="text-[14px] text-[var(--color-text)]">
          {phase.kind === "uploading" ? "Uploading your audio." : "Reading mood, structure, and beat grid."}
        </p>
        <p className="text-[13px] text-[var(--color-text-2)]">
          {phase.kind === "uploading" ? "A few seconds for most songs." : "Usually 5 to 15 seconds."}
        </p>
      </div>
    );
  }
  if (phase.kind === "rendering") {
    return (
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div className="space-y-1">
          <p className="text-[14px] text-[var(--color-text)]">Rendering on a GPU. 30 seconds to a few minutes.</p>
          <p className="text-[13px] text-[var(--color-text-2)]">You can close this tab — the render keeps going on our servers.</p>
        </div>
        <Link
          href="/me"
          className="tactile inline-flex h-10 shrink-0 items-center gap-2 self-start rounded-full border border-[var(--color-hairline-2)] bg-[var(--color-surface-2)] px-4 text-[13px] font-medium text-[var(--color-text)] hover:bg-[var(--color-bg-2)] sm:self-auto"
        >
          Watch progress on My uploads
          <svg aria-hidden viewBox="0 0 14 14" width="11" height="11" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round">
            <path d="M2.5 7h9M7 2.5L11.5 7 7 11.5" />
          </svg>
        </Link>
      </div>
    );
  }
  return null;
}

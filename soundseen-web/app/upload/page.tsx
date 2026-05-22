"use client";

import { useRef, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { AnimatePresence, motion } from "framer-motion";

import { createClient } from "@/lib/supabase/client";
import { api, type RenderStatus } from "@/lib/api";

const ALLOWED_EXT = [".mp3", ".wav", ".m4a"];
const MAX_BYTES = 50 * 1024 * 1024;

type Phase =
  | { kind: "idle" }
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

export default function UploadPage() {
  const router = useRouter();
  const inputRef = useRef<HTMLInputElement>(null);
  const [phase, setPhase] = useState<Phase>({ kind: "idle" });
  const [dragOver, setDragOver] = useState(false);

  async function startUpload(file: File) {
    const ext = "." + (file.name.split(".").pop() ?? "").toLowerCase();
    if (!ALLOWED_EXT.includes(ext)) {
      setPhase({
        kind: "failed",
        message: `Unsupported file type (${ext || "unknown"}). Use mp3, wav, or m4a.`,
      });
      return;
    }
    if (file.size > MAX_BYTES) {
      setPhase({
        kind: "failed",
        message: `File is ${Math.round(file.size / 1024 / 1024)} MB. The 50 MB limit keeps renders fast — try compressing to mp3.`,
      });
      return;
    }

    const supabase = createClient();
    const {
      data: { session },
    } = await supabase.auth.getSession();
    if (!session) {
      setPhase({
        kind: "failed",
        message: "Your session expired. Sign in again to upload.",
      });
      return;
    }

    setPhase({ kind: "uploading", filename: file.name });
    await new Promise((r) => setTimeout(r, 0));
    setPhase({ kind: "analyzing", filename: file.name });

    let songId: string;
    try {
      const result = await api.analyze(file, session.access_token);
      songId = result.songId;
    } catch (e) {
      setPhase({ kind: "failed", message: (e as Error).message });
      return;
    }

    setPhase({
      kind: "rendering",
      filename: file.name,
      songId,
      status: "queued",
    });
    pollUntilComplete(songId, file.name);
  }

  async function pollUntilComplete(songId: string, filename: string) {
    while (true) {
      try {
        const [job] = await api.jobsForSongs([songId]);
        if (!job) {
          await new Promise((r) => setTimeout(r, 1500));
          continue;
        }
        if (job.status === "complete") {
          router.push(`/song/${songId}`);
          return;
        }
        if (job.status === "failed" || job.status === "unavailable") {
          setPhase({
            kind: "failed",
            message: job.error ?? `Render ${job.status}.`,
          });
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
    if (file) void startUpload(file);
  }

  return (
    <div className="mx-auto max-w-[920px] px-8 py-16">
      <header className="mb-10">
        <p className="font-mono text-[10px] uppercase tracking-[0.28em] text-[var(--color-text-3)]">
          New visualization
        </p>
        <h1 className="mt-2 text-3xl font-medium tracking-tight">Upload</h1>
        <p className="mt-3 max-w-[58ch] text-[14px] leading-relaxed text-[var(--color-text-2)]">
          mp3, wav, or m4a — up to 50 MB. We render the first{" "}
          <span className="text-[var(--color-text)]">60 seconds</span> of your
          song as a video preview. Renders keep going on our servers even if
          you close this tab — check{" "}
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
        {phase.kind === "idle" || phase.kind === "failed" ? (
          <motion.div
            key="dropzone"
            initial={{ opacity: 0, y: 6 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -6 }}
            transition={SPRING}
          >
            <DropZone
              dragOver={dragOver}
              onDragOver={(e) => {
                e.preventDefault();
                setDragOver(true);
              }}
              onDragLeave={() => setDragOver(false)}
              onDrop={(e) => {
                e.preventDefault();
                setDragOver(false);
                onFile(e.dataTransfer.files?.[0]);
              }}
              onClick={() => inputRef.current?.click()}
            />
            {phase.kind === "failed" && (
              <p className="mt-5 rounded-2xl border border-red-500/20 bg-red-500/5 px-5 py-4 text-[13px] text-red-200/90">
                <span className="block font-medium text-red-200">
                  Couldn’t start that upload.
                </span>
                <span className="mt-1 block font-mono text-[11px] text-red-200/60">
                  {phase.message}
                </span>
              </p>
            )}
          </motion.div>
        ) : (
          <motion.div
            key="progress"
            initial={{ opacity: 0, y: 6 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -6 }}
            transition={SPRING}
          >
            <ProgressPanel phase={phase} />
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

function DropZone(props: {
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
      className={[
        "relative flex w-full flex-col items-start justify-end gap-3 overflow-hidden rounded-3xl border-2 border-dashed px-10 py-20 text-left transition-all duration-300",
        props.dragOver
          ? "border-white/30 bg-[var(--color-surface)]"
          : "border-[var(--color-hairline-2)] hover:border-white/20 hover:bg-[var(--color-surface)]",
      ].join(" ")}
    >
      {props.dragOver && (
        <span className="pointer-events-none absolute inset-0 shimmer opacity-40" />
      )}
      <span className="relative font-mono text-[10px] uppercase tracking-[0.28em] text-[var(--color-text-3)]">
        Drop zone
      </span>
      <span className="relative text-2xl font-medium tracking-tight text-[var(--color-text)]">
        Drop an audio file
      </span>
      <span className="relative text-[13px] text-[var(--color-text-2)]">
        or click to choose · mp3 · wav · m4a · up to 50 MB
      </span>
    </button>
  );
}

const STEPS: Array<{ kind: Exclude<Phase["kind"], "idle" | "failed">; label: string }> = [
  { kind: "uploading", label: "Upload" },
  { kind: "analyzing", label: "Analyze" },
  { kind: "rendering", label: "Render" },
];

function ProgressPanel({
  phase,
}: {
  phase: Exclude<Phase, { kind: "idle" } | { kind: "failed" }>;
}) {
  const activeIdx = STEPS.findIndex((s) => s.kind === phase.kind);
  return (
    <div className="overflow-hidden rounded-3xl border border-[var(--color-hairline)] bg-[var(--color-surface)]">
      <div className="px-8 pt-8 pb-6">
        <p className="font-mono text-[10px] uppercase tracking-[0.28em] text-[var(--color-text-3)]">
          {phase.kind === "rendering" && phase.status === "queued"
            ? "Queued"
            : "In progress"}
        </p>
        <h2 className="mt-2 truncate text-2xl font-medium tracking-tight">
          {phase.filename}
        </h2>
      </div>

      <ol className="flex border-y border-[var(--color-hairline)]">
        {STEPS.map((step, i) => {
          const isActive = i === activeIdx;
          const isDone = i < activeIdx;
          return (
            <li
              key={step.kind}
              className={[
                "relative flex-1 px-6 py-5",
                i > 0 && "border-l border-[var(--color-hairline)]",
              ]
                .filter(Boolean)
                .join(" ")}
            >
              <div className="flex items-center gap-2.5">
                <StepDot active={isActive} done={isDone} />
                <span
                  className={`font-mono text-[10px] uppercase tracking-[0.22em] ${
                    isActive || isDone
                      ? "text-[var(--color-text)]"
                      : "text-[var(--color-text-3)]"
                  }`}
                >
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
        <svg
          aria-hidden
          viewBox="0 0 10 10"
          width="8"
          height="8"
          fill="none"
          stroke="black"
          strokeWidth="1.8"
          strokeLinecap="round"
          strokeLinejoin="round"
        >
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
  return (
    <span className="h-4 w-4 rounded-full border border-[var(--color-hairline-2)]" />
  );
}

function PhaseDescription({ phase }: { phase: Phase }) {
  if (phase.kind === "uploading" || phase.kind === "analyzing") {
    return (
      <div className="space-y-2">
        <p className="text-[14px] text-[var(--color-text)]">
          {phase.kind === "uploading"
            ? "Uploading your audio."
            : "Reading mood, structure, and beat grid."}
        </p>
        <p className="text-[13px] text-[var(--color-text-2)]">
          {phase.kind === "uploading"
            ? "A few seconds for most songs."
            : "Usually 5 to 15 seconds."}
        </p>
      </div>
    );
  }
  if (phase.kind === "rendering") {
    return (
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div className="space-y-1">
          <p className="text-[14px] text-[var(--color-text)]">
            Rendering on a GPU. 30 seconds to a few minutes.
          </p>
          <p className="text-[13px] text-[var(--color-text-2)]">
            You can close this tab — the render keeps going on our servers.
          </p>
        </div>
        <Link
          href="/me"
          className="tactile inline-flex h-10 shrink-0 items-center gap-2 self-start rounded-full border border-[var(--color-hairline-2)] bg-[var(--color-surface-2)] px-4 text-[13px] font-medium text-[var(--color-text)] hover:bg-[var(--color-bg-2)] sm:self-auto"
        >
          Watch progress on My uploads
          <svg
            aria-hidden
            viewBox="0 0 14 14"
            width="11"
            height="11"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.6"
            strokeLinecap="round"
          >
            <path d="M2.5 7h9M7 2.5L11.5 7 7 11.5" />
          </svg>
        </Link>
      </div>
    );
  }
  return null;
}

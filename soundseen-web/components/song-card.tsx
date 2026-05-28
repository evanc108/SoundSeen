"use client";

import Link from "next/link";
import { useEffect, useRef, useState } from "react";

import type { SongCard as SongCardData } from "@/lib/api";

type Variant = "default" | "wide" | "tall" | "feature";

const VARIANT_ASPECT: Record<Variant, string> = {
  default: "aspect-video",
  wide: "aspect-[21/9]",
  tall: "aspect-[3/4]",
  feature: "aspect-[16/10]",
};

const STATUS_TONE: Record<string, string> = {
  queued: "text-[var(--color-text-3)]",
  rendering: "text-[var(--color-text-3)]",
  complete: "text-[var(--color-text-2)]",
  failed: "text-red-300/80",
  unavailable: "text-[var(--color-text-3)]",
};

const STATUS_LABEL: Record<string, string> = {
  queued: "Queued",
  rendering: "Rendering",
  complete: "Ready",
  failed: "Failed",
  unavailable: "Offline",
};

export function SongCard({
  song,
  variant = "default",
}: {
  song: SongCardData;
  variant?: Variant;
}) {
  const containerRef = useRef<HTMLAnchorElement | null>(null);
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const [inView, setInView] = useState(false);
  const ready = song.renderStatus === "complete" && !!song.videoUrl;
  const aspect = VARIANT_ASPECT[variant];

  // Only mount the <video> element when the card scrolls near the viewport.
  // Saves dozens of metadata fetches when the gallery has lots of rows.
  useEffect(() => {
    if (!ready || !containerRef.current) return;
    const el = containerRef.current;
    const io = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setInView(true);
          io.disconnect();
        }
      },
      { rootMargin: "200px" },
    );
    io.observe(el);
    return () => io.disconnect();
  }, [ready]);

  return (
    <Link
      ref={containerRef}
      href={`/song/${song.songId}`}
      className="lift group relative block overflow-hidden rounded-2xl border border-[var(--color-hairline)] bg-[var(--color-surface)]"
      onMouseEnter={() => {
        const v = videoRef.current;
        if (v && ready) {
          v.play().catch(() => {});
        }
      }}
      onMouseLeave={() => {
        const v = videoRef.current;
        if (v && ready) {
          v.pause();
          v.currentTime = 0;
        }
      }}
    >
      <div className={`relative w-full ${aspect} overflow-hidden bg-black`}>
        {ready && inView ? (
          <video
            ref={videoRef}
            src={song.videoUrl!}
            muted
            loop
            playsInline
            preload="none"
            className="h-full w-full object-cover transition-opacity duration-500 group-hover:opacity-95"
          />
        ) : (
          <PendingFrame status={song.renderStatus} ready={ready} />
        )}
        <div className="absolute inset-0 ring-1 ring-inset ring-white/5 transition-opacity duration-300 group-hover:opacity-0" />
      </div>

      <div className="flex items-end justify-between gap-4 px-4 py-3.5">
        <div className="min-w-0 flex-1">
          <h3 className="truncate text-[13.5px] font-medium tracking-tight text-[var(--color-text)]">
            {song.filename ?? song.songId.slice(0, 8)}
          </h3>
          <p className="mt-1 font-mono text-[11px] text-[var(--color-text-3)]">
            {formatMeta(song)}
          </p>
        </div>
        <StatusPip status={song.renderStatus ?? null} />
      </div>
    </Link>
  );
}

function PendingFrame({
  status,
  ready = false,
}: {
  status: SongCardData["renderStatus"];
  ready?: boolean;
}) {
  const inFlight = status === "queued" || status === "rendering";
  const showLabel = inFlight;
  return (
    <div className="relative flex h-full w-full items-center justify-center bg-[radial-gradient(ellipse_at_center,_rgba(255,255,255,0.04),_transparent_70%)]">
      {(inFlight || ready) && (
        <div className="absolute inset-0 shimmer opacity-50" />
      )}
      {showLabel && (
        <span className="z-10 font-mono text-[10px] uppercase tracking-[0.35em] text-[var(--color-text-3)]">
          {STATUS_LABEL[status ?? ""] ?? "Pending"}
        </span>
      )}
    </div>
  );
}

function StatusPip({ status }: { status: string | null }) {
  if (!status || status === "failed" || status === "unavailable") return null;
  const isInFlight = status === "queued" || status === "rendering";
  const dotClass = [
    "block h-1.5 w-1.5 rounded-full",
    status === "complete" && "bg-[var(--color-signal)]",
    isInFlight && "bg-white/70 breathe",
    status === "failed" && "bg-red-400/80",
    status === "unavailable" && "bg-[var(--color-text-3)]",
  ]
    .filter(Boolean)
    .join(" ");
  return (
    <div className="flex items-center gap-1.5">
      <span className={dotClass} aria-hidden />
      <span
        className={`font-mono text-[10px] uppercase tracking-[0.18em] ${STATUS_TONE[status] ?? ""}`}
      >
        {STATUS_LABEL[status] ?? status}
      </span>
    </div>
  );
}

function formatMeta(song: SongCardData): string {
  const parts: string[] = [];
  if (song.durationSeconds) {
    const total = Math.round(song.durationSeconds);
    parts.push(
      `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`,
    );
  }
  if (song.bpm) {
    parts.push(`${Math.round(song.bpm)} bpm`);
  }
  return parts.join("  ·  ");
}

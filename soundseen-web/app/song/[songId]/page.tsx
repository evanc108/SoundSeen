import Link from "next/link";
import { notFound } from "next/navigation";

import { DeleteSongButton } from "@/components/delete-song-button";
import { RenderWatcher } from "@/components/render-watcher";
import { api, type SongDetail, type RenderJobStatus } from "@/lib/api";
import { createClient } from "@/lib/supabase/server";

type PageProps = {
  params: Promise<{ songId: string }>;
};

export const revalidate = 0;

export default async function SongPage({ params }: PageProps) {
  const { songId } = await params;

  let song: SongDetail;
  try {
    song = await api.song(songId);
  } catch {
    notFound();
  }

  let job: RenderJobStatus | undefined;
  try {
    [job] = await api.jobsForSongs([songId]);
  } catch {
    job = undefined;
  }
  const videoUrl = job?.status === "complete" ? job.videoUrl : null;
  const isInFlight = job?.status === "queued" || job?.status === "rendering";

  // Ownership probe — viewer is owner if their auth.uid matches.
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  let isOwner = false;
  if (user) {
    try {
      const owner = await api.songOwner(songId);
      isOwner = owner.userId === user.id;
    } catch {
      isOwner = false;
    }
  }

  return (
    <div className="mx-auto max-w-[1400px] px-8 py-8">
      {isInFlight && <RenderWatcher songIds={[songId]} />}

      <nav className="mb-6 flex items-center gap-3 text-[13px] text-[var(--color-text-3)]">
        <Link href="/gallery" className="hover:text-[var(--color-text)]">
          Gallery
        </Link>
        <Slash />
        <span className="font-mono text-[11px] tracking-wider text-[var(--color-text-3)]">
          {songId.slice(0, 8)}
        </span>
      </nav>

      <div className="grid grid-cols-1 gap-8 lg:grid-cols-12">
        <div className="lg:col-span-9">
          <div className="overflow-hidden rounded-3xl border border-[var(--color-hairline)] bg-black">
            {videoUrl ? (
              <video
                src={videoUrl}
                controls
                autoPlay
                playsInline
                preload="auto"
                className="aspect-video w-full"
              />
            ) : (
              <InFlightFrame status={job?.status ?? null} message={job?.error ?? null} />
            )}
          </div>
        </div>

        <aside className="lg:col-span-3">
          <div className="sticky top-24 space-y-8">
            <div>
              <p className="font-mono text-[10px] uppercase tracking-[0.28em] text-[var(--color-text-3)]">
                Track
              </p>
              <h1 className="mt-2 break-words text-2xl font-medium tracking-tight">
                {song.filename}
              </h1>
            </div>

            <dl className="divide-y divide-[var(--color-hairline)] border-y border-[var(--color-hairline)]">
              <MetaRow label="Duration" value={formatDuration(song.durationSeconds)} />
              <MetaRow label="Tempo" value={`${Math.round(song.bpm)} bpm`} />
              <MetaRow label="Status" value={STATUS_LABEL[job?.status ?? "unavailable"]} />
            </dl>

            {videoUrl && (
              <a
                href={videoUrl}
                target="_blank"
                rel="noreferrer"
                className="tactile inline-flex h-10 w-full items-center justify-center gap-2 rounded-full border border-[var(--color-hairline-2)] text-[13px] font-medium text-[var(--color-text)] hover:bg-[var(--color-surface)]"
              >
                Open mp4
                <ArrowExternal />
              </a>
            )}

            {isOwner && <DeleteSongButton songId={songId} />}
          </div>
        </aside>
      </div>
    </div>
  );
}

function MetaRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between py-3">
      <dt className="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--color-text-3)]">
        {label}
      </dt>
      <dd className="font-mono text-[12px] text-[var(--color-text)]">
        {value}
      </dd>
    </div>
  );
}

const STATUS_LABEL: Record<string, string> = {
  queued: "Queued",
  rendering: "Rendering",
  complete: "Ready",
  failed: "Pending",
  unavailable: "Offline",
};

function InFlightFrame({
  status,
  message,
}: {
  status: string | null;
  message: string | null;
}) {
  const inFlight = status === "queued" || status === "rendering";
  return (
    <div className="relative flex aspect-video w-full items-center justify-center overflow-hidden">
      {inFlight && <div className="absolute inset-0 shimmer opacity-50" />}
      {inFlight && (
        <div className="relative z-10 flex flex-col items-center gap-4 text-center">
          <span className="relative h-3 w-3">
            <span className="absolute inset-0 rounded-full bg-white/25" />
            <span className="absolute inset-[2px] rounded-full bg-white breathe" />
          </span>
          <p className="font-mono text-[11px] uppercase tracking-[0.28em] text-[var(--color-text-2)]">
            {STATUS_LABEL[status] ?? "Rendering"}
          </p>
          <p className="max-w-[36ch] text-[13px] text-[var(--color-text-3)]">
            Rendering on a GPU. This page refreshes automatically when it’s
            ready.
          </p>
        </div>
      )}
    </div>
  );
}

function formatDuration(seconds: number): string {
  const total = Math.round(seconds);
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`;
}

function Slash() {
  return (
    <span aria-hidden className="text-[var(--color-text-3)]">
      /
    </span>
  );
}

function ArrowExternal() {
  return (
    <svg
      aria-hidden
      viewBox="0 0 14 14"
      width="11"
      height="11"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M5 9.5L11 3.5M11 3.5H6M11 3.5V8.5" />
    </svg>
  );
}

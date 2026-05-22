import Link from "next/link";
import { redirect } from "next/navigation";

import { RenderWatcher } from "@/components/render-watcher";
import { SongCard } from "@/components/song-card";
import { api, type SongCard as SongCardData } from "@/lib/api";
import { createClient } from "@/lib/supabase/server";

export const revalidate = 0;

type Variant = "default" | "wide" | "tall" | "feature";

function variantFor(index: number): Variant {
  const r = index % 12;
  if (r === 0) return "feature";
  if (r === 3) return "tall";
  if (r === 7) return "wide";
  if (r === 10) return "tall";
  return "default";
}

export default async function MyUploadsPage() {
  const supabase = await createClient();
  const {
    data: { session },
  } = await supabase.auth.getSession();
  if (!session) redirect("/auth/sign-in?next=/me");

  let songs: SongCardData[] = [];
  let error: string | null = null;
  try {
    songs = await api.mySongs(session.access_token);
  } catch (e) {
    error = (e as Error).message;
  }

  const inFlight = songs.filter(
    (s) => s.renderStatus === "queued" || s.renderStatus === "rendering",
  );
  const inFlightIds = inFlight.map((s) => s.songId);

  return (
    <div className="mx-auto max-w-[1400px] px-8 py-12">
      {inFlightIds.length > 0 && <RenderWatcher songIds={inFlightIds} />}

      <header className="mb-10 flex flex-wrap items-end justify-between gap-6 border-b border-[var(--color-hairline)] pb-8">
        <div>
          <p className="font-mono text-[10px] uppercase tracking-[0.28em] text-[var(--color-text-3)]">
            Library · {session.user.email}
          </p>
          <h1 className="mt-2 text-3xl font-medium tracking-tight">My uploads</h1>
          <p className="mt-2 max-w-[52ch] text-[14px] text-[var(--color-text-2)]">
            Everything you’ve uploaded, including renders still in flight. This
            page refreshes automatically as renders finish.
          </p>
        </div>
        <Link
          href="/upload"
          className="tactile inline-flex h-10 items-center gap-2 rounded-full bg-white px-4 text-[13px] font-medium text-black"
        >
          New upload
          <Plus />
        </Link>
      </header>

      {inFlight.length > 0 && <InFlightBanner count={inFlight.length} />}

      {error ? (
        <ErrorBlock message={error} />
      ) : songs.length === 0 ? (
        <EmptyState />
      ) : (
        <div className="columns-1 gap-3 sm:columns-2 lg:columns-3 xl:columns-4 [column-fill:_balance]">
          {songs.map((song, i) => (
            <div key={song.songId} className="mb-3 break-inside-avoid">
              <SongCard song={song} variant={variantFor(i)} />
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function InFlightBanner({ count }: { count: number }) {
  return (
    <div className="mb-8 flex items-center gap-4 rounded-2xl border border-[var(--color-hairline-2)] bg-[var(--color-surface)] px-5 py-4">
      <span className="relative h-2.5 w-2.5">
        <span className="absolute inset-0 rounded-full bg-white/20" />
        <span className="absolute inset-[2px] rounded-full bg-white breathe" />
      </span>
      <p className="text-[13px] text-[var(--color-text)]">
        {count === 1
          ? "1 render in progress."
          : `${count} renders in progress.`}
      </p>
      <span className="ml-auto font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--color-text-3)]">
        Auto-refreshing
      </span>
    </div>
  );
}

function EmptyState() {
  return (
    <div className="flex flex-col items-start gap-6 rounded-3xl border border-dashed border-[var(--color-hairline-2)] bg-[var(--color-surface)] px-10 py-16">
      <span className="font-mono text-[10px] uppercase tracking-[0.28em] text-[var(--color-text-3)]">
        Empty
      </span>
      <h2 className="text-2xl font-medium tracking-tight">
        No uploads yet.
      </h2>
      <p className="max-w-[44ch] text-[14px] text-[var(--color-text-2)]">
        Drop an mp3 and we’ll render it. Renders keep going on our servers even
        if you close the tab.
      </p>
      <Link
        href="/upload"
        className="tactile inline-flex h-10 items-center gap-2 rounded-full bg-white px-4 text-[13px] font-medium text-black"
      >
        Upload your first song
        <ArrowRight />
      </Link>
    </div>
  );
}

function ErrorBlock({ message }: { message: string }) {
  return (
    <div className="rounded-2xl border border-red-500/20 bg-red-500/5 px-6 py-5 text-sm text-red-200/90">
      <p className="font-medium">Couldn’t load your uploads.</p>
      <p className="mt-1 font-mono text-[11px] text-red-200/60">{message}</p>
    </div>
  );
}

function Plus() {
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
    >
      <path d="M7 1.5v11M1.5 7h11" />
    </svg>
  );
}

function ArrowRight() {
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
      <path d="M2.5 7h9M7 2.5L11.5 7 7 11.5" />
    </svg>
  );
}

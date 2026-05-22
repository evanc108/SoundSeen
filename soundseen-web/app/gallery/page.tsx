import Link from "next/link";

import { SongCard } from "@/components/song-card";
import { api, type SongCard as SongCardData } from "@/lib/api";

export const revalidate = 60;

const PAGE_SIZE = 24;

type Variant = "default" | "wide" | "tall" | "feature";

/** Mix variants deterministically so the bento doesn't reflow when
 *  the underlying gallery shifts by one card. Pattern repeats every 12. */
function variantFor(index: number): Variant {
  const r = index % 12;
  if (r === 0) return "feature";
  if (r === 3) return "tall";
  if (r === 7) return "wide";
  if (r === 10) return "tall";
  return "default";
}

type PageProps = {
  searchParams: Promise<{ page?: string }>;
};

export default async function GalleryPage({ searchParams }: PageProps) {
  const params = await searchParams;
  const pageNum = Math.max(1, Number(params.page ?? "1") || 1);
  const offset = (pageNum - 1) * PAGE_SIZE;

  let songs: SongCardData[] = [];
  let error: string | null = null;
  try {
    songs = await api.gallery(PAGE_SIZE, offset);
  } catch (e) {
    error = (e as Error).message;
  }

  return (
    <div className="mx-auto max-w-[1400px] px-8 py-12">
      <header className="mb-10 flex items-end justify-between border-b border-[var(--color-hairline)] pb-8">
        <div>
          <p className="font-mono text-[10px] uppercase tracking-[0.28em] text-[var(--color-text-3)]">
            Public archive
          </p>
          <h1 className="mt-2 text-3xl font-medium tracking-tight">Gallery</h1>
          <p className="mt-2 max-w-[52ch] text-[14px] text-[var(--color-text-2)]">
            Every visualization, every user, newest first. Hover to preview.
          </p>
        </div>
        <div className="hidden font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--color-text-3)] md:block">
          Page {String(pageNum).padStart(2, "0")}
        </div>
      </header>

      {error ? (
        <ErrorBlock message={error} />
      ) : songs.length === 0 ? (
        <EmptyState page={pageNum} />
      ) : (
        <div className="columns-1 gap-3 sm:columns-2 lg:columns-3 xl:columns-4 [column-fill:_balance]">
          {songs.map((song, i) => (
            <div
              key={song.songId}
              className="mb-3 break-inside-avoid"
              style={{
                animation: `fadeUp 600ms cubic-bezier(0.16, 1, 0.3, 1) both`,
                animationDelay: `${Math.min(i * 40, 600)}ms`,
              }}
            >
              <SongCard song={song} variant={variantFor(i)} />
            </div>
          ))}
        </div>
      )}

      <nav className="mt-12 flex items-center justify-between border-t border-[var(--color-hairline)] pt-6 text-[13px]">
        {pageNum > 1 ? (
          <PageLink page={pageNum - 1} dir="prev">
            Newer
          </PageLink>
        ) : (
          <span className="text-[var(--color-text-3)]">Start of archive</span>
        )}
        <span className="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--color-text-3)]">
          {String(pageNum).padStart(2, "0")} / —
        </span>
        {songs.length === PAGE_SIZE ? (
          <PageLink page={pageNum + 1} dir="next">
            Older
          </PageLink>
        ) : (
          <span className="text-[var(--color-text-3)]">End of archive</span>
        )}
      </nav>

      {/* Keyframes for the page-load stagger */}
      <style>{`@keyframes fadeUp { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: none; } }`}</style>
    </div>
  );
}

function PageLink({
  page,
  dir,
  children,
}: {
  page: number;
  dir: "prev" | "next";
  children: React.ReactNode;
}) {
  return (
    <Link
      href={`/gallery?page=${page}`}
      className="tactile inline-flex items-center gap-2 rounded-full border border-[var(--color-hairline)] px-4 py-2 text-[var(--color-text-2)] transition-colors hover:bg-[var(--color-surface)] hover:text-[var(--color-text)]"
    >
      {dir === "prev" && <Arrow direction="left" />}
      {children}
      {dir === "next" && <Arrow direction="right" />}
    </Link>
  );
}

function Arrow({ direction }: { direction: "left" | "right" }) {
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
      style={{ transform: direction === "left" ? "rotate(180deg)" : undefined }}
    >
      <path d="M2.5 7h9M7 2.5L11.5 7 7 11.5" />
    </svg>
  );
}

function EmptyState({ page }: { page: number }) {
  return (
    <div className="flex flex-col items-start gap-6 rounded-3xl border border-dashed border-[var(--color-hairline-2)] bg-[var(--color-surface)] px-10 py-16">
      <span className="font-mono text-[10px] uppercase tracking-[0.28em] text-[var(--color-text-3)]">
        Empty
      </span>
      <h2 className="text-2xl font-medium tracking-tight">
        {page === 1 ? "Nothing here yet." : "End of the archive."}
      </h2>
      <p className="max-w-[42ch] text-[14px] text-[var(--color-text-2)]">
        {page === 1
          ? "Be the first to upload a song. Visualizations land here once they finish rendering."
          : "Try going back to a more recent page."}
      </p>
      {page === 1 && (
        <Link
          href="/upload"
          className="tactile inline-flex h-10 items-center gap-2 rounded-full bg-white px-4 text-[13px] font-medium text-black"
        >
          Upload a song
          <Arrow direction="right" />
        </Link>
      )}
    </div>
  );
}

function ErrorBlock({ message }: { message: string }) {
  return (
    <div className="rounded-2xl border border-red-500/20 bg-red-500/5 px-6 py-5 text-sm text-red-200/90">
      <p className="font-medium">Couldn’t reach the backend.</p>
      <p className="mt-1 font-mono text-[11px] text-red-200/60">{message}</p>
    </div>
  );
}

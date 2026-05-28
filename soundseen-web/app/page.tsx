import Link from "next/link";

import { SongCard } from "@/components/song-card";
import { api, type SongCard as SongCardData } from "@/lib/api";

export const revalidate = 60;

export default async function HomePage() {
  let recent: SongCardData[] = [];
  try {
    recent = await api.gallery(24, 0);
  } catch {
    recent = [];
  }
  const featuredId = "f481db4a-ff21-4c7f-adc9-e85cd3827170";
  const featuredIdx = recent.findIndex((s) => s.songId === featuredId);
  const featured = featuredIdx >= 0 ? recent.splice(featuredIdx, 1)[0] : recent.shift();
  const gridSongs = recent.slice(0, 8);
  const marqueeItems = recent
    .map((s) => marqueeLabel(s.filename))
    .filter((s): s is string => !!s);

  return (
    <>
      <div className="mx-auto max-w-[1400px] px-8">
        <section className="grid grid-cols-1 gap-12 py-14 lg:grid-cols-12 lg:gap-10 lg:py-20">
          <div className="flex flex-col gap-10 lg:col-span-5">
            <div className="space-y-6">
              <p className="font-mono text-[10px] uppercase tracking-[0.28em] text-[var(--color-text-3)]">
                A music visualizer, built on librosa
              </p>
              <h1 className="text-balance text-[44px] font-medium leading-[1.02] tracking-tight md:text-[60px]">
                Render any song
                <br />
                to video.
              </h1>
              <p className="max-w-[42ch] text-[15px] leading-relaxed text-[var(--color-text-2)]">
                Drop an mp3. We read the mood, structure, and beat grid, then
                render a cinematic visualization on a GPU. Close the tab and we
                keep going.
              </p>
            </div>

            <div className="flex flex-wrap items-center gap-2.5">
              <Link
                href="/upload"
                className="tactile inline-flex h-11 items-center gap-2 rounded-full bg-white px-5 text-[13px] font-medium text-black"
              >
                Upload a song
                <ArrowRight />
              </Link>
              <Link
                href="/gallery"
                className="tactile inline-flex h-11 items-center rounded-full border border-[var(--color-hairline-2)] px-5 text-[13px] font-medium text-[var(--color-text)] hover:bg-[var(--color-surface)]"
              >
                Browse gallery
              </Link>
            </div>

            <HowItWorks />
          </div>

          <div className="lg:col-span-7">
            {featured ? <FeaturedFrame song={featured} /> : <EmptyFeatured />}
          </div>
        </section>

        {gridSongs.length > 0 && (
          <section className="pb-20">
            <header className="mb-6 flex items-end justify-between border-t border-[var(--color-hairline)] pt-8">
              <div>
                <h2 className="text-xl font-medium tracking-tight">Recent</h2>
                <p className="mt-1 font-mono text-[11px] uppercase tracking-[0.2em] text-[var(--color-text-3)]">
                  Public archive · newest first
                </p>
              </div>
              <Link
                href="/gallery"
                className="group inline-flex items-center gap-1.5 text-[13px] text-[var(--color-text-2)] hover:text-[var(--color-text)]"
              >
                See all
                <ArrowRight className="transition-transform duration-300 group-hover:translate-x-0.5" />
              </Link>
            </header>

            <div className="grid grid-cols-2 gap-3 md:grid-cols-3 lg:grid-cols-4">
              {gridSongs.map((song, i) => {
                const colSpan =
                  i === 0 ? "md:col-span-2" : i === 3 ? "lg:col-span-2" : "";
                const variant = i === 0 || i === 3 ? "wide" : "default";
                return (
                  <div key={song.songId} className={colSpan}>
                    <SongCard song={song} variant={variant} />
                  </div>
                );
              })}
            </div>
          </section>
        )}
      </div>

      {marqueeItems.length > 0 && <Marquee items={marqueeItems} />}

      <div className="mx-auto max-w-[1400px] px-8">
        <Pipeline />
        <Specs />
        <BottomCTA />
      </div>
    </>
  );
}

function HowItWorks() {
  const steps = [
    {
      n: "01",
      label: "Upload audio",
      body: "mp3, wav, or m4a — up to 50 MB.",
    },
    {
      n: "02",
      label: "Analyze",
      body: "Mood, structure, beat grid, spectral content.",
    },
    {
      n: "03",
      label: "Render",
      body: "Cinematic video, on a GPU, then shared back.",
    },
  ];
  return (
    <ol className="grid grid-cols-1 divide-y divide-[var(--color-hairline)] border-y border-[var(--color-hairline)] sm:grid-cols-3 sm:divide-x sm:divide-y-0">
      {steps.map((s) => (
        <li
          key={s.n}
          className="px-1 py-5 sm:px-5 sm:first:pl-0 sm:last:pr-0"
        >
          <div className="flex items-center gap-3">
            <span className="font-mono text-[10px] tracking-[0.2em] text-[var(--color-text-3)]">
              {s.n}
            </span>
            <span className="text-[13px] font-medium text-[var(--color-text)]">
              {s.label}
            </span>
          </div>
          <p className="mt-2 text-[12px] leading-relaxed text-[var(--color-text-2)]">
            {s.body}
          </p>
        </li>
      ))}
    </ol>
  );
}

function FeaturedFrame({ song }: { song: SongCardData }) {
  const ready = song.renderStatus === "complete" && !!song.videoUrl;
  return (
    <Link
      href={`/song/${song.songId}`}
      className="lift group relative block h-full min-h-[480px] overflow-hidden rounded-3xl border border-[var(--color-hairline)] bg-[var(--color-surface)]"
    >
      {ready ? (
        <video
          src={song.videoUrl!}
          autoPlay
          muted
          loop
          playsInline
          preload="metadata"
          className="absolute inset-0 h-full w-full object-cover"
        />
      ) : (
        <div className="absolute inset-0 flex items-center justify-center">
          <div className="absolute inset-0 shimmer" />
          <span className="z-10 font-mono text-[10px] uppercase tracking-[0.35em] text-[var(--color-text-3)]">
            Rendering
          </span>
        </div>
      )}
      <div className="absolute inset-x-0 bottom-0 h-1/3 bg-gradient-to-t from-black/70 via-black/30 to-transparent" />
      <div className="absolute inset-x-0 bottom-0 flex items-end justify-between p-6">
        <div>
          <p className="font-mono text-[10px] uppercase tracking-[0.28em] text-white/60">
            Featured
          </p>
          <h3 className="mt-2 max-w-[40ch] truncate text-xl font-medium tracking-tight text-white">
            {song.filename ?? song.songId.slice(0, 8)}
          </h3>
        </div>
        <span className="hidden rounded-full border border-white/15 bg-black/30 px-3 py-1.5 font-mono text-[10px] uppercase tracking-[0.18em] text-white/80 backdrop-blur sm:inline-flex">
          Watch
        </span>
      </div>
    </Link>
  );
}

function EmptyFeatured() {
  return (
    <div className="relative flex h-full min-h-[480px] flex-col items-start justify-end overflow-hidden rounded-3xl border border-dashed border-[var(--color-hairline-2)] bg-[var(--color-surface)] p-8">
      <div className="absolute inset-0 shimmer opacity-30" />
      <div className="relative z-10 space-y-2">
        <p className="font-mono text-[10px] uppercase tracking-[0.28em] text-[var(--color-text-3)]">
          Empty archive
        </p>
        <h3 className="text-xl font-medium tracking-tight text-[var(--color-text)]">
          No visualizations yet.
        </h3>
        <p className="max-w-[36ch] text-[13px] text-[var(--color-text-2)]">
          Be the first. Upload a song to seed the gallery.
        </p>
      </div>
    </div>
  );
}

function Marquee({ items }: { items: string[] }) {
  // Duplicate so the -50% loop appears seamless.
  const doubled = [...items, ...items];
  return (
    <section
      aria-hidden
      className="relative overflow-hidden border-y border-[var(--color-hairline)] bg-[var(--color-bg-2)] py-10"
    >
      <div className="pointer-events-none absolute inset-y-0 left-0 z-10 w-32 bg-gradient-to-r from-[var(--color-bg-2)] to-transparent" />
      <div className="pointer-events-none absolute inset-y-0 right-0 z-10 w-32 bg-gradient-to-l from-[var(--color-bg-2)] to-transparent" />
      <p className="mb-6 px-8 font-mono text-[10px] uppercase tracking-[0.28em] text-[var(--color-text-3)]">
        Lately
      </p>
      <div className="marquee flex w-max items-center">
        {doubled.map((label, i) => (
          <span
            key={i}
            className="flex items-center whitespace-nowrap text-[28px] font-medium tracking-tight text-[var(--color-text-2)] md:text-[36px]"
          >
            <span className="px-8">{label}</span>
            <span
              className="text-[var(--color-text-3)]/40"
              aria-hidden
            >
              ·
            </span>
          </span>
        ))}
      </div>
    </section>
  );
}

function Pipeline() {
  return (
    <section className="grid grid-cols-12 gap-10 border-t border-[var(--color-hairline)] py-24">
      <div className="col-span-12 lg:col-span-3">
        <p className="font-mono text-[10px] uppercase tracking-[0.28em] text-[var(--color-text-3)]">
          Under the hood
        </p>
      </div>
      <div className="col-span-12 space-y-10 lg:col-span-9">
        <p className="text-balance text-[24px] font-medium leading-[1.35] tracking-tight text-[var(--color-text)] md:text-[32px]">
          The analyzer reads a song the way a producer would. It locks onto
          the beat grid, finds the structural sections — intros, drops,
          breakdowns — and reads the spectral content frame by frame. The
          renderer treats that score as a brief.
        </p>
        <div className="grid gap-10 sm:grid-cols-2">
          <div className="space-y-3">
            <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--color-text-3)]">
              Mood
            </p>
            <p className="text-[14px] leading-relaxed text-[var(--color-text-2)]">
              Valence and arousal land the song in one of four visual biomes.
              Slow and heavy passages render dark and narrow. Bright, fast
              passages open up. The hue rotates with the chord centroid;
              saturation tracks how tonal the moment is.
            </p>
          </div>
          <div className="space-y-3">
            <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--color-text-3)]">
              Rhythm
            </p>
            <p className="text-[14px] leading-relaxed text-[var(--color-text-2)]">
              Beat alignment is sample-accurate. The visualizer pulses on the
              downbeat, breathes on the bar line, and resets through transition
              zones. Drops trigger bloom, chromatic aberration, and a brief
              camera shake. Nothing is interpolated after the fact.
            </p>
          </div>
        </div>
        <Link
          href="/about"
          className="inline-flex items-center gap-1.5 text-[13px] text-[var(--color-text-2)] transition-colors hover:text-[var(--color-text)]"
        >
          Read the full mapping
          <ArrowRight />
        </Link>
      </div>
    </section>
  );
}

function Specs() {
  const rows: Array<[string, string, string]> = [
    ["01", "Format", "MP4 · H.264 · 30 fps"],
    ["02", "Aspect", "9 : 16 vertical · 1080 × 1920"],
    ["03", "Length", "Matches the song · capped at 8 min"],
    ["04", "Audio", "Original track muxed in, lossless"],
    ["05", "Render", "GPU pipeline on Modal · ~1× realtime"],
    ["06", "Delivery", "Hosted on a shareable URL, public by default"],
  ];
  return (
    <section className="border-t border-[var(--color-hairline)] py-24">
      <header className="mb-12 flex items-end justify-between">
        <h2 className="text-balance text-3xl font-medium tracking-tight md:text-4xl">
          What comes back.
        </h2>
        <p className="hidden font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--color-text-3)] md:block">
          Output spec
        </p>
      </header>
      <dl className="grid grid-cols-1 gap-px overflow-hidden rounded-2xl bg-[var(--color-hairline)] sm:grid-cols-2 lg:grid-cols-3">
        {rows.map(([n, label, value]) => (
          <div
            key={n}
            className="flex flex-col gap-6 bg-[var(--color-bg)] px-6 py-7"
          >
            <div className="flex items-center justify-between font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--color-text-3)]">
              <span>{n}</span>
              <span>{label}</span>
            </div>
            <dd className="text-[18px] font-medium leading-snug tracking-tight text-[var(--color-text)]">
              {value}
            </dd>
          </div>
        ))}
      </dl>
    </section>
  );
}

function BottomCTA() {
  return (
    <section className="relative overflow-hidden border-t border-[var(--color-hairline)] py-28">
      <div
        aria-hidden
        className="drift pointer-events-none absolute -top-32 left-1/2 h-[420px] w-[820px] -translate-x-1/2 rounded-full bg-[radial-gradient(closest-side,_rgba(255,255,255,0.08),_transparent_70%)] blur-2xl"
      />
      <div className="relative grid grid-cols-12 items-end gap-8">
        <h2 className="col-span-12 text-balance text-[40px] font-medium leading-[1.05] tracking-tight md:col-span-9 md:text-[64px]">
          Bring a song.
          <br />
          <span className="text-[var(--color-text-3)]">Leave with a film.</span>
        </h2>
        <div className="col-span-12 flex justify-start md:col-span-3 md:justify-end">
          <Link
            href="/upload"
            className="tactile inline-flex h-12 items-center gap-2 rounded-full bg-white px-6 text-[14px] font-medium text-black"
          >
            Start
            <ArrowRight />
          </Link>
        </div>
      </div>
    </section>
  );
}

function marqueeLabel(name: string | null): string | null {
  if (!name) return null;
  const stripped = name
    .replace(/\.(mp3|wav|m4a|flac|ogg|aac)$/i, "")
    .replace(/\s*\(mp3cut\.net\)\s*/i, "")
    .trim();
  if (stripped.length < 3) return null;
  // Drop UUID-looking filenames.
  if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-/i.test(stripped)) return null;
  return stripped.length > 64 ? `${stripped.slice(0, 61)}…` : stripped;
}

function ArrowRight({ className = "" }: { className?: string }) {
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
      className={className}
    >
      <path d="M2.5 7h9M7 2.5L11.5 7 7 11.5" />
    </svg>
  );
}

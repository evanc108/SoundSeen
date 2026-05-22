import { SongCardSkeleton } from "@/components/song-card-skeleton";

const PATTERN: Array<"default" | "wide" | "tall" | "feature"> = [
  "feature",
  "default",
  "default",
  "tall",
  "default",
  "default",
  "default",
  "wide",
  "default",
  "default",
  "tall",
  "default",
];

export default function GalleryLoading() {
  return (
    <div className="mx-auto max-w-[1400px] px-8 py-12">
      <header className="mb-10 flex items-end justify-between border-b border-[var(--color-hairline)] pb-8">
        <div className="space-y-3">
          <div className="h-2 w-24 overflow-hidden rounded-full bg-[var(--color-surface-2)]">
            <div className="shimmer h-full w-full" />
          </div>
          <div className="h-7 w-32 overflow-hidden rounded bg-[var(--color-surface-2)]">
            <div className="shimmer h-full w-full" />
          </div>
          <div className="h-3 w-72 overflow-hidden rounded bg-[var(--color-surface-2)]">
            <div className="shimmer h-full w-full" />
          </div>
        </div>
      </header>

      <div className="columns-1 gap-3 sm:columns-2 lg:columns-3 xl:columns-4 [column-fill:_balance]">
        {PATTERN.map((variant, i) => (
          <div key={i} className="mb-3 break-inside-avoid">
            <SongCardSkeleton variant={variant} />
          </div>
        ))}
      </div>
    </div>
  );
}

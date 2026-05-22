import { SongCardSkeleton } from "@/components/song-card-skeleton";

export default function HomeLoading() {
  return (
    <div className="mx-auto max-w-[1400px] px-8">
      <section className="grid min-h-[78dvh] grid-cols-1 gap-12 py-16 lg:grid-cols-12 lg:gap-8 lg:py-24">
        <div className="space-y-8 lg:col-span-5">
          <div className="h-2.5 w-44 overflow-hidden rounded-full bg-[var(--color-surface-2)]">
            <div className="shimmer h-full w-full" />
          </div>
          <div className="space-y-4">
            <div className="h-12 w-3/4 overflow-hidden rounded bg-[var(--color-surface-2)]">
              <div className="shimmer h-full w-full" />
            </div>
            <div className="h-12 w-2/3 overflow-hidden rounded bg-[var(--color-surface-2)]">
              <div className="shimmer h-full w-full" />
            </div>
          </div>
          <div className="space-y-2">
            <div className="h-3 w-full overflow-hidden rounded bg-[var(--color-surface-2)]">
              <div className="shimmer h-full w-full" />
            </div>
            <div className="h-3 w-5/6 overflow-hidden rounded bg-[var(--color-surface-2)]">
              <div className="shimmer h-full w-full" />
            </div>
          </div>
          <div className="flex gap-3">
            <div className="h-11 w-36 overflow-hidden rounded-full bg-[var(--color-surface-2)]">
              <div className="shimmer h-full w-full" />
            </div>
            <div className="h-11 w-36 overflow-hidden rounded-full bg-[var(--color-surface-2)]">
              <div className="shimmer h-full w-full" />
            </div>
          </div>
        </div>
        <div className="lg:col-span-7">
          <div className="h-full min-h-[420px] overflow-hidden rounded-3xl bg-[var(--color-surface-2)]">
            <div className="shimmer h-full w-full" />
          </div>
        </div>
      </section>

      <section className="pb-24">
        <div className="mb-6 border-t border-[var(--color-hairline)] pt-8">
          <div className="h-5 w-24 overflow-hidden rounded bg-[var(--color-surface-2)]">
            <div className="shimmer h-full w-full" />
          </div>
        </div>
        <div className="grid grid-cols-2 gap-3 md:grid-cols-3 lg:grid-cols-4">
          <div className="md:col-span-2">
            <SongCardSkeleton variant="wide" />
          </div>
          <SongCardSkeleton />
          <SongCardSkeleton />
          <div className="lg:col-span-2">
            <SongCardSkeleton variant="wide" />
          </div>
          <SongCardSkeleton />
          <SongCardSkeleton />
          <SongCardSkeleton />
          <SongCardSkeleton />
        </div>
      </section>
    </div>
  );
}

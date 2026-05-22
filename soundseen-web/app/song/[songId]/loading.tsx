export default function SongLoading() {
  return (
    <div className="mx-auto max-w-[1400px] px-8 py-8">
      <div className="mb-6 flex items-center gap-3 text-[13px]">
        <div className="h-3 w-16 overflow-hidden rounded bg-[var(--color-surface-2)]">
          <div className="shimmer h-full w-full" />
        </div>
      </div>

      <div className="grid grid-cols-1 gap-8 lg:grid-cols-12">
        <div className="lg:col-span-9">
          <div className="aspect-video overflow-hidden rounded-3xl border border-[var(--color-hairline)] bg-[var(--color-surface)]">
            <div className="shimmer h-full w-full" />
          </div>
        </div>

        <aside className="space-y-8 lg:col-span-3">
          <div className="space-y-3">
            <div className="h-2 w-16 overflow-hidden rounded bg-[var(--color-surface-2)]">
              <div className="shimmer h-full w-full" />
            </div>
            <div className="h-7 w-3/4 overflow-hidden rounded bg-[var(--color-surface-2)]">
              <div className="shimmer h-full w-full" />
            </div>
          </div>
          <div className="border-y border-[var(--color-hairline)] py-2">
            {[0, 1, 2].map((i) => (
              <div
                key={i}
                className="flex items-center justify-between py-3"
              >
                <div className="h-2 w-16 overflow-hidden rounded bg-[var(--color-surface-2)]">
                  <div className="shimmer h-full w-full" />
                </div>
                <div className="h-2 w-12 overflow-hidden rounded bg-[var(--color-surface-2)]">
                  <div className="shimmer h-full w-full" />
                </div>
              </div>
            ))}
          </div>
        </aside>
      </div>
    </div>
  );
}

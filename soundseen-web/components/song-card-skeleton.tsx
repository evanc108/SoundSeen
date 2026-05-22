type Variant = "default" | "wide" | "tall" | "feature";

const ASPECT: Record<Variant, string> = {
  default: "aspect-video",
  wide: "aspect-[21/9]",
  tall: "aspect-[3/4]",
  feature: "aspect-[16/10]",
};

export function SongCardSkeleton({ variant = "default" }: { variant?: Variant }) {
  return (
    <div className="overflow-hidden rounded-2xl border border-[var(--color-hairline)] bg-[var(--color-surface)]">
      <div className={`relative w-full ${ASPECT[variant]} overflow-hidden bg-[var(--color-surface-2)]`}>
        <div className="absolute inset-0 shimmer" />
      </div>
      <div className="flex items-center justify-between gap-4 px-4 py-3.5">
        <div className="flex-1 space-y-2">
          <div className="h-3 w-3/5 overflow-hidden rounded-full bg-[var(--color-surface-2)]">
            <div className="shimmer h-full w-full" />
          </div>
          <div className="h-2.5 w-2/5 overflow-hidden rounded-full bg-[var(--color-surface-2)]">
            <div className="shimmer h-full w-full" />
          </div>
        </div>
        <div className="h-2 w-12 overflow-hidden rounded-full bg-[var(--color-surface-2)]">
          <div className="shimmer h-full w-full" />
        </div>
      </div>
    </div>
  );
}

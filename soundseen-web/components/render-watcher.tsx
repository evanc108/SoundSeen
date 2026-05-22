"use client";

import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";

import { api, type RenderStatus } from "@/lib/api";

/** Polls /jobs?song_ids=... every 4s while the render is in-flight.
 *  Triggers a server-side refresh once the render completes so the page
 *  picks up the new video URL on next paint. Used on /song/[id] and /me. */
export function RenderWatcher({
  songIds,
  intervalMs = 4000,
}: {
  songIds: string[];
  intervalMs?: number;
}) {
  const router = useRouter();
  const [tick, setTick] = useState(0);
  const completedRef = useRef(new Set<string>());

  useEffect(() => {
    if (songIds.length === 0) return;
    let cancelled = false;

    async function poll() {
      try {
        const statuses = await api.jobsForSongs(songIds);
        let anyJustFinished = false;
        for (const s of statuses) {
          if (
            (s.status === "complete" ||
              s.status === "failed" ||
              s.status === "unavailable") &&
            !completedRef.current.has(s.songId)
          ) {
            completedRef.current.add(s.songId);
            anyJustFinished = true;
          }
        }
        if (anyJustFinished && !cancelled) {
          router.refresh();
        }
      } catch {
        // Transient — try again on the next tick.
      }
    }

    void poll();
    const id = window.setInterval(() => setTick((t) => t + 1), intervalMs);
    return () => {
      cancelled = true;
      window.clearInterval(id);
    };
  }, [songIds, intervalMs, router, tick]);

  return null;
}

export const TERMINAL: ReadonlyArray<RenderStatus> = [
  "complete",
  "failed",
  "unavailable",
];

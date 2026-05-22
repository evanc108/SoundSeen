"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";

import { api } from "@/lib/api";
import { createClient } from "@/lib/supabase/client";

export function DeleteSongButton({ songId }: { songId: string }) {
  const router = useRouter();
  const [confirming, setConfirming] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function doDelete() {
    setBusy(true);
    setError(null);
    try {
      const supabase = createClient();
      const {
        data: { session },
      } = await supabase.auth.getSession();
      if (!session) {
        setError("Session expired. Sign in again.");
        setBusy(false);
        return;
      }
      await api.deleteSong(songId, session.access_token);
      router.push("/me");
      router.refresh();
    } catch (e) {
      setError((e as Error).message);
      setBusy(false);
    }
  }

  if (!confirming) {
    return (
      <button
        type="button"
        onClick={() => setConfirming(true)}
        className="tactile inline-flex h-10 w-full items-center justify-center gap-2 rounded-full border border-red-500/20 text-[13px] font-medium text-red-200/90 transition-colors hover:bg-red-500/10"
      >
        Delete
      </button>
    );
  }

  return (
    <div className="space-y-2">
      <p className="text-[12px] text-[var(--color-text-2)]">
        Delete this song, its analysis, and its rendered video? This can’t be
        undone.
      </p>
      <div className="grid grid-cols-2 gap-2">
        <button
          type="button"
          onClick={() => setConfirming(false)}
          disabled={busy}
          className="tactile h-10 rounded-full border border-[var(--color-hairline-2)] text-[13px] font-medium text-[var(--color-text)] transition-colors hover:bg-[var(--color-surface-2)] disabled:opacity-50"
        >
          Cancel
        </button>
        <button
          type="button"
          onClick={doDelete}
          disabled={busy}
          className="tactile h-10 rounded-full bg-red-500/90 text-[13px] font-medium text-white transition-colors hover:bg-red-500 disabled:opacity-50"
        >
          {busy ? "Deleting…" : "Confirm delete"}
        </button>
      </div>
      {error && (
        <p className="font-mono text-[11px] text-red-200/70">{error}</p>
      )}
    </div>
  );
}

"use client";

import { useRouter } from "next/navigation";

import { createClient } from "@/lib/supabase/client";

export function SignOutButton() {
  const router = useRouter();
  return (
    <button
      type="button"
      onClick={async () => {
        const supabase = createClient();
        await supabase.auth.signOut();
        router.push("/");
        router.refresh();
      }}
      className="tactile rounded-full px-3 py-2 text-[13px] text-[var(--color-text-3)] transition-colors hover:text-[var(--color-text)]"
    >
      Sign out
    </button>
  );
}

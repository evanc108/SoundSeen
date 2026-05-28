"use client";

import { Suspense, useState } from "react";
import { useSearchParams } from "next/navigation";

import { createClient } from "@/lib/supabase/client";

export default function SignInPage() {
  return (
    <Suspense fallback={null}>
      <SignInForm />
    </Suspense>
  );
}

function SignInForm() {
  const searchParams = useSearchParams();
  const next = searchParams.get("next") ?? "/me";

  const [email, setEmail] = useState("");
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function sendMagicLink(e: React.FormEvent) {
    e.preventDefault();
    if (!email) return;
    setBusy(true);
    setError(null);
    setStatus(null);
    const supabase = createClient();
    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: {
        emailRedirectTo: `${window.location.origin}/auth/callback?next=${encodeURIComponent(next)}`,
      },
    });
    setBusy(false);
    if (error) setError(error.message);
    else setStatus(`Check ${email} for a sign-in link.`);
  }

  return (
    <div className="mx-auto grid min-h-[78dvh] max-w-[1100px] grid-cols-1 items-center gap-16 px-8 py-16 lg:grid-cols-2">
      <div className="space-y-6">
        <p className="font-mono text-[10px] uppercase tracking-[0.28em] text-[var(--color-text-3)]">
          Sign in
        </p>
        <h1 className="text-4xl font-medium tracking-tight md:text-5xl">
          One link.
          <br />
          <span className="text-[var(--color-text-3)]">No password.</span>
        </h1>
        <p className="max-w-[42ch] text-[14px] leading-relaxed text-[var(--color-text-2)]">
          We email you a link. You click it. You&rsquo;re in. Same email every time,
          no account to create, no setup.
        </p>
      </div>

      <div className="rounded-3xl border border-[var(--color-hairline)] bg-[var(--color-surface)] p-8">
        <form onSubmit={sendMagicLink} className="space-y-5">
          <label className="block">
            <span className="block font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--color-text-3)]">
              Email
            </span>
            <input
              type="email"
              required
              autoFocus
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="your@email.com"
              className="mt-2 block w-full rounded-2xl border border-[var(--color-hairline-2)] bg-[var(--color-bg-2)] px-4 py-3 text-[14px] text-[var(--color-text)] placeholder:text-[var(--color-text-3)] outline-none transition focus:border-white/30"
            />
          </label>
          <button
            type="submit"
            disabled={busy}
            className="tactile flex h-11 w-full items-center justify-center gap-2 rounded-full bg-white text-[13px] font-medium text-black transition-opacity disabled:opacity-50"
          >
            {busy ? "Sending…" : "Send magic link"}
          </button>
        </form>

        {status && (
          <p className="mt-5 rounded-2xl border border-[var(--color-hairline-2)] bg-[var(--color-bg-2)] px-4 py-3 text-[13px] text-[var(--color-text-2)]">
            {status}
          </p>
        )}
        {error && (
          <p className="mt-5 rounded-2xl border border-red-500/20 bg-red-500/5 px-4 py-3 text-[13px] text-red-200/90">
            <span className="block font-medium text-red-200">
              Couldn&rsquo;t sign you in.
            </span>
            <span className="mt-1 block font-mono text-[11px] text-red-200/60">
              {error}
            </span>
          </p>
        )}
      </div>
    </div>
  );
}

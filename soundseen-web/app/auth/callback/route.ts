import { NextResponse, type NextRequest } from "next/server";

import { createClient } from "@/lib/supabase/server";

/** Supabase Auth redirects here after a magic-link click or OAuth round-trip.
 *  Exchange the `code` for a session, then forward to wherever the sign-in
 *  flow was originally trying to go. */
export async function GET(request: NextRequest) {
  const { searchParams, origin } = new URL(request.url);
  const code = searchParams.get("code");
  const next = searchParams.get("next") ?? "/me";

  if (code) {
    const supabase = await createClient();
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) {
      return NextResponse.redirect(`${origin}${next}`);
    }
  }

  // Fall back to the sign-in page on any failure.
  return NextResponse.redirect(`${origin}/auth/sign-in?error=callback`);
}

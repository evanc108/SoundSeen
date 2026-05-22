import { createBrowserClient } from "@supabase/ssr";

/** Browser-side Supabase client. Use from Client Components and event handlers. */
export function createClient() {
  return createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
  );
}

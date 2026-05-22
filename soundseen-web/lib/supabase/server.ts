import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";

/** Server-side Supabase client. Use from Server Components, Route Handlers,
 *  and Server Actions. Reads cookies via next/headers. */
export async function createClient() {
  const cookieStore = await cookies();
  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll();
        },
        setAll(cookiesToSet) {
          try {
            for (const { name, value, options } of cookiesToSet) {
              cookieStore.set(name, value, options);
            }
          } catch {
            // Called from a Server Component — middleware handles refresh.
          }
        },
      },
    },
  );
}

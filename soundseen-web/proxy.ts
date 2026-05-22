import { NextResponse, type NextRequest } from "next/server";
import { createServerClient } from "@supabase/ssr";

const PROTECTED_PREFIXES = ["/upload", "/me"];

export async function proxy(request: NextRequest) {
  let response = NextResponse.next({ request });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet) {
          for (const { name, value } of cookiesToSet) {
            request.cookies.set(name, value);
          }
          response = NextResponse.next({ request });
          for (const { name, value, options } of cookiesToSet) {
            response.cookies.set(name, value, options);
          }
        },
      },
    },
  );

  // Refresh the auth cookie if it's near expiry — getUser() triggers a
  // refresh side-effect on the cookie store via setAll above.
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const pathname = request.nextUrl.pathname;
  const requiresAuth = PROTECTED_PREFIXES.some((p) => pathname.startsWith(p));
  if (requiresAuth && !user) {
    const url = request.nextUrl.clone();
    url.pathname = "/auth/sign-in";
    url.searchParams.set("next", pathname);
    return NextResponse.redirect(url);
  }

  return response;
}

export const config = {
  matcher: [
    // Run on everything except static assets and Next internals.
    "/((?!_next/static|_next/image|favicon.ico|.*\\..*).*)",
  ],
};

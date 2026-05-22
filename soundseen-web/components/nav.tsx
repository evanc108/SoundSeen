import Link from "next/link";

import { createClient } from "@/lib/supabase/server";
import { SignOutButton } from "@/components/sign-out-button";

export async function Nav() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  return (
    <header className="sticky top-0 z-40 border-b border-[var(--color-hairline)] bg-[var(--color-bg)]/80 backdrop-blur-xl">
      <nav className="mx-auto flex max-w-[1400px] items-center justify-between px-8 py-4">
        <Link
          href="/"
          className="group flex items-center gap-2.5 text-[15px] font-medium tracking-tight"
        >
          <span className="block h-1.5 w-1.5 rounded-full bg-[var(--color-text)] transition-transform duration-500 group-hover:scale-150" />
          <span className="text-[var(--color-text)]">soundseen</span>
        </Link>

        <ul className="flex items-center gap-1 text-sm">
          <NavLink href="/gallery">Gallery</NavLink>
          <NavLink href="/about">About</NavLink>
          {user ? (
            <>
              <NavLink href="/me">My uploads</NavLink>
              <li className="ml-2">
                <Link
                  href="/upload"
                  className="tactile inline-flex h-9 items-center gap-2 rounded-full bg-white px-4 text-[13px] font-medium text-black transition-colors hover:bg-[var(--color-text)]"
                >
                  Upload
                  <Plus />
                </Link>
              </li>
              <li className="ml-1">
                <SignOutButton />
              </li>
            </>
          ) : (
            <li className="ml-2">
              <Link
                href="/auth/sign-in"
                className="tactile inline-flex h-9 items-center rounded-full bg-white px-4 text-[13px] font-medium text-black transition-colors hover:bg-[var(--color-text)]"
              >
                Sign in
              </Link>
            </li>
          )}
        </ul>
      </nav>
    </header>
  );
}

function NavLink({
  href,
  children,
}: {
  href: string;
  children: React.ReactNode;
}) {
  return (
    <li>
      <Link
        href={href}
        className="rounded-full px-3 py-2 text-[var(--color-text-2)] transition-colors hover:text-[var(--color-text)]"
      >
        {children}
      </Link>
    </li>
  );
}

function Plus() {
  return (
    <svg
      aria-hidden
      viewBox="0 0 14 14"
      width="11"
      height="11"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
    >
      <path d="M7 1.5v11M1.5 7h11" />
    </svg>
  );
}

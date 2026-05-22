import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";

import { Nav } from "@/components/nav";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "SoundSeen — see music",
  description:
    "Upload a song. Get a cinematic visualization back. Share it.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}
    >
      <body className="grain flex min-h-full flex-col bg-[var(--color-bg)] text-[var(--color-text)] selection:bg-white selection:text-black">
        <Nav />
        <main className="flex-1">{children}</main>
        <footer className="border-t border-[var(--color-hairline)] py-8 text-[11px] uppercase tracking-[0.2em] text-[var(--color-text-3)]">
          <div className="mx-auto flex max-w-[1400px] items-center justify-between px-8">
            <span>SoundSeen</span>
            <span className="font-mono">{new Date().getFullYear()}</span>
          </div>
        </footer>
      </body>
    </html>
  );
}

import Link from "next/link";

export const metadata = {
  title: "About · SoundSeen",
  description:
    "How a song becomes a picture. The audio-to-visual mapping used by SoundSeen, feature by feature.",
};

type Mapping = {
  feature: string;
  range: string;
  visual: string;
  why: string;
};

const PERCEPTUAL: Mapping[] = [
  {
    feature: "spectral centroid",
    range: "0 → 1",
    visual: "vertical placement, bloom intensity, godrays spread",
    why: "Marks 1989. Brighter spectra are perceived as higher in space.",
  },
  {
    feature: "harmonic ratio (HPSS)",
    range: "0 → 1",
    visual: "shape softness — rounded blooms vs. jagged shards",
    why: "Bouba/Kiki effect: tonal, sustained sounds map to curves; noisy, percussive ones to angles.",
  },
  {
    feature: "chroma strength",
    range: "0 → 1",
    visual: "color saturation lift, post-process hue rotation",
    why: "Itoh 2017. The more tonal a moment, the more saturated it feels.",
  },
  {
    feature: "RMS (loudness)",
    range: "0 → 1",
    visual: "visual mass: bloom radius, particle density, FOV push-in",
    why: "Spence 2011. Louder sounds are matched to larger, heavier visual objects.",
  },
  {
    feature: "pitch class (chroma argmax)",
    range: "0 … 11",
    visual: "vertical Y of onset particles, particle size",
    why: "Pratt 1930 + Walker 2010. Pitch height maps to elevation; higher notes also read as smaller.",
  },
  {
    feature: "MFCC[1] (spectral tilt)",
    range: "−1 → +1",
    visual: "color temperature: warm orange ↔ cool blue",
    why: "Warmer timbres correlate with low-frequency energy; mapped onto a warm/cool axis.",
  },
  {
    feature: "spectral rolloff",
    range: "0 → 1",
    visual: "particle altitude ceiling, rain ribbon aspect",
    why: "Sets the upper edge of the spectrum, so it sets the upper edge of the canvas.",
  },
  {
    feature: "zero-crossing rate",
    range: "0 → 1",
    visual: "grain opacity over the whole frame",
    why: "Sibilance and noisiness translate to visual texture.",
  },
  {
    feature: "chord centroid (chroma vector)",
    range: "X, Y in [−1, 1]",
    visual: "hue rotation",
    why: "Distance walked on the chroma circle rotates the palette through chord changes.",
  },
];

const STRUCTURAL: Mapping[] = [
  {
    feature: "beat events",
    range: "discrete",
    visual: "pulse — ring on the water plane, glow on the rain ribbon",
    why: "Sample-accurate beat tracking from librosa.beat.beat_track.",
  },
  {
    feature: "downbeat / phrase (every 4 beats)",
    range: "discrete",
    visual: "camera swoop and crane, post-FX flash",
    why: "Phrases mark the felt subdivision of a song — the visual answers with a longer breath.",
  },
  {
    feature: "onset events",
    range: "discrete + ADSR",
    visual: "particle bursts, splash on the water plane",
    why: "Each transient gets its own attack/decay envelope, sized by intensity and contrast.",
  },
  {
    feature: "drop trigger",
    range: "discrete",
    visual: "bloom boost ×2.5, chromatic aberration, lightning, camera shake",
    why: "Fires when arousal, spectral flux, and energy all clear threshold within a window.",
  },
  {
    feature: "spectral flux",
    range: "0 → 1",
    visual: "vignette darkness, rain speed, water-plane chop",
    why: "Sustained spectral change reads as tension — the visual tightens around it.",
  },
  {
    feature: "mel bands (8-band)",
    range: "0 → 1 per band",
    visual: "vertical placement of per-band sparkles (sub-bass low, ultra-high high)",
    why: "Spectrum mapped 1:1 onto the Y axis. The bass lives at the floor; air lives at the ceiling.",
  },
];

const BIOMES: Array<{
  name: string;
  v: string;
  a: string;
  signature: string;
}> = [
  {
    name: "Melancholic Rain",
    v: "low valence",
    a: "low arousal",
    signature: "puddled horizon, falling rain ribbons, distant skyline",
  },
  {
    name: "Serene Dawn",
    v: "high valence",
    a: "low arousal",
    signature: "wide sun disk, slow cloud bands, warm hills",
  },
  {
    name: "Euphoric Bloom",
    v: "high valence",
    a: "high arousal",
    signature: "radial particle bloom, curl-noise drift, magenta accents",
  },
  {
    name: "Intense Storm",
    v: "low valence",
    a: "high arousal",
    signature: "lightning fired on downbeats, red onset accents, vertical chaos",
  },
];

const CITATIONS: Array<{ author: string; topic: string }> = [
  { author: "Marks, 1989", topic: "Loudness → brightness; brightness → height" },
  {
    author: "Köhler / Ramachandran & Hubbard (Bouba/Kiki)",
    topic: "Tonal vs. noisy sound → round vs. jagged shape",
  },
  { author: "Spence, 2011", topic: "Loudness → visual mass" },
  { author: "Pratt, 1930", topic: "Pitch height → vertical position" },
  { author: "Walker, 2010", topic: "Higher pitch → smaller object" },
  {
    author: "Schloss & Palmer, 2011",
    topic: "Music-to-color associations; emotion-mediated hue",
  },
  { author: "Russell, 1980", topic: "Valence/arousal circumplex of emotion" },
  {
    author: "Valdez & Mehrabian, 1994",
    topic: "Saturation and brightness drive emotional response",
  },
  {
    author: "Krumhansl & Kessler, 1982",
    topic: "Chroma correlation → major/minor mode",
  },
  { author: "Itoh, 2017", topic: "Tonal clarity → perceived saturation" },
];

export default function AboutPage() {
  return (
    <div className="mx-auto max-w-[1200px] px-8 py-16 lg:py-24">
      <header className="border-b border-[var(--color-hairline)] pb-12">
        <p className="font-mono text-[10px] uppercase tracking-[0.28em] text-[var(--color-text-3)]">
          How a song becomes a picture
        </p>
        <h1 className="mt-4 text-balance text-[44px] font-medium leading-[1.04] tracking-tight md:text-[60px]">
          Every pixel
          <br />
          comes from a number.
        </h1>
        <p className="mt-6 max-w-[58ch] text-[15px] leading-relaxed text-[var(--color-text-2)]">
          SoundSeen doesn&rsquo;t guess. Each visual decision — color, shape,
          motion, position — is the output of an audio feature pulled from{" "}
          <Mono>librosa</Mono>, paired with a perceptual finding from the
          psychophysics literature. This page is the legend.
        </p>
      </header>

      <PipelineDiagram />

      <Section
        eyebrow="01 · Perceptual mappings"
        title="Continuous audio features → continuous visual axes."
        lede="These run per-frame at 10 Hz and get interpolated for every rendered frame. Each row is one knob the audio is allowed to turn."
      >
        <MappingTable rows={PERCEPTUAL} />
      </Section>

      <Section
        eyebrow="02 · Structural events"
        title="Beats, drops, and phrases as discrete impulses."
        lede="These are the things you feel in your chest. They&rsquo;re modeled as events with envelopes — attack, decay, sustain — not as smooth signals."
      >
        <MappingTable rows={STRUCTURAL} />
      </Section>

      <Section
        eyebrow="03 · Mood routing"
        title="Where in the song you are determines what world you&rsquo;re in."
        lede="Valence and arousal land each section in a quadrant. The renderer picks one of four scenes accordingly, then crossfades through transitions."
      >
        <BiomeGrid />
      </Section>

      <Section
        eyebrow="04 · Research anchors"
        title="The mappings aren&rsquo;t arbitrary."
        lede="Every choice in the tables above is grounded in published work on cross-modal perception. The short list:"
      >
        <Citations rows={CITATIONS} />
      </Section>

      <section className="mt-24 border-t border-[var(--color-hairline)] pt-12">
        <div className="flex flex-col items-start justify-between gap-6 md:flex-row md:items-end">
          <p className="max-w-[52ch] text-[15px] leading-relaxed text-[var(--color-text-2)]">
            Curious to see it work? Upload a song or browse what other people
            have rendered. The same mappings drive everything in the gallery.
          </p>
          <div className="flex items-center gap-2.5">
            <Link
              href="/upload"
              className="tactile inline-flex h-11 items-center gap-2 rounded-full bg-white px-5 text-[13px] font-medium text-black"
            >
              Upload a song
              <Arrow />
            </Link>
            <Link
              href="/gallery"
              className="tactile inline-flex h-11 items-center rounded-full border border-[var(--color-hairline-2)] px-5 text-[13px] font-medium text-[var(--color-text)] hover:bg-[var(--color-surface)]"
            >
              Browse gallery
            </Link>
          </div>
        </div>
      </section>
    </div>
  );
}

function Section({
  eyebrow,
  title,
  lede,
  children,
}: {
  eyebrow: string;
  title: string;
  lede: string;
  children: React.ReactNode;
}) {
  return (
    <section className="mt-24 grid grid-cols-12 gap-10">
      <div className="col-span-12 lg:col-span-4">
        <p className="font-mono text-[10px] uppercase tracking-[0.28em] text-[var(--color-text-3)]">
          {eyebrow}
        </p>
        <h2 className="mt-4 text-balance text-[26px] font-medium leading-[1.2] tracking-tight md:text-[32px]">
          {title}
        </h2>
        <p className="mt-4 max-w-[44ch] text-[14px] leading-relaxed text-[var(--color-text-2)]">
          {lede}
        </p>
      </div>
      <div className="col-span-12 lg:col-span-8">{children}</div>
    </section>
  );
}

function MappingTable({ rows }: { rows: Mapping[] }) {
  return (
    <div className="overflow-hidden rounded-2xl border border-[var(--color-hairline)]">
      <div className="hidden grid-cols-12 gap-4 border-b border-[var(--color-hairline)] bg-[var(--color-bg-2)] px-5 py-3 font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--color-text-3)] md:grid">
        <div className="col-span-3">Feature</div>
        <div className="col-span-1">Range</div>
        <div className="col-span-4">Visual</div>
        <div className="col-span-4">Why</div>
      </div>
      <ul className="divide-y divide-[var(--color-hairline)]">
        {rows.map((row) => (
          <li
            key={row.feature}
            className="grid grid-cols-12 gap-x-4 gap-y-3 px-5 py-5 transition-colors hover:bg-[var(--color-bg-2)]/60"
          >
            <div className="col-span-12 md:col-span-3">
              <span className="text-[13.5px] font-medium tracking-tight text-[var(--color-text)]">
                {row.feature}
              </span>
            </div>
            <div className="col-span-6 md:col-span-1">
              <span className="font-mono text-[11px] text-[var(--color-text-3)]">
                {row.range}
              </span>
            </div>
            <div className="col-span-12 md:col-span-4">
              <span className="text-[13.5px] text-[var(--color-text-2)]">
                {row.visual}
              </span>
            </div>
            <div className="col-span-12 md:col-span-4">
              <span className="text-[13px] leading-relaxed text-[var(--color-text-3)]">
                {row.why}
              </span>
            </div>
          </li>
        ))}
      </ul>
    </div>
  );
}

function BiomeGrid() {
  return (
    <div className="grid grid-cols-1 gap-px overflow-hidden rounded-2xl bg-[var(--color-hairline)] sm:grid-cols-2">
      {BIOMES.map((b, i) => (
        <div
          key={b.name}
          className="flex min-h-[200px] flex-col justify-between bg-[var(--color-bg)] p-6"
        >
          <div className="flex items-center justify-between">
            <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--color-text-3)]">
              Quadrant {String(i + 1).padStart(2, "0")}
            </p>
            <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--color-text-3)]">
              {b.v} · {b.a}
            </p>
          </div>
          <div className="space-y-2">
            <h3 className="text-[22px] font-medium leading-tight tracking-tight text-[var(--color-text)]">
              {b.name}
            </h3>
            <p className="text-[13px] leading-relaxed text-[var(--color-text-2)]">
              {b.signature}
            </p>
          </div>
        </div>
      ))}
    </div>
  );
}

function Citations({ rows }: { rows: Array<{ author: string; topic: string }> }) {
  return (
    <ol className="space-y-px overflow-hidden rounded-2xl bg-[var(--color-hairline)]">
      {rows.map((r) => (
        <li
          key={r.author}
          className="flex flex-col gap-1 bg-[var(--color-bg)] px-5 py-4 sm:flex-row sm:items-baseline sm:gap-6"
        >
          <span className="w-64 shrink-0 text-[13.5px] font-medium tracking-tight text-[var(--color-text)]">
            {r.author}
          </span>
          <span className="text-[13px] leading-relaxed text-[var(--color-text-2)]">
            {r.topic}
          </span>
        </li>
      ))}
    </ol>
  );
}

function PipelineDiagram() {
  const stages = [
    { label: "Audio", body: "mp3, wav, or m4a" },
    { label: "librosa", body: "rms, centroid, chroma, mel, onsets, beats, HPSS" },
    { label: "Composition", body: "frames @ 10 Hz, section script, event tracks" },
    { label: "Renderer", body: "GPU shaders + post-FX, one frame at a time" },
    { label: "Video", body: "MP4 with the original audio muxed in" },
  ];
  return (
    <section className="mt-16">
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-5">
        {stages.map((s, i) => (
          <div
            key={s.label}
            className="relative flex flex-col gap-3 rounded-2xl border border-[var(--color-hairline)] bg-[var(--color-surface)] px-4 py-5"
          >
            <span className="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--color-text-3)]">
              {String(i + 1).padStart(2, "0")}
            </span>
            <span className="text-[14px] font-medium tracking-tight text-[var(--color-text)]">
              {s.label}
            </span>
            <span className="text-[12px] leading-relaxed text-[var(--color-text-2)]">
              {s.body}
            </span>
          </div>
        ))}
      </div>
    </section>
  );
}

function Mono({ children }: { children: React.ReactNode }) {
  return (
    <span className="rounded-md bg-[var(--color-surface)] px-1.5 py-0.5 font-mono text-[12.5px] text-[var(--color-text)]">
      {children}
    </span>
  );
}

function Arrow() {
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
      strokeLinejoin="round"
    >
      <path d="M2.5 7h9M7 2.5L11.5 7 7 11.5" />
    </svg>
  );
}

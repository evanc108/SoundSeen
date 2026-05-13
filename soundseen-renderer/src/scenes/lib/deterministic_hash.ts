// Deterministic hash helpers — replace Math.random() in scene code so
// render re-seek (scrubbing through the same t) is reproducible and
// per-band spawning doesn't flicker frame-by-frame at identical inputs.
//
// All three follow the classic `fract(sin(x) * 43758.5453)` pattern.
// Output is in [0, 1). Cheap on CPU; phase-uncorrelated enough that
// using hash1/hash2/hash3 for different axes of jitter produces visually
// independent streams without obvious patterns.

export function hash1(t: number): number {
  const x = Math.sin(t * 12.9898) * 43758.5453;
  return x - Math.floor(x);
}

export function hash2(t: number, k: number): number {
  const x = Math.sin(t * 12.9898 + k * 78.233) * 43758.5453;
  return x - Math.floor(x);
}

export function hash3(t: number, k: number, b: number): number {
  const x =
    Math.sin(t * 12.9898 + k * 78.233 + b * 37.719) * 43758.5453;
  return x - Math.floor(x);
}

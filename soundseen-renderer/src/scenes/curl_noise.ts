// Deterministic 2D curl-noise — divergence-free velocity field for
// particle drift. Replaces sin-based per-particle motion that visually
// loops; curl noise gives organic flow that reads as "alive."
//
// Uses sin-hash value noise (same pattern as bolt rand in
// intense_storm.ts) so renders remain bit-identical across runs.

function hash2(x: number, y: number): number {
  const h = Math.sin(x * 12.9898 + y * 78.233) * 43758.5453;
  return h - Math.floor(h);
}

function valueNoise2(x: number, y: number): number {
  const ix = Math.floor(x);
  const iy = Math.floor(y);
  const fx = x - ix;
  const fy = y - iy;
  const ux = fx * fx * (3 - 2 * fx);
  const uy = fy * fy * (3 - 2 * fy);
  const a = hash2(ix, iy);
  const b = hash2(ix + 1, iy);
  const c = hash2(ix, iy + 1);
  const d = hash2(ix + 1, iy + 1);
  return (a * (1 - ux) + b * ux) * (1 - uy) + (c * (1 - ux) + d * ux) * uy;
}

// Returns a 2-vector (vx, vy) describing the curl of a scalar noise field
// at (x, y). The field's divergence is zero, so the resulting flow
// doesn't bunch particles into sinks. eps controls how fine the curl is
// (smaller = more turbulent).
export function curlNoise2(x: number, y: number, eps = 0.10): [number, number] {
  const n1 = valueNoise2(x, y + eps);
  const n2 = valueNoise2(x, y - eps);
  const n3 = valueNoise2(x + eps, y);
  const n4 = valueNoise2(x - eps, y);
  return [(n1 - n2) / (2 * eps), -(n3 - n4) / (2 * eps)];
}

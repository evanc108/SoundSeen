// Cinematic camera deltas — biome-agnostic camera modulation that
// scenes layer on top of their own base camera transforms. Each scene
// computes its base position/lookAt, then applies these deltas, then
// calls lookAt + updateProjectionMatrix.
//
// Levers (each subtle alone, restless together):
//   - sub_bass / low_bass band: gentle XY sway tied to the low-freq throb
//   - buildIntensity:            Z push-in toward the subject at climaxes
//   - phrasePulse:               Z swoop + Y crane lift + X sweep
//   - dropImpulse:               brief XY shake (hash-driven jitter)
//   - tension:                   small Z roll
//
// Each scene can scale the returned values via the multiplier param;
// e.g. Serene Dawn wants gentler moves than Intense Storm.

import * as THREE from "three";
import type { FrameContext } from "../../types.js";
import { hash1 } from "./deterministic_hash.js";

export interface CinematicMultipliers {
  /// Multiplier on the bass-band XY sway. Default 1.0.
  sway?: number;
  /// Multiplier on the build-driven Z push-in. Default 1.0.
  push?: number;
  /// Multiplier on phrase-pulse moves (Y crane, Z swoop, X sweep). Default 1.0.
  phrase?: number;
  /// Multiplier on drop-driven shake amplitude. Default 1.0.
  shake?: number;
  /// Multiplier on tension-driven roll. Default 1.0.
  roll?: number;
}

export interface CinematicDeltas {
  posDelta: THREE.Vector3;
  rollZ: number;
}

export function cinematicCameraDeltas(
  ctx: FrameContext,
  mult: CinematicMultipliers = {},
): CinematicDeltas {
  const swayMult = mult.sway ?? 1.0;
  const pushMult = mult.push ?? 1.0;
  const phraseMult = mult.phrase ?? 1.0;
  const shakeMult = mult.shake ?? 1.0;
  const rollMult = mult.roll ?? 1.0;

  const bands = ctx.audio.melBands;
  const subBass = bands[0] ?? 0;
  const lowBass = bands[1] ?? 0;

  const swayPhase = ctx.t * 0.6;
  const swayX = Math.sin(swayPhase) * subBass * 0.18 * swayMult;
  const swayY = Math.cos(swayPhase * 0.7) * lowBass * 0.10 * swayMult;

  const pushIn = ctx.buildIntensity * 1.4 * pushMult;
  const phraseSwoop = ctx.phrasePulse * 0.6 * phraseMult;
  const craneLift = ctx.phrasePulse * 0.25 * phraseMult;
  const phraseSweep =
    Math.sin(ctx.t * 1.5) * ctx.phrasePulse * 0.25 * phraseMult;

  const shakeX =
    (hash1(ctx.t * 60) - 0.5) * ctx.dropImpulse * 0.12 * shakeMult +
    (hash1(ctx.t * 50 + 11) - 0.5) * ctx.phrasePulse * 0.05 * shakeMult;
  const shakeY =
    (hash1(ctx.t * 60 + 7.3) - 0.5) * ctx.dropImpulse * 0.12 * shakeMult +
    (hash1(ctx.t * 50 + 23) - 0.5) * ctx.phrasePulse * 0.05 * shakeMult;

  const tension = ctx.section?.tension ?? 0.4;
  const rollZ =
    ((tension - 0.4) * 0.05 + ctx.phrasePulse * 0.03) * rollMult;

  return {
    posDelta: new THREE.Vector3(
      swayX + shakeX + phraseSweep,
      swayY + craneLift + shakeY,
      -(pushIn + phraseSwoop),
    ),
    rollZ,
  };
}

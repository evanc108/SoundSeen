//
//  FrostTexture.swift
//  SoundSeen
//
//  Crystalline specks in the SKY zone. Round 2: recycled pool of 36
//  specks (not 80 fixed). Each speck has its own birth and lifetime
//  (~4s, jittered) so the shimmer is *new sparkle every moment* — a
//  cymbal shimmer isn't the same crystal every frame.
//
//  Position v is spectral-brightness-skewed: high centroid → specks
//  float closer to the top of SKY. Hue lerps from a desaturated accent
//  toward the song's chromatic key when chroma strength is high, so an
//  ultra-high in a tonal passage picks up the key tint; in a noisy wash
//  it stays near-white.
//
//  Alpha cap is halved outside chorus/drop to de-emphasize the sparkle
//  layer that was previously dominating the frame.
//

import SwiftUI

private let frostSeedCount: Int = 36
private let frostLifetimeBase: Double = 4.0

struct FrostTexture: View {
    @Bindable var state: VisualizerState
    let scheme: EmotionScheme
    let dialect: SectionDialect
    let now: Date

    @State private var specks: [FrostSpeck] = []
    @State private var didSeed: Bool = false

    var body: some View {
        if dialect.enabledTextures.contains(.frost) {
            Canvas { ctx, size in
                let ultra = (state.currentBands.count > 7 ? state.currentBands[7] : 0) * dialect.bandMask[7]
                let t = now.timeIntervalSinceReferenceDate

                // Refresh any dead specks to new positions before drawing.
                recycle(at: t)

                guard ultra > 0.04 else { return }

                // Hue: cold accent base, pulled toward key when tonal.
                let cs = state.currentChromaStrength
                let keyHSB = HSB(h: state.currentHue, s: 0.25, b: 1.0)
                let coldBase = HSB(
                    h: scheme.accent.h,
                    s: scheme.accent.s * 0.15,
                    b: min(1.0, scheme.accent.b * 1.2)
                )
                let tint = blendHSB(coldBase, keyHSB, min(1.0, cs * 0.6))
                // Saturation climbs with B[7] so louder trebles picks up colour.
                let satBoost = 0.05 + 0.30 * ultra
                let color = HSB(h: tint.h, s: max(tint.s, satBoost), b: tint.b)

                // Alpha cap: lower outside chorus/drop to tame the sparkle.
                let isShowy = dialect.mirrorX || dialect.allowOffscreen
                let alphaCap = isShowy ? 0.80 : 0.55

                for speck in specks {
                    let age = t - speck.birth
                    let norm = age / speck.life
                    guard norm < 1 else { continue }

                    // Alpha envelope per speck — soft rise + soft fall so
                    // recycled positions don't pop in.
                    let env = sin(norm * .pi)  // 0 → 1 → 0 across lifetime
                    let emphasis = speck.bright ? 1.0 : 0.45
                    let rawAlpha = (0.20 + 0.70 * ultra) * emphasis * env
                    let alpha = min(alphaCap, rawAlpha)

                    let radius = (0.7 + ultra * 2.4 * emphasis) * env

                    let x = speck.u * size.width
                    let y = speck.v * size.height
                    let rect = CGRect(x: x - radius, y: y - radius,
                                      width: radius * 2, height: radius * 2)
                    ctx.fill(
                        Path(ellipseIn: rect),
                        with: .color(color.color(opacity: alpha))
                    )
                }
            }
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Pool management

    /// Spawn or replace dead specks so we always have `frostSeedCount`
    /// active positions. Respawn position is centroid-aware: bright
    /// spectrum → specks spawn near the top of SKY; darker spectrum →
    /// they sit closer to the horizon.
    private func recycle(at t: Double) {
        // Seed the pool on first frame.
        if !didSeed {
            specks.reserveCapacity(frostSeedCount)
            for _ in 0..<frostSeedCount {
                specks.append(randomSpeck(at: t, startAged: true))
            }
            didSeed = true
            return
        }
        for i in 0..<specks.count where t - specks[i].birth >= specks[i].life {
            specks[i] = randomSpeck(at: t, startAged: false)
        }
    }

    private func randomSpeck(at t: Double, startAged: Bool) -> FrostSpeck {
        let cn = state.currentCentroidNormalized
        let vLo = max(dialect.activeVBounds.lowerBound, 0.03)
        let vHi = min(dialect.activeVBounds.upperBound, 0.30)

        // Brighter spectrum → higher in SKY (smaller v).
        let vCentered = 0.05 + 0.25 * (1.0 - cn)
        let vJitter = Double.random(in: -0.06...0.06)
        let v = max(vLo, min(vHi, vCentered + vJitter))

        let uLo = dialect.activeUBounds.lowerBound
        let uHi = dialect.activeUBounds.upperBound
        let u = Double.random(in: uLo...uHi)

        // Life jittered ±30% of the base so specks don't all respawn on
        // the same frame.
        let life = frostLifetimeBase * Double.random(in: 0.7...1.3)

        // When seeding initially, stagger births so the pool isn't all
        // peaking at once (which would create a visible puffing pattern).
        let birth = startAged
            ? t - Double.random(in: 0...life)
            : t

        let bright = Double.random(in: 0...1) > 0.80

        return FrostSpeck(u: u, v: v, birth: birth, life: life, bright: bright)
    }

    // MARK: - Helpers

    private struct FrostSpeck {
        let u: Double
        let v: Double
        let birth: Double
        let life: Double
        /// ~20% of specks are "bright" — anchor points of the shimmer.
        let bright: Bool
    }

    private func blendHSB(_ a: HSB, _ b: HSB, _ t: Double) -> HSB {
        var dh = b.h - a.h
        if dh > 0.5 { dh -= 1 }
        if dh < -0.5 { dh += 1 }
        var h = a.h + dh * t
        h = h.truncatingRemainder(dividingBy: 1); if h < 0 { h += 1 }
        return HSB(
            h: h,
            s: a.s + (b.s - a.s) * t,
            b: a.b + (b.b - a.b) * t
        )
    }
}

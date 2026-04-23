//
//  SubBassRippleTexture.swift
//  SoundSeen
//
//  Dedicated primitive for the sub-bass band (bands[0]). Sub-bass is a
//  physical pressure wave — an expanding ring is the most literal
//  possible metaphor, and the frequency band deaf users most want to
//  "see" because it drives the music's physical impact.
//
//  Two emitters in the FLOOR corners (bottom-left + bottom-right) each
//  spawn concentric rings while bands[0] is above a threshold. Rings
//  expand slowly (2–4s lifetime), heavily blurred. Max 2–4 rings on
//  screen per emitter so the scene doesn't clutter.
//

import SwiftUI

private let maxRingsPerEmitter: Int = 4
private let ringLifetime: Double = 3.0

struct SubBassRippleTexture: View {
    @Bindable var state: VisualizerState
    let scheme: EmotionScheme
    let dialect: SectionDialect
    let now: Date

    @State private var leftRings: [Ring] = []
    @State private var rightRings: [Ring] = []
    @State private var lastEmitLeft: Double = -.infinity
    @State private var lastEmitRight: Double = -.infinity

    var body: some View {
        if dialect.enabledTextures.contains(.subBassRipple) {
            Canvas { ctx, size in
                let sub = (state.currentBands.first ?? 0) * dialect.bandMask[0]
                let t = now.timeIntervalSinceReferenceDate

                maybeEmit(at: t, sub: sub)
                reap(at: t)

                // Emitter positions breathe slightly so rings don't all
                // spawn at exactly the same pixel.
                let breathL = CGPoint(
                    x: size.width * (0.08 + 0.02 * sin(t * 0.3)),
                    y: size.height * (0.88 - 0.02 * sin(t * 0.3))
                )
                let breathR = CGPoint(
                    x: size.width * (0.92 - 0.02 * sin(t * 0.3 + .pi / 2)),
                    y: size.height * (0.88 - 0.02 * sin(t * 0.3 + .pi / 2))
                )

                drawRings(ctx: &ctx, origin: breathL, rings: leftRings,
                          t: t, size: size, sub: sub)
                drawRings(ctx: &ctx, origin: breathR, rings: rightRings,
                          t: t, size: size, sub: sub)
            }
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        }
    }

    private func maybeEmit(at t: Double, sub: Double) {
        guard sub > 0.15 else { return }
        // Inter-ring interval compresses with sub-bass energy.
        let interval = 1.2 - 0.6 * sub
        if t - lastEmitLeft >= interval, leftRings.count < maxRingsPerEmitter {
            leftRings.append(Ring(birth: t, intensity: sub))
            lastEmitLeft = t
        }
        if t - lastEmitRight >= interval * 0.95, rightRings.count < maxRingsPerEmitter {
            // Right emitter offset slightly so the two sides don't lockstep.
            rightRings.append(Ring(birth: t, intensity: sub))
            lastEmitRight = t
        }
    }

    private func reap(at t: Double) {
        leftRings.removeAll { t - $0.birth >= ringLifetime }
        rightRings.removeAll { t - $0.birth >= ringLifetime }
    }

    private func drawRings(
        ctx: inout GraphicsContext,
        origin: CGPoint,
        rings: [Ring],
        t: Double,
        size: CGSize,
        sub: Double
    ) {
        let minDim = min(size.width, size.height)
        // Ring color: atmosphere blended toward primary by sub-bass energy.
        let color = blend2(scheme.atmosphere, scheme.primary, min(1.0, sub))

        for ring in rings {
            let age = t - ring.birth
            guard age >= 0, age < ringLifetime else { continue }
            let norm = age / ringLifetime

            let radius = minDim * CGFloat(0.10 + 1.0 * norm)
            // Alpha envelope: fade in over first 15%, fade out over rest.
            let env: Double
            if norm < 0.15 {
                env = norm / 0.15
            } else {
                env = 1 - (norm - 0.15) / 0.85
            }
            let alpha = (0.08 + 0.14 * ring.intensity) * env

            // Ring thickness = annulus: draw outer ellipse then punch inner.
            var ringCtx = ctx
            ringCtx.addFilter(.blur(radius: 36))

            let outerRect = CGRect(
                x: origin.x - radius, y: origin.y - radius,
                width: radius * 2, height: radius * 2
            )
            // Stroked ring for a clean wave shape.
            let strokeWidth: CGFloat = max(4, radius * 0.06)
            ringCtx.stroke(
                Path(ellipseIn: outerRect),
                with: .color(color.color(opacity: alpha)),
                lineWidth: strokeWidth
            )
        }
    }

    private struct Ring {
        let birth: Double
        let intensity: Double
    }

    private func blend2(_ a: HSB, _ b: HSB, _ t: Double) -> HSB {
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

//
//  GlowPulseTexture.swift
//  SoundSeen
//
//  Beat-driven luminance flash. Round 2:
//  - Gate threshold raised to 0.35 — faint beats don't visually
//    punctuate, so they shouldn't pulse.
//  - Center drifts slowly through CORE so the same hole isn't punched
//    on every beat.
//  - Downbeat ripple picks up the song's key tint when tonal, making
//    the emphasis feel specific to the piece.
//  - Peak alpha reduced 30% to rebalance the sparkle dominance problem.
//

import SwiftUI

struct GlowPulseTexture: View {
    @Bindable var state: VisualizerState
    let scheme: EmotionScheme
    let dialect: SectionDialect
    let now: Date

    var body: some View {
        if dialect.enabledTextures.contains(.glowPulse) {
            GeometryReader { geo in
                let pulse = state.beatPulse
                if pulse > 0.35 {
                    let isHeavy = pulse > 0.85
                    let size = geo.size
                    let minDim = min(size.width, size.height)
                    let t = now.timeIntervalSinceReferenceDate

                    // Drift through CORE so the pulse isn't a stationary hole.
                    let driftU = dialect.compositionOrigin.x + 0.08 * sin(t * 0.1)
                    let driftV = dialect.compositionOrigin.y + 0.08 * cos(t * 0.07)
                    let origin = CGPoint(
                        x: size.width * driftU,
                        y: size.height * driftV
                    )

                    // Round-2 peak alpha: core 0.15 (was 0.22).
                    let coreAlpha = 0.15 * pulse
                    let radius = minDim * (isHeavy ? 0.55 : 0.30) * pulse

                    Ellipse()
                        .fill(
                            RadialGradient(
                                gradient: Gradient(colors: [
                                    scheme.primary.color(opacity: coreAlpha),
                                    scheme.primary.color(opacity: 0)
                                ]),
                                center: .center,
                                startRadius: 0,
                                endRadius: radius
                            )
                        )
                        .frame(width: radius * 2, height: radius * 2)
                        .position(origin)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)

                    if isHeavy {
                        // Downbeat ripple — accent blended toward key when tonal.
                        let cs = state.currentChromaStrength
                        let keyHSB = HSB(h: state.currentHue, s: 0.85, b: 1.0)
                        let rippleColor = blend2(scheme.accent, keyHSB, min(1.0, cs * 0.5))
                        let rippleAlpha = 0.07 * pulse
                        let rippleR = minDim * 0.95 * pulse
                        Ellipse()
                            .fill(
                                RadialGradient(
                                    gradient: Gradient(stops: [
                                        .init(color: rippleColor.color(opacity: 0), location: 0.0),
                                        .init(color: rippleColor.color(opacity: rippleAlpha), location: 0.75),
                                        .init(color: rippleColor.color(opacity: 0), location: 1.0)
                                    ]),
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: rippleR
                                )
                            )
                            .frame(width: rippleR * 2, height: rippleR * 2)
                            .position(origin)
                            .blur(radius: 12)
                            .blendMode(.plusLighter)
                            .allowsHitTesting(false)
                    }
                }
            }
            .allowsHitTesting(false)
        }
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

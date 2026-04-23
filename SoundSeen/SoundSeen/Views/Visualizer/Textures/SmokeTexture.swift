//
//  SmokeTexture.swift
//  SoundSeen
//
//  Volumetric bass — layered blurred ellipses drifting slowly upward.
//  Edge-less, soft, mass-without-silhouette. Owns FLOOR plus a gentle
//  reach into MIDBODY when bass is loud.
//
//  Round 2 changes:
//  - Drops sub-bass (B[0]) — SubBassRipple owns that band. Smoke now
//    reads B[1]+B[2] for bass-body only.
//  - Upper two layers' vertical position rises with bass energy: when
//    bass intensifies, the mass lifts off the floor, making the listener
//    feel the pressure climb.
//  - Horizontal sway driven by (1 − HR): noisy passages slosh laterally,
//    harmonic ones sit still. Noise = motion; harmony = stasis.
//  - Hue pulls toward the song's chromatic key when chroma strength is
//    high, and brightness lifts with bass so the floor *glows with the
//    music*.
//

import SwiftUI

struct SmokeTexture: View {
    @Bindable var state: VisualizerState
    let scheme: EmotionScheme
    let dialect: SectionDialect
    let now: Date

    var body: some View {
        if dialect.enabledTextures.contains(.smoke) {
            Canvas { ctx, size in
                let bands = state.currentBands
                let bass = (bands.count > 1 ? bands[1] : 0) * dialect.bandMask[1]
                let lowMid = (bands.count > 2 ? bands[2] : 0) * dialect.bandMask[2]
                let mass = min(1.0, bass + lowMid * 0.5)
                guard mass > 0.04 else { return }

                // Base hue: atmosphere, pulled toward key on tonal passages.
                let cs = state.currentChromaStrength
                let keyHSB = HSB(h: state.currentHue, s: 0.55, b: 0.85)
                let atmo = blend2(scheme.atmosphere, keyHSB, min(1.0, cs * 0.4))
                let tint = scheme.primary

                let t = now.timeIntervalSinceReferenceDate
                let pitchBias = -state.currentPitchDirection * 0.3
                let driftSpeed = 0.12 + 0.08 * mass + pitchBias

                let harm = state.currentHarmonicRatio
                // Lateral slosh amplitude — wider when noisy.
                let swayAmp = 0.15 * (1 - harm)

                let uLo = dialect.activeUBounds.lowerBound
                let uHi = dialect.activeUBounds.upperBound
                let floorCenter = 0.88 * size.height

                let layers = 4
                for layer in 0..<layers {
                    let layerT = t * driftSpeed + Double(layer) * 0.7

                    // Upper-two layers rise with bass. Bottom-two stay anchored
                    // at the floor so there's always a grounded mass.
                    let riseLift: CGFloat = (layer >= 2)
                        ? CGFloat(bass * 0.08) * size.height
                        : 0

                    let spanW = size.width * (0.55 + Double(layer) * 0.18)
                    let span = CGRect(
                        x: CGFloat(uLo) * size.width - spanW * 0.15,
                        y: floorCenter - CGFloat(layer) * 26 - CGFloat(mass) * 80 - riseLift,
                        width: min(spanW, CGFloat(uHi - uLo) * size.width * 1.25),
                        height: 120 + CGFloat(layer) * 30 + CGFloat(mass) * 70
                    )

                    // HR-gated lateral slosh, layered onto the existing parallax
                    // drift so noisy mids *add* turbulence to the motion.
                    let slosh = sin(t * 0.3 + Double(layer)) * swayAmp
                    let phase1 = sin(layerT * 0.8 + Double(layer)) * 40 + slosh * 100
                    let phase2 = cos(layerT * 0.6 + Double(layer) * 1.4) * 40 - slosh * 100
                    let rectA = span.offsetBy(dx: CGFloat(phase1), dy: CGFloat(sin(layerT) * 6))
                    let rectB = span.offsetBy(dx: CGFloat(phase2), dy: CGFloat(cos(layerT) * 6))

                    // Deeper layers skew toward primary tint when bass is present.
                    let tintWeight = 0.25 * Double(layer) / Double(layers - 1) * mass
                    let blended = HSB(
                        h: atmo.h * (1 - tintWeight) + tint.h * tintWeight,
                        s: atmo.s,
                        b: min(1.0, atmo.b * (1.0 + 0.25 * bass))
                    )
                    let layerOpacity = 0.12 + 0.28 * mass * (1.0 - Double(layer) * 0.12)

                    var layerCtx = ctx
                    layerCtx.addFilter(.blur(radius: 38 + CGFloat(layer) * 18))
                    layerCtx.fill(Path(ellipseIn: rectA), with: .color(blended.color(opacity: layerOpacity)))
                    layerCtx.fill(Path(ellipseIn: rectB), with: .color(blended.color(opacity: layerOpacity * 0.8)))
                }
            }
            .blendMode(.plusLighter)
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

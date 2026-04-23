//
//  VelvetDarknessTexture.swift
//  SoundSeen
//
//  Matte black veil that deepens the scene. Two components:
//
//    1. Radial vignette darkening the edges (always on when this texture
//       is enabled).
//    2. Slow-breathing low-frequency glow at FLOOR center. Round 2: the
//       breath rate scales with arousal — darkness breathes faster when
//       the song's energy is up — and the FLOOR glow picks up the song's
//       key tint when chroma strength is high.
//

import SwiftUI

struct VelvetDarknessTexture: View {
    @Bindable var state: VisualizerState
    let scheme: EmotionScheme
    let dialect: SectionDialect
    let now: Date

    var body: some View {
        if dialect.enabledTextures.contains(.velvetDarkness) {
            GeometryReader { geo in
                ZStack {
                    vignette(size: geo.size)
                    floorBreath(size: geo.size)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func vignette(size: CGSize) -> some View {
        let maxR = max(size.width, size.height) * 0.9
        return RadialGradient(
            gradient: Gradient(stops: [
                .init(color: .black.opacity(0.0), location: 0.0),
                .init(color: .black.opacity(0.35), location: 0.7),
                .init(color: .black.opacity(0.75), location: 1.0)
            ]),
            center: .center,
            startRadius: size.width * 0.1,
            endRadius: maxR
        )
        .blendMode(.multiply)
    }

    private func floorBreath(size: CGSize) -> some View {
        let subBass = (state.currentBands.first ?? 0) * dialect.bandMask[0]
        let t = now.timeIntervalSinceReferenceDate

        // Arousal-scaled breath: 0.4 Hz when calm, 0.9 Hz at peak.
        let breathHz = 0.4 + state.smoothedArousal * 0.5
        let breath = 0.5 + 0.5 * sin(t * 2 * .pi * breathHz)
        let intensity = max(subBass, breath * 0.25)

        // Even the dark carries the key residue when tonal.
        let cs = state.currentChromaStrength
        let keyHSB = HSB(h: state.currentHue, s: 0.6, b: 0.9)
        let glow = blend2(scheme.atmosphere, keyHSB, min(1.0, cs * 0.3))

        let diameter = size.height * CGFloat(0.45 + 0.25 * intensity)
        let cy = size.height * 0.88

        return Ellipse()
            .fill(
                RadialGradient(
                    gradient: Gradient(colors: [
                        glow.color(opacity: 0.6 * intensity),
                        glow.color(opacity: 0)
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter / 2
                )
            )
            .frame(width: diameter * 1.6, height: diameter)
            .position(x: size.width / 2, y: cy)
            .blur(radius: 28)
            .blendMode(.plusLighter)
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

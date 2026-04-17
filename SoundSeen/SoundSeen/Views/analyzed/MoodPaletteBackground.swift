//
//  MoodPaletteBackground.swift
//  SoundSeen
//
//  Full-screen mood-driven palette layer for the AnalyzedPlayerView.
//  Renders a radial gradient plus a slow-rotating conic overlay whose
//  colors are derived from the track's 2D emotion (valence, arousal).
//
//  Both valence and arousal arrive in [0, 1] (confirmed against
//  soundseen-backend/pipeline/emotion.py). We apply exponential moving
//  average smoothing inside this view to kill the 2Hz step that would
//  otherwise be visible since the upstream VisualizerState does a
//  nearest-neighbor lookup on a 0.5s-spaced sample array.
//

import SwiftUI

struct MoodPaletteBackground: View {
    /// Raw valence in [0, 1] from VisualizerState.currentValence.
    let valence: Double
    /// Raw arousal in [0, 1] from VisualizerState.currentArousal.
    let arousal: Double
    /// Exponentially-decaying beat pulse in [0, 1] from VisualizerState.beatPulse.
    /// Modulates palette brightness/saturation so the whole screen visibly
    /// flickers brighter on every beat.
    var beatPulse: Double = 0

    // EMA-smoothed values. α = 0.15 at 60Hz reaches 95% of a step in ~0.33s.
    @State private var smoothedV: Double = 0.5
    @State private var smoothedA: Double = 0.5
    @State private var didSeedSmoothing: Bool = false

    private static let alpha: Double = 0.15

    var body: some View {
        TimelineView(.animation) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            let v = smoothedV
            let a = smoothedA
            let pulse = max(0.0, min(1.0, beatPulse))
            let pulseBoost = pulse * 0.25

            let h = lerp(0.55, 0.92, v)
            let s = min(1.0, lerp(0.45, 1.00, a) + pulse * 0.15)
            let b = min(1.0, lerp(0.45, 0.85, a) + pulseBoost)

            let primary = Color(hue: h, saturation: s, brightness: b)
            let secondaryHue = wrapHue(h + 0.08)
            let secondary = Color(hue: secondaryHue,
                                  saturation: s * 0.8,
                                  brightness: b * 0.55)

            let rotationRate = 0.05 + a * 0.2
            let angle = (seconds * rotationRate).truncatingRemainder(dividingBy: .pi * 2)

            ZStack {
                Rectangle()
                    .fill(
                        RadialGradient(
                            colors: [primary, secondary],
                            center: UnitPoint(x: 0.5, y: 0.3),
                            startRadius: 20,
                            endRadius: 900
                        )
                    )

                AngularGradient(
                    gradient: Gradient(colors: [
                        primary.opacity(0.30),
                        secondary.opacity(0.45),
                        primary.opacity(0.20),
                        secondary.opacity(0.40),
                        primary.opacity(0.30),
                    ]),
                    center: .center
                )
                .rotationEffect(.radians(angle))
                .opacity(0.55)
            }
        }
        .onAppear {
            if !didSeedSmoothing {
                smoothedV = valence
                smoothedA = arousal
                didSeedSmoothing = true
            }
        }
        .onChange(of: valence) { _, newValue in
            smoothedV = Self.alpha * newValue + (1 - Self.alpha) * smoothedV
        }
        .onChange(of: arousal) { _, newValue in
            smoothedA = Self.alpha * newValue + (1 - Self.alpha) * smoothedA
        }
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        let clamped = max(0.0, min(1.0, t))
        return a + (b - a) * clamped
    }

    private func wrapHue(_ h: Double) -> Double {
        var v = h.truncatingRemainder(dividingBy: 1.0)
        if v < 0 { v += 1 }
        return v
    }
}

#Preview {
    MoodPaletteBackground(valence: 0.7, arousal: 0.6)
}

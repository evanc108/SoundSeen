//
//  BiomePaletteBackground.swift
//  SoundSeen
//
//  Bottom-most background for the analyzed player. Renders four biome
//  gradients — one per V/A quadrant — stacked and weighted by
//  VisualizerState.biomeWeights, so transiting between quadrants is a
//  smooth cross-fade rather than a hue slide within one palette.
//
//  Replaces MoodPaletteBackground (kept in-tree until PR1 ships). Smoothing
//  is now owned by VisualizerState.smoothedValence / smoothedArousal so
//  every biome-aware layer moves on the same curve.
//

import SwiftUI

struct BiomePaletteBackground: View {
    let weights: BiomeWeights
    /// Exponentially-decaying beat pulse in [0, 1]. Brightens all biomes
    /// slightly on every beat so the whole screen breathes with the track.
    var beatPulse: Double = 0

    var body: some View {
        TimelineView(.animation) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            let pulse = max(0, min(1, beatPulse))

            ZStack {
                Color.black.ignoresSafeArea()

                ForEach(Biome.allCases, id: \.rawValue) { biome in
                    let w = weights[biome]
                    if w > 0.04 {
                        biomeGradient(biome, seconds: seconds, pulse: pulse)
                            .opacity(w)
                            .ignoresSafeArea()
                    }
                }
            }
        }
    }

    // MARK: - Per-biome gradients

    @ViewBuilder
    private func biomeGradient(_ biome: Biome, seconds: Double, pulse: Double) -> some View {
        switch biome {
        case .euphoric:
            euphoric(seconds: seconds, pulse: pulse)
        case .serene:
            serene(seconds: seconds, pulse: pulse)
        case .intense:
            intense(seconds: seconds, pulse: pulse)
        case .melancholic:
            melancholic(seconds: seconds, pulse: pulse)
        }
    }

    /// Coral → gold. Warm, buoyant. Radial origin drifts upward (rising energy).
    private func euphoric(seconds: Double, pulse: Double) -> some View {
        let rise = CGFloat(0.5 + 0.15 * sin(seconds * 0.2))
        let core = Color(hue: 0.04, saturation: 0.85, brightness: 0.85 + 0.10 * pulse)
        let outer = Color(hue: 0.12, saturation: 0.90, brightness: 0.55 + 0.10 * pulse)
        return ZStack {
            RadialGradient(
                colors: [core, outer, .black],
                center: UnitPoint(x: 0.5, y: rise - 0.1),
                startRadius: 40,
                endRadius: 900
            )
            AngularGradient(
                gradient: Gradient(colors: [
                    core.opacity(0.25),
                    outer.opacity(0.35),
                    core.opacity(0.15),
                    outer.opacity(0.35),
                    core.opacity(0.25),
                ]),
                center: .center
            )
            .rotationEffect(.radians(seconds * 0.04))
            .opacity(0.45)
            .blendMode(.plusLighter)
        }
    }

    /// Pale teal → cream. Low-arousal, drifting. Slow horizontal sweep.
    private func serene(seconds: Double, pulse: Double) -> some View {
        let drift = CGFloat(0.5 + 0.12 * sin(seconds * 0.12))
        let core = Color(hue: 0.48, saturation: 0.55, brightness: 0.70 + 0.06 * pulse)
        let outer = Color(hue: 0.55, saturation: 0.30, brightness: 0.55 + 0.06 * pulse)
        let cream = Color(hue: 0.12, saturation: 0.15, brightness: 0.85)
        return ZStack {
            RadialGradient(
                colors: [cream.opacity(0.85), core, outer, .black.opacity(0.9)],
                center: UnitPoint(x: drift, y: 0.4),
                startRadius: 60,
                endRadius: 1000
            )
            LinearGradient(
                colors: [core.opacity(0.18), .clear, outer.opacity(0.22)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    /// Blood-orange → magenta with dark vignette. Centripetal energy.
    private func intense(seconds: Double, pulse: Double) -> some View {
        let core = Color(hue: 0.02, saturation: 0.95, brightness: 0.80 + 0.15 * pulse)
        let mid = Color(hue: 0.92, saturation: 0.90, brightness: 0.55 + 0.10 * pulse)
        let vignette = Color.black
        return ZStack {
            RadialGradient(
                colors: [core, mid, vignette],
                center: .center,
                startRadius: 20,
                endRadius: 700
            )
            // Pulsing radial vignette rim to keep attention focused center.
            RadialGradient(
                colors: [.clear, .clear, vignette.opacity(0.85)],
                center: .center,
                startRadius: 200,
                endRadius: 900
            )
            AngularGradient(
                gradient: Gradient(colors: [
                    core.opacity(0.35),
                    mid.opacity(0.25),
                    core.opacity(0.15),
                    mid.opacity(0.25),
                    core.opacity(0.35),
                ]),
                center: .center
            )
            .rotationEffect(.radians(seconds * 0.18))
            .opacity(0.55)
            .blendMode(.plusLighter)
        }
    }

    /// Indigo → slate. Sinking, desaturated. Light origin slides downward.
    private func melancholic(seconds: Double, pulse: Double) -> some View {
        let sink = CGFloat(0.35 + 0.10 * sin(seconds * 0.08))
        let core = Color(hue: 0.68, saturation: 0.55, brightness: 0.45 + 0.05 * pulse)
        let outer = Color(hue: 0.62, saturation: 0.35, brightness: 0.22 + 0.04 * pulse)
        return ZStack {
            RadialGradient(
                colors: [core, outer, .black],
                center: UnitPoint(x: 0.5, y: sink),
                startRadius: 80,
                endRadius: 1000
            )
            LinearGradient(
                colors: [.clear, outer.opacity(0.25)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

#Preview("Euphoric") {
    BiomePaletteBackground(
        weights: BiomeWeights(euphoric: 1, serene: 0, intense: 0, melancholic: 0),
        beatPulse: 0.5
    )
}

#Preview("Intense") {
    BiomePaletteBackground(
        weights: BiomeWeights(euphoric: 0, serene: 0, intense: 1, melancholic: 0),
        beatPulse: 0.5
    )
}

#Preview("Melancholic") {
    BiomePaletteBackground(
        weights: BiomeWeights(euphoric: 0, serene: 0, intense: 0, melancholic: 1),
        beatPulse: 0.2
    )
}

#Preview("Blend: euphoric/serene 50/50") {
    BiomePaletteBackground(
        weights: BiomeWeights(euphoric: 0.5, serene: 0.5, intense: 0, melancholic: 0),
        beatPulse: 0.3
    )
}

//
//  CentroidSparkleLayer.swift
//  SoundSeen
//
//  Ambient shimmer whose vertical distribution encodes spectral centroid:
//  when the sound is bright (cymbals, hats, sparkle), dots drift toward the
//  top of the frame; when it's bassy, they sink. Each dot's rest position
//  is deterministic from its index + current time (no mutable particle
//  state), and that rest is continuously pulled toward a centroid-derived
//  target. The effect is organic motion that shows you where the song's
//  spectral energy is sitting without needing a spectrum graph.
//

import SwiftUI

struct CentroidSparkleLayer: View {
    let visualizer: VisualizerState
    let paletteColor: Color

    private let sparkleCount = 80

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let centroid = visualizer.currentCentroid
            let lo = visualizer.centroidMin
            let hi = visualizer.centroidMax
            let range = max(1e-6, hi - lo)
            // 1.0 = bright (cymbals), 0.0 = dark (bass). Clamp so off-track
            // excursions don't push dots outside the safe region.
            let brightness = max(0.0, min(1.0, (centroid - lo) / range))
            let energy = max(0.0, min(1.0, visualizer.currentEnergy))

            Canvas { ctx, size in
                let w = size.width
                let h = size.height
                // Full-screen shimmer band so sparkles fill the whole view,
                // not just a strip around the cymatic shape. The band is
                // wide enough that dots reach the top and bottom edges.
                let bandTop = h * 0.04
                let bandBottom = h * 0.90
                // Target y based on brightness: bright → near top, dark →
                // near bottom. Inverted because SwiftUI y grows downward.
                let bandMid = bandTop + (bandBottom - bandTop) * (1.0 - brightness)

                for i in 0..<sparkleCount {
                    let seed = Double(i)
                    // Horizontal drift — slow low-frequency sine per-dot.
                    let xPhase = seed * 0.918 + t * 0.06
                    let xNorm = 0.5 + 0.5 * sin(xPhase + sin(seed * 1.317))
                    let x = xNorm * w

                    // Vertical rest position — time-seeded scatter clustered
                    // around bandMid. Scatter stays wide even at extremes so
                    // dots cover most of the screen; centroid just biases
                    // where the density centers.
                    let bandHeight = max(120.0, (bandBottom - bandTop) * (0.45 + 0.25 * (1 - abs(2 * brightness - 1))))
                    let yJitter = sin(seed * 2.713 + t * 0.22) + cos(seed * 1.511 + t * 0.31)
                    let y = bandMid + yJitter * bandHeight * 0.5

                    // Twinkle — each dot breathes at its own small phase.
                    let twinklePhase = seed * 1.09 + t * (0.6 + 0.8 * energy)
                    let twinkle = 0.45 + 0.55 * (0.5 + 0.5 * sin(twinklePhase))

                    let dotRadius: CGFloat = 2.2 + 3.0 * CGFloat(twinkle)
                    let alpha = (0.45 + 0.55 * energy) * twinkle

                    let rect = CGRect(
                        x: x - dotRadius,
                        y: y - dotRadius,
                        width: dotRadius * 2,
                        height: dotRadius * 2
                    )
                    ctx.fill(
                        Path(ellipseIn: rect),
                        with: .color(paletteColor.opacity(alpha))
                    )
                }
            }
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }
}

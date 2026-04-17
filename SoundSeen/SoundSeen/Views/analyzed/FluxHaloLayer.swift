//
//  FluxHaloLayer.swift
//  SoundSeen
//
//  Short-lived expanding halos spawned on spectral-flux spikes. These catch
//  transients that aren't beats — snare hits, synth stabs, cymbal crashes,
//  section-change whooshes — so the scene responds to the *texture* of the
//  song, not just its pulse. Stylistically tighter and faster than the
//  (deleted) beat rings: smaller max radius, shorter lifetime, secondary
//  palette tint, plus-lighter blend.
//

import SwiftUI
import QuartzCore

private struct FluxHalo {
    var spawnTime: TimeInterval
    var lifetime: Double
    var isAlive: Bool
}

struct FluxHaloLayer: View {
    let visualizer: VisualizerState
    let paletteColor: Color

    @State private var halos: [FluxHalo] = []
    @State private var lastGeneration: Int = 0

    private let capacity = 12
    private let lifetime: Double = 0.55
    private let startRadius: Double = 40

    var body: some View {
        TimelineView(.animation) { _ in
            // Observe the generation counter so this body re-evaluates when
            // a new spike lands; spawn lives in onChange so a single tick
            // redraw doesn't spawn twice.
            let _ = visualizer.fluxSpikeGeneration

            Canvas { ctx, size in
                let now = CACurrentMediaTime()
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                // Reach the far corner of whatever frame we're in so each
                // halo sweeps past the screen edges before fading out.
                let endRadius = hypot(size.width, size.height)

                for halo in halos where halo.isAlive {
                    let age = now - halo.spawnTime
                    guard age >= 0, age <= halo.lifetime else { continue }
                    let phase = age / halo.lifetime
                    let eased = 1 - pow(1 - phase, 3)

                    let radius = startRadius + (endRadius - startRadius) * eased
                    let stroke = 6.0 - 5.0 * eased
                    let alpha = (1 - phase) * 0.85

                    let rect = CGRect(
                        x: center.x - CGFloat(radius),
                        y: center.y - CGFloat(radius),
                        width: CGFloat(radius * 2),
                        height: CGFloat(radius * 2)
                    )
                    ctx.stroke(
                        Path(ellipseIn: rect),
                        with: .color(paletteColor.opacity(alpha)),
                        lineWidth: CGFloat(stroke)
                    )
                }
            }
            .blendMode(.plusLighter)
        }
        .onChange(of: visualizer.fluxSpikeGeneration) { _, newValue in
            guard newValue != lastGeneration else { return }
            lastGeneration = newValue
            spawn()
        }
        .allowsHitTesting(false)
    }

    private func spawn() {
        let now = CACurrentMediaTime()
        let fresh = FluxHalo(spawnTime: now, lifetime: lifetime, isAlive: true)

        // Reap dead rings before appending so the pool stays bounded under
        // bursty spike sequences. Appending-then-trim from the front would
        // also work; this is cheaper for the common case.
        halos.removeAll { !$0.isAlive || (now - $0.spawnTime) > $0.lifetime }
        if halos.count >= capacity {
            halos.removeFirst()
        }
        halos.append(fresh)
    }
}

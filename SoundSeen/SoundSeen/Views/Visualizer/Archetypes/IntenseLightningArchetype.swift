//
//  IntenseLightningArchetype.swift
//  SoundSeen
//
//  Low-V, high-A protagonist form — jagged crackle bolts that spawn on
//  flux spikes. Each bolt is a polyline with per-segment perpendicular
//  jitter plus a handful of branching forks. Lifetimes are ~280ms: long
//  enough to read as a strike, short enough to stack without smearing.
//
//  Emission is gated by *both* biome weight and smoothed arousal, so
//  when the scene's mood drifts into the low-V/high-A quadrant, bolts
//  also need the energy to be there to actually strike. This matches
//  how storms behave — tension + trigger, not just tension.
//

import SwiftUI

private let boltLifetime: Double = 0.28
private let maxConcurrentBolts: Int = 8

struct IntenseLightningArchetype: View {
    @Bindable var state: VisualizerState
    let weight: Double
    let scheme: EmotionScheme
    let dialect: SectionDialect
    let now: Date

    @State private var bolts: [Bolt] = []
    @State private var lastSpikeObserved: Int = -1

    var body: some View {
        if weight > Archetype.minWeight {
            Canvas { ctx, size in
                let t = now.timeIntervalSinceReferenceDate
                reap(at: t)
                for bolt in bolts {
                    drawBolt(ctx: &ctx, bolt: bolt, size: size, t: t)
                }
            }
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
            .onChange(of: state.fluxSpikeGeneration) { _, newGen in
                if newGen != lastSpikeObserved {
                    lastSpikeObserved = newGen
                    maybeEmit()
                }
            }
        }
    }

    // MARK: - Emission

    /// A flux spike only produces a bolt if arousal is actually high. The
    /// archetype being rendered at all already requires the intense
    /// biome's weight to be up, but weight alone doesn't imply a storm
    /// is breaking — we want arousal > 0.55 so bolts only fire during
    /// genuinely energetic passages.
    private func maybeEmit() {
        guard state.smoothedArousal > 0.55 else { return }

        let t = now.timeIntervalSinceReferenceDate
        let intensity = state.currentFlux * state.smoothedArousal
        // 1 bolt at low intensity, up to 3 at peak.
        let count = max(1, min(3, Int((intensity * 4).rounded())))

        for _ in 0..<count {
            bolts.append(makeBolt(at: t))
        }
        if bolts.count > maxConcurrentBolts {
            bolts.removeFirst(bolts.count - maxConcurrentBolts)
        }
    }

    private func makeBolt(at t: Double) -> Bolt {
        // Unit-square endpoints. One edge-hugging anchor + one mid-scene
        // target keeps bolts visually grounded. Sides picked randomly so
        // strikes feel non-deterministic.
        let originSide = Int.random(in: 0..<4)
        let (u0, v0) = edgePoint(side: originSide)
        // Target lands in the central 60% so every bolt crosses the
        // scene rather than hugging one corner.
        let u1 = Double.random(in: 0.25...0.75)
        let v1 = Double.random(in: 0.25...0.75)

        // 6–10 waypoints between endpoints, each nudged perpendicular
        // to the bolt axis. More waypoints → more jagged.
        let segments = Int.random(in: 6...10)
        var waypoints: [(Double, Double)] = []
        for i in 1..<segments {
            let f = Double(i) / Double(segments)
            // Base position along the line.
            let bx = u0 + (u1 - u0) * f
            let by = v0 + (v1 - v0) * f
            // Perpendicular jitter — strongest in the middle, tapers at
            // endpoints so the bolt actually connects origin → target.
            let amp = 0.055 * sin(f * .pi)
            let perpX = -(v1 - v0)
            let perpY = (u1 - u0)
            let mag = max(1e-6, (perpX * perpX + perpY * perpY).squareRoot())
            let jitter = Double.random(in: -1...1) * amp
            waypoints.append((
                bx + perpX / mag * jitter,
                by + perpY / mag * jitter
            ))
        }

        // Optional single fork branching off a mid-path waypoint.
        var forkStart: Int? = nil
        var forkEnd: (Double, Double)? = nil
        if Double.random(in: 0...1) < 0.55 && waypoints.count >= 4 {
            let idx = Int.random(in: 1..<(waypoints.count - 1))
            forkStart = idx
            let start = waypoints[idx]
            forkEnd = (
                start.0 + Double.random(in: -0.18...0.18),
                start.1 + Double.random(in: -0.15...0.15)
            )
        }

        return Bolt(
            start: (u0, v0),
            end: (u1, v1),
            waypoints: waypoints,
            forkStart: forkStart,
            forkEnd: forkEnd,
            birth: t,
            intensity: max(0.4, state.currentFlux)
        )
    }

    private func edgePoint(side: Int) -> (Double, Double) {
        switch side {
        case 0: return (Double.random(in: 0...1), 0)       // top
        case 1: return (1, Double.random(in: 0...1))       // right
        case 2: return (Double.random(in: 0...1), 1)       // bottom
        default: return (0, Double.random(in: 0...1))      // left
        }
    }

    private func reap(at t: Double) {
        bolts.removeAll { t - $0.birth >= boltLifetime }
    }

    // MARK: - Drawing

    private func drawBolt(
        ctx: inout GraphicsContext,
        bolt: Bolt,
        size: CGSize,
        t: Double
    ) {
        let age = t - bolt.birth
        let norm = age / boltLifetime
        guard norm < 1 else { return }

        // Flash envelope: fast rise, linear fall. Lightning doesn't fade
        // symmetrically — it *snaps* on and trails off.
        let env: Double
        if norm < 0.12 {
            env = norm / 0.12
        } else {
            env = (1 - norm) / 0.88
        }
        let alpha = env * bolt.intensity * weight

        // Path: start → each waypoint → end, in unit coords scaled to size.
        func point(_ u: Double, _ v: Double) -> CGPoint {
            CGPoint(x: u * size.width, y: v * size.height)
        }

        var path = Path()
        path.move(to: point(bolt.start.0, bolt.start.1))
        for w in bolt.waypoints {
            path.addLine(to: point(w.0, w.1))
        }
        path.addLine(to: point(bolt.end.0, bolt.end.1))

        // Two-pass stroke: wide outer glow + thin inner core so the bolt
        // reads as hot and bright, not just a line. MFCC[1] modulates
        // core thickness — bright timbre → sharper thinner bolts,
        // warm/muffled timbre → fatter softer bolts.
        let glow = scheme.primary
        let core = scheme.accent
        let mfcc1 = state.currentMFCC.count > 1 ? state.currentMFCC[1] : 0.5
        let coreLineWidth = 1.0 + (1 - mfcc1) * 1.6
        let glowLineWidth = 3.5 + (1 - mfcc1) * 2.5

        var glowCtx = ctx
        glowCtx.addFilter(.blur(radius: 6))
        glowCtx.stroke(
            path,
            with: .color(glow.color(opacity: alpha * 0.6)),
            style: StrokeStyle(lineWidth: glowLineWidth, lineCap: .round, lineJoin: .round)
        )

        ctx.stroke(
            path,
            with: .color(core.color(opacity: alpha)),
            style: StrokeStyle(lineWidth: coreLineWidth, lineCap: .round, lineJoin: .round)
        )

        // Optional fork.
        if let forkIdx = bolt.forkStart,
           let forkEnd = bolt.forkEnd,
           forkIdx < bolt.waypoints.count {
            var forkPath = Path()
            let startPt = bolt.waypoints[forkIdx]
            forkPath.move(to: point(startPt.0, startPt.1))
            forkPath.addLine(to: point(forkEnd.0, forkEnd.1))

            var forkGlow = ctx
            forkGlow.addFilter(.blur(radius: 5))
            forkGlow.stroke(
                forkPath,
                with: .color(glow.color(opacity: alpha * 0.4)),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
            ctx.stroke(
                forkPath,
                with: .color(core.color(opacity: alpha * 0.75)),
                style: StrokeStyle(lineWidth: 1.0, lineCap: .round)
            )
        }
    }

    private struct Bolt {
        let start: (Double, Double)
        let end: (Double, Double)
        let waypoints: [(Double, Double)]
        let forkStart: Int?
        let forkEnd: (Double, Double)?
        let birth: Double
        let intensity: Double
    }
}

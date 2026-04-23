//
//  FluxShatterTexture.swift
//  SoundSeen
//
//  Short directional shards across the HORIZON_BAND, triggered by
//  fluxSpikeGeneration (the backend's adaptive-threshold transient
//  detector). Flux = rate of spectral change; a sudden change is a
//  rupture, not a steady shimmer. Slashes read as "something broke or
//  moved suddenly" — distinct from Ember's vertical-attack language.
//
//  Each spike emits 3–8 shards at random u, angle ±30° from horizontal.
//  Lifetime 80–180ms. Cap 18 shards on-screen (24 in chorus/drop).
//

import SwiftUI

private let shardLifetime: Double = 0.18

struct FluxShatterTexture: View {
    @Bindable var state: VisualizerState
    let scheme: EmotionScheme
    let dialect: SectionDialect
    let now: Date

    @State private var shards: [Shard] = []
    @State private var lastSpikeObserved: Int = -1

    var body: some View {
        if dialect.enabledTextures.contains(.fluxShatter) {
            Canvas { ctx, size in
                let t = now.timeIntervalSinceReferenceDate
                reap(at: t)
                for s in shards {
                    drawShard(ctx: &ctx, shard: s, t: t, size: size)
                }
            }
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
            .onChange(of: state.fluxSpikeGeneration) { _, newGen in
                if newGen != lastSpikeObserved {
                    lastSpikeObserved = newGen
                    emitBurst()
                }
            }
        }
    }

    private func emitBurst() {
        let flux = state.currentFlux
        let count = 3 + Int(flux * 5)
        let t = now.timeIntervalSinceReferenceDate

        // Color: primary at birth, tinted toward key when tonal.
        let cs = state.currentChromaStrength
        let keyHSB = HSB(h: state.currentHue, s: 0.85, b: 1.0)
        let color: HSB = cs > 0.5
            ? blend2(scheme.primary, keyHSB, 0.4)
            : scheme.primary

        for _ in 0..<count {
            let u = Double.random(in: 0.05...0.95)
            // v within HORIZON_BAND.
            let v = Double.random(in: 0.46...0.54)
            // Angle: ±30° from horizontal in radians.
            let angle = Double.random(in: -.pi/6 ... .pi/6)
            let length = Double.random(in: 20...80)
            let thickness = Double.random(in: 1...3)

            shards.append(Shard(
                unitU: u,
                unitV: v,
                angle: angle,
                length: length,
                thickness: thickness,
                birth: t,
                color: color,
                intensity: max(0.35, flux)
            ))
        }
        capPool()
    }

    private func capPool() {
        let cap = (dialect.mirrorX || dialect.allowOffscreen) ? 24 : 18
        if shards.count > cap {
            shards.removeFirst(shards.count - cap)
        }
    }

    private func reap(at t: Double) {
        shards.removeAll { t - $0.birth >= shardLifetime }
    }

    private func drawShard(
        ctx: inout GraphicsContext,
        shard: Shard,
        t: Double,
        size: CGSize
    ) {
        let age = t - shard.birth
        let norm = age / shardLifetime
        guard norm < 1 else { return }

        // Alpha: fast rise, fast fall (sin envelope gives a clean slash).
        let env = sin(norm * .pi)
        let alpha = env * shard.intensity

        let cx = shard.unitU * size.width
        let cy = shard.unitV * size.height
        let half = shard.length / 2
        let dx = cos(shard.angle) * half
        let dy = sin(shard.angle) * half
        let p0 = CGPoint(x: cx - dx, y: cy - dy)
        let p1 = CGPoint(x: cx + dx, y: cy + dy)

        var path = Path()
        path.move(to: p0)
        path.addLine(to: p1)

        ctx.stroke(
            path,
            with: .color(shard.color.color(opacity: alpha)),
            style: StrokeStyle(lineWidth: shard.thickness, lineCap: .round)
        )
    }

    private struct Shard {
        let unitU: Double
        let unitV: Double
        let angle: Double
        let length: Double
        let thickness: Double
        let birth: Double
        let color: HSB
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

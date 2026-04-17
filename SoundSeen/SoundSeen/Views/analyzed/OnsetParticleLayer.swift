//
//  OnsetParticleLayer.swift
//  SoundSeen
//
//  Onset-driven particle bursts for the AnalyzedPlayerView. A cursor over
//  analysis.onsetEvents advances on every audio tick; each crossed onset
//  spawns an AttackParticle whose lifetime / velocity / size / color are
//  driven by the ADSR envelope shipped by the backend.
//
//  All mutable state lives in OnsetParticleController (a reference type)
//  so the SwiftUI view struct stays a pure renderer. The controller is
//  @Observable and bumps a `generation` counter on every tick, which
//  triggers TimelineView-wrapped re-renders even when the Canvas closure
//  is re-evaluated on display-link frames.
//
//  Clock discipline: spawnTime and the Canvas "now" are both CACurrentMediaTime
//  (monotonic, main-thread safe). TimelineView(.animation) drives the redraw
//  cadence — we read its date for re-evaluation, but timing math uses
//  CACurrentMediaTime to stay on one clock.
//

import SwiftUI
import QuartzCore

// MARK: - Particle

struct AttackParticle {
    var spawnTime: TimeInterval   // CACurrentMediaTime at spawn
    var lifetime: Double          // seconds
    var origin: CGPoint           // normalized (0..1, 0..1) — resolved to view size at draw time
    var angle: Double             // radians
    var initialVelocity: Double   // pts/s
    var size: Double              // pts
    var hue: Double
    var saturation: Double
    var brightness: Double
    var sustainLevel: Double      // opacity floor during sustain phase
    var isAlive: Bool
}

// MARK: - Pool

@MainActor
final class ParticlePool {
    private(set) var particles: [AttackParticle] = []
    private let capacity = 80
    private var writeIndex = 0

    func spawn(_ p: AttackParticle) {
        if particles.count < capacity {
            particles.append(p)
        } else {
            particles[writeIndex] = p
            writeIndex = (writeIndex + 1) % capacity
        }
    }

    func reap(now: TimeInterval) {
        for i in particles.indices where particles[i].isAlive {
            let age = now - particles[i].spawnTime
            if age >= particles[i].lifetime {
                particles[i].isAlive = false
            }
        }
    }
}

// MARK: - Controller

@Observable
@MainActor
final class OnsetParticleController {
    @ObservationIgnored private let onsets: [OnsetEvent]
    @ObservationIgnored private var cursor: Int = 0
    @ObservationIgnored let pool = ParticlePool()

    /// Bumped on every tick that produces state changes. The Canvas reads
    /// this inside its draw closure so the @Observable machinery knows to
    /// re-invoke the body when the pool mutates.
    private(set) var generation: Int = 0

    init(onsets: [OnsetEvent]) {
        self.onsets = onsets
    }

    /// Drive the particle cursor forward one tick. Wire into
    /// `AudioPlayer.addTickHandler` alongside visualizer + haptics.
    func tick(prevTime: Double, currentTime: Double, valence: Double, arousal: Double) {
        // Seek discontinuity detection — same pattern as VisualizerState.swift:128
        // and HapticEngine.swift:80. Backward jump or forward jump > 2s rebinds
        // the cursor. Tiny scrubs (< 2s) advance naturally.
        if currentTime < prevTime || (currentTime - prevTime) > 2.0 {
            cursor = firstOnsetIndex(atOrAfter: currentTime)
            generation &+= 1
            return
        }

        // Skip any onsets that were already in the past at the start of this tick.
        while cursor < onsets.count && onsets[cursor].time <= prevTime {
            cursor += 1
        }
        // Spawn for every onset that fired in (prevTime, currentTime].
        while cursor < onsets.count && onsets[cursor].time <= currentTime {
            spawnParticle(for: onsets[cursor], valence: valence, arousal: arousal)
            cursor += 1
        }

        generation &+= 1
    }

    // MARK: - Private

    private func firstOnsetIndex(atOrAfter time: Double) -> Int {
        var lo = 0
        var hi = onsets.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if onsets[mid].time < time {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    private func spawnParticle(for onset: OnsetEvent, valence: Double, arousal: Double) {
        // Mood → HSB using the same formulas as MoodPaletteBackground. Keep the
        // components (not the Color) so we can modulate opacity at draw time.
        let v = clamp01(valence)
        let a = clamp01(arousal)
        let hue = lerp(0.55, 0.92, v)
        let saturation = lerp(0.45, 1.00, a)
        let baseBrightness = lerp(0.45, 0.85, a)
        // Small brightness bump keyed by onset intensity so transients pop.
        let brightness = min(0.95, baseBrightness + 0.3 * clamp01(onset.intensity))

        let lifetime = clamp(onset.decayTimeMs / 1000.0, minValue: 0.12, maxValue: 2.0)
        let initialVelocity = onset.attackSlope * 200.0
        let angle = Double.random(in: 0 ..< 2 * .pi)
        let size = 6.0 + onset.attackStrength * 20.0
        let sustainLevel = max(0.0, min(0.6, onset.sustainLevel))

        let particle = AttackParticle(
            spawnTime: CACurrentMediaTime(),
            lifetime: lifetime,
            origin: CGPoint(x: 0.5, y: 0.5),
            angle: angle,
            initialVelocity: initialVelocity,
            size: size,
            hue: hue,
            saturation: saturation,
            brightness: brightness,
            sustainLevel: sustainLevel,
            isAlive: true
        )
        pool.spawn(particle)
    }

    private func clamp01(_ x: Double) -> Double {
        max(0.0, min(1.0, x))
    }

    private func clamp(_ x: Double, minValue: Double, maxValue: Double) -> Double {
        max(minValue, min(maxValue, x))
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        let c = clamp01(t)
        return a + (b - a) * c
    }
}

// MARK: - View

struct OnsetParticleLayer: View {
    let controller: OnsetParticleController

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { context, size in
                // Read `generation` so the @Observable tracker subscribes the
                // Canvas to controller changes. Discarded — the value itself
                // doesn't affect rendering, only the dependency it registers.
                _ = controller.generation

                let now = CACurrentMediaTime()
                let center = CGPoint(x: size.width / 2, y: size.height / 2)

                for p in controller.pool.particles where p.isAlive {
                    let age = now - p.spawnTime
                    guard age >= 0, age <= p.lifetime, p.lifetime > 0 else { continue }

                    let phase = age / p.lifetime
                    let opacity: Double
                    if phase < 0.75 {
                        // Fade 1.0 → sustainLevel across the first 75% of lifetime.
                        opacity = 1.0 - (1.0 - p.sustainLevel) * (phase / 0.75)
                    } else {
                        // Fade sustainLevel → 0 across the final 25%.
                        opacity = p.sustainLevel * (1.0 - (phase - 0.75) / 0.25)
                    }

                    let distance = p.initialVelocity * age
                    let x = center.x + CGFloat(cos(p.angle) * distance)
                    let y = center.y + CGFloat(sin(p.angle) * distance)
                    let rect = CGRect(
                        x: x - CGFloat(p.size) / 2,
                        y: y - CGFloat(p.size) / 2,
                        width: CGFloat(p.size),
                        height: CGFloat(p.size)
                    )
                    let color = Color(
                        hue: p.hue,
                        saturation: p.saturation,
                        brightness: p.brightness
                    ).opacity(max(0.0, opacity))
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
    }
}

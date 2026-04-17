//
//  ExpressiveLayers.swift
//  SoundSeen
//
//  A stack of obvious, high-contrast animated shapes wired to
//  AudioReactivePlayer's realtime signals so they work on every track
//  (bundled or imported) without any backend round-trip.
//
//  Each layer is a self-contained View that observes only the ARP fields
//  it needs. Layers are split into "background" (behind visualizer core)
//  and "overlay" (above content) so z-order is explicit.
//

import SwiftUI
import QuartzCore

// MARK: - Public entry points

/// Drops-in behind the visualizer core. Only renders the beat rings — the
/// existing TimbreSpaceVisualizer ring is the focal element, so adding a
/// central orb or spectrum flower behind it creates visual collision.
struct ExpressiveBackgroundLayers: View {
    @ObservedObject var player: AudioReactivePlayer
    /// Color used to tint all layers — pass in the caller's adaptive theme
    /// color so new visuals match the existing mood palette.
    var tint: Color = .white

    var body: some View {
        ExpressiveBeatRingsView(player: player, tint: tint)
            .allowsHitTesting(false)
            .ignoresSafeArea()
    }
}

/// Drops-in on top of content. Renders beat flash, film grain, bass floor.
struct ExpressiveOverlayLayers: View {
    @ObservedObject var player: AudioReactivePlayer
    var tint: Color = .white

    var body: some View {
        ZStack {
            FilmGrainView(player: player)
            BeatFlashView(player: player, tint: tint)
            VStack {
                Spacer()
                ExpressiveBassFloorView(player: player, tint: tint)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

// MARK: - Beat detection helper

/// Detects a rising-edge beat from a decaying `beatPulse` scalar.
/// ARP doesn't expose discrete beat events — we synthesize them here.
private struct BeatDetector {
    var previous: Double = 0
    var lastFireAt: TimeInterval = 0

    /// Returns true if a beat just fired this tick.
    mutating func step(current: Double, now: TimeInterval) -> Bool {
        defer { previous = current }
        let threshold = 0.5
        let minInterval = 0.12
        guard current > threshold,
              previous <= threshold,
              (now - lastFireAt) > minInterval else { return false }
        lastFireAt = now
        return true
    }
}

// MARK: - Beat rings

private struct RingInstance: Identifiable {
    let id = UUID()
    let spawn: TimeInterval
    let lifetime: Double
    let intensity: Double
    let isStrong: Bool
}

private struct ExpressiveBeatRingsView: View {
    @ObservedObject var player: AudioReactivePlayer
    var tint: Color = .white
    @State private var rings: [RingInstance] = []
    @State private var detector = BeatDetector()

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { ctx, size in
                let now = CACurrentMediaTime()
                let center = CGPoint(x: size.width / 2, y: size.height / 2)

                for ring in rings {
                    let age = now - ring.spawn
                    guard age >= 0, age <= ring.lifetime else { continue }
                    let phase = age / ring.lifetime
                    let eased = 1 - pow(1 - phase, 3)

                    let startR: Double = ring.isStrong ? 40 : 25
                    let endR: Double = ring.isStrong ? 720 : 420
                    let startS: Double = ring.isStrong ? 8 : 4
                    let endS: Double = ring.isStrong ? 1.5 : 0.5

                    let radius = startR + (endR - startR) * eased
                    let stroke = startS + (endS - startS) * eased
                    let alpha = (1 - phase) * (ring.isStrong ? 0.85 : 0.65)

                    let rect = CGRect(
                        x: center.x - CGFloat(radius),
                        y: center.y - CGFloat(radius),
                        width: CGFloat(radius * 2),
                        height: CGFloat(radius * 2)
                    )
                    ctx.stroke(
                        Path(ellipseIn: rect),
                        with: .color(tint.opacity(alpha)),
                        lineWidth: CGFloat(stroke)
                    )
                }
            }
        }
        .onChange(of: player.beatPulse) { _, newValue in
            let now = CACurrentMediaTime()
            let val = Double(newValue)
            if detector.step(current: val, now: now) {
                let isStrong = val > 0.8 || Double(player.bassEnergy) > 0.5
                rings.append(RingInstance(
                    spawn: now,
                    lifetime: isStrong ? 0.6 : 0.35,
                    intensity: val,
                    isStrong: isStrong
                ))
                // Trim dead rings
                rings = rings.filter { now - $0.spawn < 1.0 }
            }
        }
    }
}

// MARK: - Kick pulse orb

private struct ExpressiveKickOrbView: View {
    @ObservedObject var player: AudioReactivePlayer
    @State private var currentScale: CGFloat = 1.0
    @State private var currentOpacity: Double = 0.55

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Outer soft halo
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.white.opacity(0.28 - Double(i) * 0.08))
                        .blur(radius: CGFloat(18 + i * 10))
                        .frame(width: 180, height: 180)
                        .scaleEffect(currentScale + CGFloat(i) * 0.08)
                        .blendMode(.plusLighter)
                }

                // Core
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                .white.opacity(currentOpacity),
                                .white.opacity(0.0)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 100
                        )
                    )
                    .frame(width: 180, height: 180)
                    .scaleEffect(currentScale)
                    .overlay(
                        Circle()
                            .stroke(.white.opacity(currentOpacity * 0.75), lineWidth: 2)
                            .frame(width: 180, height: 180)
                            .scaleEffect(currentScale)
                    )
            }
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .onChange(of: player.bassEnergy) { _, newValue in
            let bass = Double(newValue)
            let target = 1.0 + 0.45 * bass
            withAnimation(.interpolatingSpring(duration: 0.22, bounce: 0.3)) {
                currentScale = CGFloat(target)
            }
        }
        .onChange(of: player.beatPulse) { _, newValue in
            let pulse = Double(newValue)
            withAnimation(.easeOut(duration: 0.08)) {
                currentOpacity = 0.55 + 0.4 * pulse
            }
        }
    }
}

// MARK: - Beat flash

private struct BeatFlashView: View {
    @ObservedObject var player: AudioReactivePlayer
    var tint: Color = .white
    @State private var currentOpacity: Double = 0
    @State private var lastFlashAt: TimeInterval = 0
    @State private var detector = BeatDetector()

    var body: some View {
        RadialGradient(
            colors: [tint.opacity(currentOpacity), .clear],
            center: .center,
            startRadius: 0,
            endRadius: 700
        )
        .onChange(of: player.beatPulse) { _, newValue in
            let now = CACurrentMediaTime()
            let val = Double(newValue)
            // Fire only on strong beats or rising drop
            let strong = val > 0.8 || Double(player.dropLikelihood) > 0.55
            if detector.step(current: val, now: now) && strong && (now - lastFlashAt) > 0.35 {
                lastFlashAt = now
                withAnimation(.easeOut(duration: 0.05)) { currentOpacity = 0.35 }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    withAnimation(.easeOut(duration: 0.2)) { currentOpacity = 0 }
                }
            }
        }
    }
}

// MARK: - Bass floor

private struct ExpressiveBassFloorView: View {
    @ObservedObject var player: AudioReactivePlayer
    var tint: Color = .white
    @State private var currentHeight: CGFloat = 2

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        tint.opacity(0.1),
                        tint.opacity(0.75),
                        tint.opacity(0.1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: currentHeight)
            .shadow(color: tint.opacity(0.4), radius: 10)
            .onChange(of: player.bassEnergy) { _, newValue in
                let bass = Double(newValue)
                let target: CGFloat = 2 + 60 * bass
                withAnimation(.interpolatingSpring(duration: 0.2, bounce: 0.25)) {
                    currentHeight = target
                }
            }
    }
}

// MARK: - Film grain

private struct FilmGrainView: View {
    @ObservedObject var player: AudioReactivePlayer

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            Canvas { ctx, size in
                // Seed random positions based on the timeline date so the
                // grain "boils" between frames.
                let grain = Double(player.timbreGrain)
                let count = Int(40 + 180 * grain)
                var rng = SeededRNG(seed: UInt64(context.date.timeIntervalSinceReferenceDate * 30))
                for _ in 0..<count {
                    let x = Double(rng.next() % 1000) / 1000.0 * size.width
                    let y = Double(rng.next() % 1000) / 1000.0 * size.height
                    let r: CGFloat = 0.6 + CGFloat(Double(rng.next() % 100) / 100.0) * 1.2
                    let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                    ctx.fill(
                        Path(ellipseIn: rect),
                        with: .color(.white.opacity(0.08 + 0.1 * grain))
                    )
                }
            }
        }
        .blendMode(.overlay)
    }
}

// MARK: - Spectrum flower

private struct SpectrumFlowerView: View {
    @ObservedObject var player: AudioReactivePlayer

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, size in
                let seconds = context.date.timeIntervalSinceReferenceDate
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let rotation = seconds * 0.12
                let bands = sampledBands()

                // 16 spokes (twice the 8 we'd have from backend — use every-other interpolation for smoother look).
                let spokes = 16
                for i in 0..<spokes {
                    let bandIdx = (i * bands.count) / spokes
                    let energy = bands[bandIdx]
                    let angle = (Double(i) / Double(spokes)) * 2 * .pi + rotation
                    let startR: Double = 120
                    let endR: Double = 120 + 220 * energy

                    let x1 = center.x + CGFloat(cos(angle) * startR)
                    let y1 = center.y + CGFloat(sin(angle) * startR)
                    let x2 = center.x + CGFloat(cos(angle) * endR)
                    let y2 = center.y + CGFloat(sin(angle) * endR)

                    var path = Path()
                    path.move(to: CGPoint(x: x1, y: y1))
                    path.addLine(to: CGPoint(x: x2, y: y2))

                    let alpha = 0.35 + 0.45 * energy
                    ctx.stroke(
                        path,
                        with: .color(.white.opacity(alpha)),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                }
            }
        }
    }

    /// ARP exposes 44 log-spaced bins; sum them into 8 coarse bands for the
    /// flower so each spoke has a visibly different length.
    private func sampledBands() -> [Double] {
        let bars = player.barLevels.map { Double($0) }
        guard bars.count >= 8 else {
            return [Double](repeating: 0, count: 8)
        }
        let bucket = bars.count / 8
        var out: [Double] = []
        for i in 0..<8 {
            let lo = i * bucket
            let hi = min(bars.count, lo + bucket)
            let slice = bars[lo..<hi]
            let avg = slice.isEmpty ? 0 : slice.reduce(0, +) / Double(slice.count)
            out.append(min(1.0, avg))
        }
        return out
    }
}

// MARK: - Tiny seeded RNG (avoids stdlib `Int.random` overhead for grain)

private struct SeededRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0xDEADBEEF : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

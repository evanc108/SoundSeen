//
//  QuadrantBiome.swift
//  SoundSeen
//
//  The four emotion biomes stacked above the palette background. Each
//  sub-view owns its own Canvas and particle motion language — all curved
//  and flowing, matching the "abstract & organic" aesthetic. Opacity is
//  driven by BiomeWeights so the scene cross-fades between biomes as V/A
//  drifts across quadrant boundaries.
//
//  Particle positions are generated deterministically from the current time
//  (via sin/cos offsets keyed by an index) instead of mutable state, so the
//  render is stateless and cheap to skip.
//

import SwiftUI

struct QuadrantBiomeLayer: View {
    let weights: BiomeWeights
    /// Exponentially-decaying beat pulse in [0, 1] for subtle all-biome breath.
    var beatPulse: Double = 0

    var body: some View {
        ZStack {
            if weights.euphoric > 0.04 {
                EuphoricBiome(weight: weights.euphoric, beatPulse: beatPulse)
            }
            if weights.serene > 0.04 {
                SereneBiome(weight: weights.serene, beatPulse: beatPulse)
            }
            if weights.intense > 0.04 {
                IntenseBiome(weight: weights.intense, beatPulse: beatPulse)
            }
            if weights.melancholic > 0.04 {
                MelancholicBiome(weight: weights.melancholic, beatPulse: beatPulse)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Euphoric — buoyant rising bubbles

private struct EuphoricBiome: View {
    let weight: Double
    let beatPulse: Double

    private let bubbleCount = 72
    private let riseDuration: Double = 6.0

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = max(0, min(1, beatPulse))

            Canvas { ctx, size in
                for i in 0..<bubbleCount {
                    let offset = Double(i) / Double(bubbleCount)
                    let phase = (t / riseDuration + offset).truncatingRemainder(dividingBy: 1.0)

                    // Horizontal anchor + gentle sway. Seeded per-bubble via
                    // irrational-like multipliers so columns don't align.
                    let anchorX = Double(i) * 0.2718 + 0.15
                    let wrapX = anchorX.truncatingRemainder(dividingBy: 1.0)
                    let sway = sin(t * 0.5 + Double(i) * 1.37) * 0.04
                    let x = (wrapX + sway) * size.width

                    // Bottom → top.
                    let y = size.height * (1.0 - phase)

                    // Fade in bottom 15%, out top 15%.
                    var alpha: Double = 1.0
                    if phase < 0.15 { alpha = phase / 0.15 }
                    else if phase > 0.85 { alpha = (1.0 - phase) / 0.15 }

                    let radius: Double = (20 + Double(i % 7) * 9) * (0.9 + pulse * 0.4)
                    let hue = 0.04 + 0.08 * sin(Double(i) * 0.9 + t * 0.1)
                    let fill = Color(hue: hue, saturation: 0.90, brightness: 1.0)

                    let rect = CGRect(
                        x: x - radius,
                        y: y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    ctx.fill(
                        Path(ellipseIn: rect),
                        with: .color(fill.opacity(alpha * 0.85 * weight))
                    )
                }
            }
            .blur(radius: 6)
            .blendMode(.plusLighter)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Serene — sparse orbiting disks + wide breathing ribbon

private struct SereneBiome: View {
    let weight: Double
    let beatPulse: Double

    private let diskCount = 12

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = max(0, min(1, beatPulse))

            Canvas { ctx, size in
                let center = CGPoint(x: size.width / 2, y: size.height * 0.45)

                // Disks on a wide, slow orbit. Radii vary per disk so they
                // don't all stack on one ring.
                for i in 0..<diskCount {
                    let offset = Double(i) / Double(diskCount)
                    let angle = t * 0.08 + offset * .pi * 2
                    let orbitR = 140.0 + Double(i) * 28.0
                    let x = center.x + CGFloat(cos(angle) * orbitR)
                    let y = center.y + CGFloat(sin(angle) * orbitR * 0.6)
                    let r: CGFloat = 60 + CGFloat(i * 6)
                    let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)

                    let hue = 0.48 + 0.04 * sin(Double(i) + t * 0.05)
                    let fill = Color(hue: hue, saturation: 0.55, brightness: 0.95)
                    ctx.fill(
                        Path(ellipseIn: rect),
                        with: .color(fill.opacity((0.45 + 0.12 * pulse) * weight))
                    )
                }

                // Wide horizontal ribbon breathing at 0.3Hz. Drawn as a
                // cubic curve through three control points.
                let breath = 0.5 + 0.5 * sin(t * 0.3 * .pi * 2)
                let cy = size.height * (0.5 + 0.04 * sin(t * 0.2))
                var path = Path()
                path.move(to: CGPoint(x: -60, y: cy))
                path.addCurve(
                    to: CGPoint(x: size.width + 60, y: cy + 20),
                    control1: CGPoint(x: size.width * 0.3, y: cy - 100 * breath),
                    control2: CGPoint(x: size.width * 0.7, y: cy + 100 * breath)
                )
                let ribbonHue = 0.52
                let ribbonColor = Color(hue: ribbonHue, saturation: 0.60, brightness: 1.0)
                ctx.stroke(
                    path,
                    with: .color(ribbonColor.opacity(0.60 * weight)),
                    style: StrokeStyle(lineWidth: 110 + CGFloat(breath * 50), lineCap: .round)
                )
            }
            .blur(radius: 14)
            .blendMode(.plusLighter)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Intense — dense blob swarm centripetal

private struct IntenseBiome: View {
    let weight: Double
    let beatPulse: Double

    private let blobCount = 40

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = max(0, min(1, beatPulse))

            Canvas { ctx, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)

                for i in 0..<blobCount {
                    let offset = Double(i) / Double(blobCount)
                    let angle = t * 0.55 + offset * .pi * 2 + Double(i) * 0.33
                    // Breathing orbit radius — contracts on beats. Extended
                    // outer orbits so blobs reach the screen edges, not just
                    // hug the center.
                    let baseOrbit = 100.0 + Double(i % 7) * 60.0
                    let orbitR = baseOrbit * (1.0 - 0.25 * pulse) + 20 * sin(t * 0.8 + Double(i))
                    let x = center.x + CGFloat(cos(angle) * orbitR)
                    let y = center.y + CGFloat(sin(angle) * orbitR)
                    let r: CGFloat = 24 + CGFloat(i % 6) * 6
                    let rect = CGRect(
                        x: x - r,
                        y: y - r,
                        width: r * 2,
                        height: r * 2
                    )

                    let hue = 0.02 + 0.90 * Double(i % 3) / 3.0
                    let wrappedHue = hue.truncatingRemainder(dividingBy: 1.0)
                    let fill = Color(hue: wrappedHue, saturation: 1.0, brightness: 1.0)
                    ctx.fill(
                        Path(ellipseIn: rect),
                        with: .color(fill.opacity((0.75 + 0.25 * pulse) * weight))
                    )
                }
            }
            .blur(radius: 8)
            .blendMode(.plusLighter)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Melancholic — slow descending droplets

private struct MelancholicBiome: View {
    let weight: Double
    let beatPulse: Double

    private let dropCount = 56
    private let fallDuration: Double = 9.0

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate

            Canvas { ctx, size in
                for i in 0..<dropCount {
                    let offset = Double(i) / Double(dropCount)
                    let phase = (t / fallDuration + offset).truncatingRemainder(dividingBy: 1.0)

                    let anchorX = Double(i) * 0.3819 + 0.07
                    let wrapX = anchorX.truncatingRemainder(dividingBy: 1.0)
                    let sway = sin(t * 0.2 + Double(i) * 0.9) * 0.02
                    let x = (wrapX + sway) * size.width

                    // Top → bottom with gentle easing at the ends.
                    let y = size.height * phase

                    var alpha: Double = 1.0
                    if phase < 0.10 { alpha = phase / 0.10 }
                    else if phase > 0.90 { alpha = (1.0 - phase) / 0.10 }

                    // Droplets are elongated ellipses — taller than wide.
                    let w: CGFloat = 12 + CGFloat(i % 4) * 3
                    let h: CGFloat = 54 + CGFloat(i % 5) * 18
                    let rect = CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)

                    let hue = 0.66 + 0.04 * sin(Double(i) + t * 0.02)
                    let fill = Color(hue: hue, saturation: 0.70, brightness: 0.95)
                    ctx.fill(
                        Path(ellipseIn: rect),
                        with: .color(fill.opacity(alpha * 0.65 * weight))
                    )
                }
            }
            .blur(radius: 4)
            .blendMode(.plusLighter)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Previews

#Preview("Euphoric") {
    ZStack {
        Color.black.ignoresSafeArea()
        QuadrantBiomeLayer(
            weights: BiomeWeights(euphoric: 1, serene: 0, intense: 0, melancholic: 0),
            beatPulse: 0.4
        )
    }
}

#Preview("Serene") {
    ZStack {
        Color.black.ignoresSafeArea()
        QuadrantBiomeLayer(
            weights: BiomeWeights(euphoric: 0, serene: 1, intense: 0, melancholic: 0),
            beatPulse: 0.2
        )
    }
}

#Preview("Intense") {
    ZStack {
        Color.black.ignoresSafeArea()
        QuadrantBiomeLayer(
            weights: BiomeWeights(euphoric: 0, serene: 0, intense: 1, melancholic: 0),
            beatPulse: 0.6
        )
    }
}

#Preview("Melancholic") {
    ZStack {
        Color.black.ignoresSafeArea()
        QuadrantBiomeLayer(
            weights: BiomeWeights(euphoric: 0, serene: 0, intense: 0, melancholic: 1),
            beatPulse: 0.1
        )
    }
}

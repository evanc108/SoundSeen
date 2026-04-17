//
//  EnergySkyline.swift
//  SoundSeen
//
//  A horizon-like preview of the next ~20s of the track's energy envelope.
//  Renders frames.energy sampled over a sliding window [now, now + 20s] as
//  a smoothed mountain silhouette. The cursor (now) sits at x=0 and the
//  future extends rightward, so a rising skyline means a buildup is coming.
//  Reads beautifully alongside the section timeline above it: the section
//  labels tell you *what* is coming (verse / chorus / drop), the skyline
//  shows *how loud* it will be.
//

import SwiftUI

struct EnergySkyline: View {
    let analysis: SongAnalysis
    let currentTime: Double
    let paletteColor: Color
    var windowSeconds: Double = 20.0

    /// Number of sample points used to draw the silhouette. Downsampled from
    /// the raw frame resolution (~23ms → ~860 frames per 20s window), which
    /// would be far more detail than the strip height can resolve and would
    /// also stress the Canvas path with micro-segments.
    private let sampleCount = 80

    var body: some View {
        GeometryReader { proxy in
            Canvas { ctx, size in
                let samples = sampleEnergy(width: size.width)
                guard !samples.isEmpty else { return }
                drawSilhouette(ctx: &ctx, size: size, samples: samples)
                drawCursor(ctx: &ctx, size: size)
                drawRightEdgeFade(ctx: &ctx, size: size)
            }
        }
        .frame(height: 54)
        .allowsHitTesting(false)
    }

    // MARK: - Sampling

    private func sampleEnergy(width: CGFloat) -> [CGPoint] {
        let frames = analysis.frames
        guard frames.count > 0, frames.frameDurationMs > 0 else { return [] }
        let energies = frames.energy
        guard !energies.isEmpty else { return [] }

        var points: [CGPoint] = []
        points.reserveCapacity(sampleCount)

        for i in 0..<sampleCount {
            let t = currentTime + windowSeconds * Double(i) / Double(sampleCount - 1)
            let idx = min(energies.count - 1, max(0, Int(t * 1000.0 / frames.frameDurationMs)))
            let energy = energies[idx]
            let x = width * CGFloat(i) / CGFloat(sampleCount - 1)
            // Energy values can exceed 1.0 on hot transients; clamp so the
            // silhouette never overflows the strip.
            let clamped = max(0.0, min(1.0, energy))
            points.append(CGPoint(x: x, y: CGFloat(clamped)))
        }
        return points
    }

    // MARK: - Drawing

    private func drawSilhouette(
        ctx: inout GraphicsContext,
        size: CGSize,
        samples: [CGPoint]
    ) {
        let bottomY = size.height - 2
        let topY: CGFloat = 4
        let usableH = bottomY - topY

        func screenY(_ normEnergy: CGFloat) -> CGFloat {
            // 1.0 → topY, 0.0 → bottomY.
            bottomY - normEnergy * usableH
        }

        // Build a smooth closed path for the fill.
        var fillPath = Path()
        fillPath.move(to: CGPoint(x: 0, y: bottomY))
        fillPath.addLine(to: CGPoint(x: samples[0].x, y: screenY(samples[0].y)))
        for i in 1..<samples.count {
            let prev = samples[i - 1]
            let cur = samples[i]
            let midX = (prev.x + cur.x) / 2
            let prevY = screenY(prev.y)
            let curY = screenY(cur.y)
            fillPath.addQuadCurve(
                to: CGPoint(x: cur.x, y: curY),
                control: CGPoint(x: midX, y: (prevY + curY) / 2)
            )
        }
        fillPath.addLine(to: CGPoint(x: samples.last!.x, y: bottomY))
        fillPath.closeSubpath()

        ctx.fill(
            fillPath,
            with: .linearGradient(
                Gradient(colors: [
                    paletteColor.opacity(0.18),
                    paletteColor.opacity(0.48),
                ]),
                startPoint: CGPoint(x: 0, y: topY),
                endPoint: CGPoint(x: 0, y: bottomY)
            )
        )

        // Stroke on top — just the outline, so the horizon is crisp.
        var strokePath = Path()
        strokePath.move(to: CGPoint(x: samples[0].x, y: screenY(samples[0].y)))
        for i in 1..<samples.count {
            let prev = samples[i - 1]
            let cur = samples[i]
            let midX = (prev.x + cur.x) / 2
            let prevY = screenY(prev.y)
            let curY = screenY(cur.y)
            strokePath.addQuadCurve(
                to: CGPoint(x: cur.x, y: curY),
                control: CGPoint(x: midX, y: (prevY + curY) / 2)
            )
        }
        ctx.stroke(
            strokePath,
            with: .color(paletteColor.opacity(0.85)),
            style: StrokeStyle(lineWidth: 1.6, lineJoin: .round)
        )
    }

    private func drawCursor(ctx: inout GraphicsContext, size: CGSize) {
        var cursor = Path()
        cursor.move(to: CGPoint(x: 0.5, y: 0))
        cursor.addLine(to: CGPoint(x: 0.5, y: size.height))
        ctx.stroke(
            cursor,
            with: .color(.white.opacity(0.85)),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
        )
    }

    private func drawRightEdgeFade(ctx: inout GraphicsContext, size: CGSize) {
        // Fade the rightmost 20% so the horizon doesn't read as clipped —
        // it suggests "more song beyond" rather than a hard end. Drawn last
        // so it sits over the silhouette.
        let fadeWidth = size.width * 0.20
        let fadeRect = CGRect(
            x: size.width - fadeWidth,
            y: 0,
            width: fadeWidth,
            height: size.height
        )
        ctx.fill(
            Path(fadeRect),
            with: .linearGradient(
                Gradient(colors: [.black.opacity(0), .black.opacity(0.55)]),
                startPoint: CGPoint(x: size.width - fadeWidth, y: 0),
                endPoint: CGPoint(x: size.width, y: 0)
            )
        )
    }
}

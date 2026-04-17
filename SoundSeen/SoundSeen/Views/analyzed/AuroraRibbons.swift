//
//  AuroraRibbons.swift
//  SoundSeen
//
//  Three Bezier ribbons sweeping diagonally across the screen, warped by a
//  cheap superimposed-sine noise field. Each ribbon has its own slowly
//  drifting phase / frequency so the three never collide on the same shape
//  twice — the effect is an always-alive aurora flow that fills the area
//  behind the cymatic center and frames the entire view, not just the
//  middle. Colors come from the palette so the ribbons track the song's
//  current emotion + chroma alongside everything else.
//

import SwiftUI

struct AuroraRibbons: View {
    let visualizer: VisualizerState
    let paletteColor: Color
    let paletteSecondary: Color

    private let ribbonCount = 3
    private let samplesPerRibbon = 120

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = max(0, min(1, visualizer.beatPulse))
            let energy = max(0, min(1, visualizer.currentEnergy))
            let arousal = max(0, min(1, visualizer.smoothedArousal))

            Canvas { ctx, size in
                for r in 0..<ribbonCount {
                    drawRibbon(
                        ctx: &ctx,
                        size: size,
                        index: r,
                        time: t,
                        pulse: pulse,
                        energy: energy,
                        arousal: arousal
                    )
                }
            }
            .blendMode(.plusLighter)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Ribbon generator

    private func drawRibbon(
        ctx: inout GraphicsContext,
        size: CGSize,
        index: Int,
        time: Double,
        pulse: Double,
        energy: Double,
        arousal: Double
    ) {
        let w = size.width
        let h = size.height

        // Each ribbon has a unique diagonal slope + vertical anchor so the
        // three don't stack on top of each other. Phase offsets keep their
        // noise patterns out of phase.
        let anchorY: Double
        let slope: Double
        let phaseOffset: Double
        let hue: Color
        switch index {
        case 0:
            anchorY = Double(h) * 0.25
            slope = 0.15 * Double(h)
            phaseOffset = 0.0
            hue = paletteColor
        case 1:
            anchorY = Double(h) * 0.55
            slope = -0.22 * Double(h)
            phaseOffset = 1.7
            hue = paletteSecondary
        default:
            anchorY = Double(h) * 0.78
            slope = 0.18 * Double(h)
            phaseOffset = 3.1
            hue = paletteColor
        }

        // Arousal accelerates noise advection — tense tracks feel more
        // agitated, serene tracks drift slowly.
        let flowRate = 0.15 + arousal * 0.45
        let advect = time * flowRate + phaseOffset

        // Build the centerline of the ribbon.
        var centerline: [CGPoint] = []
        centerline.reserveCapacity(samplesPerRibbon + 1)
        for i in 0...samplesPerRibbon {
            let u = Double(i) / Double(samplesPerRibbon)
            let x = u * Double(w)
            // Diagonal baseline + layered sine noise.
            let baseY = anchorY + slope * u
            let n1 = sin(u * 6.28 * 0.9 + advect * 1.1) * 28
            let n2 = sin(u * 6.28 * 2.3 - advect * 0.7) * 14
            let n3 = sin(u * 6.28 * 5.1 + advect * 1.6) * 6
            // Beat kick displaces the ribbon vertically for a split second.
            let kick = sin(u * 6.28 * 1.4 + advect) * 18 * pulse
            let y = baseY + n1 + n2 + n3 + kick
            centerline.append(CGPoint(x: x, y: y))
        }

        // Ribbon width breathes with energy + beat, falls off at the ends
        // so the ribbon reads as a comet, not a slab.
        let maxWidth = 80.0 + 40.0 * energy + 30.0 * pulse

        // Build a closed path from the offset curves above and below the
        // centerline. Offset direction = normal to the line segment.
        var path = Path()
        var topPoints: [CGPoint] = []
        var bottomPoints: [CGPoint] = []
        topPoints.reserveCapacity(centerline.count)
        bottomPoints.reserveCapacity(centerline.count)
        for i in 0..<centerline.count {
            let p = centerline[i]
            let prev = centerline[max(0, i - 1)]
            let next = centerline[min(centerline.count - 1, i + 1)]
            let dx = next.x - prev.x
            let dy = next.y - prev.y
            let len = max(0.001, hypot(dx, dy))
            // Normal (rotated 90°, normalized).
            let nx = CGFloat(-dy / len)
            let ny = CGFloat(dx / len)
            // Taper: width goes to zero at u=0 and u=1, peak in the middle.
            let u = Double(i) / Double(centerline.count - 1)
            let taper = sin(u * .pi)
            let halfW = CGFloat(maxWidth * taper * 0.5)
            topPoints.append(CGPoint(x: p.x + nx * halfW, y: p.y + ny * halfW))
            bottomPoints.append(CGPoint(x: p.x - nx * halfW, y: p.y - ny * halfW))
        }

        // Close top edge.
        path.move(to: topPoints.first!)
        for i in 1..<topPoints.count {
            path.addLine(to: topPoints[i])
        }
        // Close bottom edge going back.
        for i in stride(from: bottomPoints.count - 1, through: 0, by: -1) {
            path.addLine(to: bottomPoints[i])
        }
        path.closeSubpath()

        ctx.fill(
            path,
            with: .linearGradient(
                Gradient(colors: [
                    hue.opacity(0.0),
                    hue.opacity(0.55),
                    hue.opacity(0.0),
                ]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: w, y: 0)
            )
        )
    }
}

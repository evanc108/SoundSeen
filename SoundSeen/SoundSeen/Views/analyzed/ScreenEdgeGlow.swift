//
//  ScreenEdgeGlow.swift
//  SoundSeen
//
//  Peripheral decoration: four edge-aligned glow bands that pulse with the
//  beat + overall energy, plus four corner radial blobs each tied to a
//  frequency band group (low / low-mid / high-mid / high). The corners
//  let you see the spectrum distribution spatially — when the bass hits,
//  the top-left lights up; when the hats / cymbals come in, the bottom-right
//  brightens. The edge bands frame the whole scene so the content never
//  feels like it's just floating in the middle.
//

import SwiftUI

struct ScreenEdgeGlow: View {
    let visualizer: VisualizerState
    let paletteColor: Color
    let paletteSecondary: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
            let pulse = max(0, min(1, visualizer.beatPulse))
            let energy = max(0, min(1, visualizer.currentEnergy))
            let bands = visualizer.currentBands

            // Group the 8 log-spaced bands into 4 band groups, one per corner.
            let low     = bandAverage(bands, range: 0..<2)
            let lowMid  = bandAverage(bands, range: 2..<4)
            let highMid = bandAverage(bands, range: 4..<6)
            let high    = bandAverage(bands, range: 6..<8)

            ZStack {
                edgeGlows(energy: energy, pulse: pulse)
                cornerGlows(low: low, lowMid: lowMid, highMid: highMid, high: high)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    // MARK: - Edge glows

    private func edgeGlows(energy: Double, pulse: Double) -> some View {
        // Strength combines a steady energy floor with a sharp beat kick.
        // The floor gives the edges a presence even during quiet passages;
        // the kick gives each beat a visible "ping" around the frame.
        let strength = 0.30 + 0.25 * energy + 0.45 * pulse
        return ZStack {
            // Top edge
            LinearGradient(
                colors: [paletteColor.opacity(0.55 * strength), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(maxWidth: .infinity, maxHeight: 140)
            .frame(maxHeight: .infinity, alignment: .top)

            // Bottom edge
            LinearGradient(
                colors: [.clear, paletteColor.opacity(0.55 * strength)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(maxWidth: .infinity, maxHeight: 140)
            .frame(maxHeight: .infinity, alignment: .bottom)

            // Left edge
            LinearGradient(
                colors: [paletteSecondary.opacity(0.45 * strength), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(maxWidth: 90, maxHeight: .infinity)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right edge
            LinearGradient(
                colors: [.clear, paletteSecondary.opacity(0.45 * strength)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(maxWidth: 90, maxHeight: .infinity)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .blendMode(.plusLighter)
    }

    // MARK: - Corner band blobs

    private func cornerGlows(
        low: Double,
        lowMid: Double,
        highMid: Double,
        high: Double
    ) -> some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let radius = min(w, h) * 0.55
            // Top corners use primary palette, bottom use secondary — gives
            // a gentle two-tone diversity without fighting the scene color.
            ZStack {
                cornerBlob(center: CGPoint(x: 0, y: 0), radius: radius, color: paletteColor, energy: low)
                cornerBlob(center: CGPoint(x: w, y: 0), radius: radius, color: paletteColor, energy: lowMid)
                cornerBlob(center: CGPoint(x: 0, y: h), radius: radius, color: paletteSecondary, energy: highMid)
                cornerBlob(center: CGPoint(x: w, y: h), radius: radius, color: paletteSecondary, energy: high)
            }
            .blendMode(.plusLighter)
        }
    }

    private func cornerBlob(
        center: CGPoint,
        radius: CGFloat,
        color: Color,
        energy: Double
    ) -> some View {
        let strength = max(0.0, min(1.0, energy))
        return Circle()
            .fill(
                RadialGradient(
                    colors: [
                        color.opacity(0.55 * strength),
                        color.opacity(0.18 * strength),
                        .clear,
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: radius
                )
            )
            .frame(width: radius * 2, height: radius * 2)
            .position(center)
    }

    // MARK: - Helpers

    private func bandAverage(_ bands: [Double], range: Range<Int>) -> Double {
        let valid = range.clamped(to: 0..<bands.count)
        guard !valid.isEmpty else { return 0 }
        var sum = 0.0
        for i in valid { sum += bands[i] }
        return sum / Double(valid.count)
    }
}

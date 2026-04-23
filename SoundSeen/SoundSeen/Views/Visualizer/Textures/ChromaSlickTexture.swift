//
//  ChromaSlickTexture.swift
//  SoundSeen
//
//  Iridescent thin-film wash on the PERIMETER. Appears only when
//  currentChromaStrength > 0.2. Reads as "the world is tinted with the
//  song's key right now"; disappears during atonal passages so deaf
//  users see harmonic/atonal boundaries directly on the screen frame.
//
//  Round 3: the 3-stop triad was replaced with a true 12-stop per-pitch-
//  class conic gradient sampled from `currentChromaVector`. Each pitch
//  class that's active contributes its own hue stop weighted by its
//  chroma magnitude — a C chord paints C/E/G prominently; a tritone
//  paints two hot spots on opposite arcs. Keys modulate = gradient
//  reshapes.
//

import SwiftUI

struct ChromaSlickTexture: View {
    @Bindable var state: VisualizerState
    let dialect: SectionDialect
    let now: Date

    var body: some View {
        if dialect.enabledTextures.contains(.chromaSlick) {
            let cs = state.currentChromaStrength
            if cs > 0.2 {
                GeometryReader { geo in
                    let size = geo.size
                    let baseAlpha = min(0.45, (cs - 0.2) * 1.5)
                    let t = now.timeIntervalSinceReferenceDate
                    let rotationRate = 0.02 * (1 + cs)
                    let rotation = Angle.radians(t * 2 * .pi * rotationRate)

                    // Build 12 stops — one per pitch class. Each stop's
                    // alpha is scaled by the chroma[i] value so active
                    // pitches read, inactive ones fade. Fall back to a
                    // flat triad when the vector is empty (old cached
                    // analyses without per-frame chroma data).
                    let vec = state.currentChromaVector
                    let stops = buildStops(vector: vec, baseAlpha: baseAlpha)

                    let gradient = AngularGradient(
                        gradient: Gradient(stops: stops),
                        center: .center,
                        angle: rotation
                    )

                    // Mask: ring only. 12% of the shorter edge, blurred.
                    let thickness = min(size.width, size.height) * 0.12

                    Rectangle()
                        .fill(gradient)
                        .mask(
                            Rectangle()
                                .strokeBorder(Color.white, lineWidth: thickness)
                                .blur(radius: thickness * 0.35)
                        )
                        .blendMode(.overlay)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// Build 12 conic gradient stops from a chroma vector. If the vector
    /// is empty or looks degenerate, fall back to a simple triad using
    /// `currentHue` so old analyses without chroma data still render.
    private func buildStops(vector: [Double], baseAlpha: Double) -> [Gradient.Stop] {
        let usable = vector.count == 12 && vector.contains(where: { $0 > 0.01 })
        if !usable {
            let hue = state.currentHue
            let c0 = HSB(h: hue, s: 0.7, b: 1.0).color(opacity: baseAlpha)
            let c1 = HSB(h: hue + 0.33, s: 0.7, b: 1.0).color(opacity: baseAlpha)
            let c2 = HSB(h: hue + 0.66, s: 0.7, b: 1.0).color(opacity: baseAlpha)
            return [
                .init(color: c0, location: 0.00),
                .init(color: c1, location: 0.33),
                .init(color: c2, location: 0.66),
                .init(color: c0, location: 1.00)
            ]
        }

        // Normalize so the brightest pitch class hits full alpha; keeps
        // the gradient visible even when overall chroma is modest.
        let peak = max(0.25, vector.max() ?? 1)

        var stops: [Gradient.Stop] = []
        stops.reserveCapacity(13)
        for i in 0..<12 {
            let weight = min(1.0, vector[i] / peak)
            let hue = Double(i) / 12.0
            let color = HSB(h: hue, s: 0.75, b: 1.0).color(opacity: baseAlpha * weight)
            stops.append(.init(color: color, location: Double(i) / 12.0))
        }
        // Close the loop back to the first stop so the conic gradient
        // doesn't seam visibly at the top.
        stops.append(.init(color: stops[0].color, location: 1.0))
        return stops
    }
}

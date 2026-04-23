//
//  ValenceGradientTexture.swift
//  SoundSeen
//
//  Diagonal corner blooms driven by smoothedValence × smoothedArousal.
//  Happy songs light the warm diagonal (top-left + bottom-right); sad
//  songs light the cool diagonal (top-right + bottom-left). Arousal
//  controls gradient radius and overall alpha.
//
//  Deaf users read the diagonal lean as the song's emotional temperature
//  — a persistent compositional bias, not a motion event.
//

import SwiftUI

struct ValenceGradientTexture: View {
    @Bindable var state: VisualizerState
    let dialect: SectionDialect

    // Fixed warm/cool reference hues. Warm: amber ~0.08 (hue space).
    // Cool: cyan ~0.55.
    private let warmHSB = HSB(h: 0.08, s: 0.85, b: 1.00)
    private let coolHSB = HSB(h: 0.55, s: 0.70, b: 0.95)

    var body: some View {
        if dialect.enabledTextures.contains(.valenceGradient) {
            GeometryReader { geo in
                let size = geo.size
                let minDim = min(size.width, size.height)

                let val = state.smoothedValence
                let ar = state.smoothedArousal

                // Weighting: V > 0.5 → warm alpha rises; V < 0.5 → cool
                // alpha rises. Both scaled by arousal.
                let warmAlpha = val * ar * 0.45
                let coolAlpha = (1 - val) * ar * 0.45
                let radius = minDim * CGFloat(0.10 + 0.15 * ar)

                ZStack {
                    // Warm diagonal: top-left + bottom-right.
                    cornerBloom(size: size, anchor: .topLeading, radius: radius,
                                color: warmHSB, alpha: warmAlpha)
                    cornerBloom(size: size, anchor: .bottomTrailing, radius: radius,
                                color: warmHSB, alpha: warmAlpha)
                    // Cool diagonal: top-right + bottom-left.
                    cornerBloom(size: size, anchor: .topTrailing, radius: radius,
                                color: coolHSB, alpha: coolAlpha)
                    cornerBloom(size: size, anchor: .bottomLeading, radius: radius,
                                color: coolHSB, alpha: coolAlpha)
                }
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
            }
        }
    }

    private func cornerBloom(
        size: CGSize,
        anchor: UnitPoint,
        radius: CGFloat,
        color: HSB,
        alpha: Double
    ) -> some View {
        // Convert UnitPoint to a pixel position. Anchor becomes the brightest
        // point of the radial gradient.
        let x = size.width * anchor.x
        let y = size.height * anchor.y
        let diameter = radius * 2

        return RadialGradient(
            gradient: Gradient(colors: [
                color.color(opacity: alpha),
                color.color(opacity: 0)
            ]),
            center: .center,
            startRadius: 0,
            endRadius: radius
        )
        .frame(width: diameter, height: diameter)
        .position(x: x, y: y)
    }
}

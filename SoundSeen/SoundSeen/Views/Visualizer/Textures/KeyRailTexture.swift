//
//  KeyRailTexture.swift
//  SoundSeen
//
//  Compact key compass in the bottom-left corner. 12 pitch-class color
//  stops always visible at low alpha; the stop nearest currentHue·12
//  lights up. Demoted from the full-gutter rail — this is a glance
//  indicator, not scene chrome.
//
//  Gives deaf users a *persistent readable indicator* of the key rather
//  than only a tinted scene. "The song is in F# right now" is legible at
//  a glance, but the compass no longer competes with the emotion shapes
//  for visual attention.
//

import SwiftUI

struct KeyRailTexture: View {
    @Bindable var state: VisualizerState
    let dialect: SectionDialect

    var body: some View {
        if dialect.enabledTextures.contains(.keyRail) {
            GeometryReader { geo in
                let size = geo.size
                let cs = state.currentChromaStrength
                let hue = state.currentHue

                // Hide when atonal — signal is just noise.
                guard cs > 0.05 else { return AnyView(EmptyView()) }

                // Compass geometry: 60% reduction from the old full-rail form.
                // Anchored in the bottom-left, height ~16% of viewport.
                let barX = size.width * 0.04
                let barTop = size.height * 0.74
                let barBot = size.height * 0.90
                let barH = barBot - barTop
                let barW: CGFloat = 12

                // 12 pitch-class hues evenly distributed around color wheel.
                // Alpha dropped ~40% from the old rail — this is ambient,
                // not primary.
                let stops: [Gradient.Stop] = (0..<12).map { i in
                    let h = Double(i) / 12.0
                    let s = 0.65 + 0.20 * cs
                    let b = 0.80
                    return .init(
                        color: HSB(h: h, s: s, b: b).color(opacity: 0.17 + 0.07 * cs),
                        location: Double(i) / 11.0
                    )
                }
                let gradient = LinearGradient(
                    gradient: Gradient(stops: stops),
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Active marker: centered on the v corresponding to current hue.
                let markerY = barTop + CGFloat(hue) * barH
                let markerColor = HSB(h: hue, s: 0.9, b: 1.0)

                return AnyView(
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(gradient)
                            .frame(width: barW, height: barH)
                            .position(x: barX, y: (barTop + barBot) / 2)
                            .blur(radius: 4)
                            .blendMode(.plusLighter)

                        // Active-stop glow — brightens the current pitch class.
                        Circle()
                            .fill(
                                RadialGradient(
                                    gradient: Gradient(colors: [
                                        markerColor.color(opacity: 0.34 + 0.15 * cs),
                                        markerColor.color(opacity: 0)
                                    ]),
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: 12
                                )
                            )
                            .frame(width: 24, height: 24)
                            .position(x: barX, y: markerY)
                            .blendMode(.plusLighter)
                    }
                    .allowsHitTesting(false)
                )
            }
        }
    }
}

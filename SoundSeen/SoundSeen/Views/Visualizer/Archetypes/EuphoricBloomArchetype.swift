//
//  EuphoricBloomArchetype.swift
//  SoundSeen
//
//  High-V, high-A protagonist form — a radial flower bloom. Petals count
//  rises with harmonic ratio (6 when noisy, 12 when tonal), scale thumps
//  with beatPulse, hue pulls toward scheme.accent + key. Designed to
//  carry the "excitement" reading that LightRayTexture used to emit at
//  high arousal, but as a *shape*, not a beam rack.
//
//  Petals are drawn as elongated teardrops filled with a radial gradient
//  that's hottest at the tip. The whole bloom rotates slowly so it reads
//  as alive rather than stamped.
//

import SwiftUI

struct EuphoricBloomArchetype: View {
    @Bindable var state: VisualizerState
    /// Biome weight in [0, 1]. Multiplied into alpha; archetype early-outs
    /// below Archetype.minWeight so the four-way cross-fade is free.
    let weight: Double
    let scheme: EmotionScheme
    let dialect: SectionDialect
    let now: Date

    var body: some View {
        if weight > Archetype.minWeight {
            Canvas { ctx, size in
                draw(ctx: &ctx, size: size)
            }
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        }
    }

    private func draw(ctx: inout GraphicsContext, size: CGSize) {
        let t = now.timeIntervalSinceReferenceDate

        // Petal count — tonal passages bloom full, noisy ones show fewer
        // petals so the form dissolves toward shards instead of a flower.
        let hr = state.currentHarmonicRatio
        let petalCount = max(6, min(12, 6 + Int((hr * 6).rounded())))

        // Bloom center drifts in a small Lissajous so the flower feels
        // rooted but alive. Stays inside the central viewing zone.
        let cx = size.width * (0.5 + 0.04 * sin(t * 0.11))
        let cy = size.height * (0.52 + 0.03 * cos(t * 0.17))

        // Radius breathes on the beat. baseRadius scales with smoothed
        // arousal so excited passages bloom wider than simmering ones.
        let arousal = state.smoothedArousal
        let shortEdge = min(size.width, size.height)
        let baseRadius = shortEdge * (0.18 + 0.10 * arousal)
        let beatSwell = 1.0 + state.beatPulse * 0.22
        let radius = baseRadius * beatSwell

        // Slow rotation so the bloom doesn't feel stamped.
        let rotation = t * 0.08

        // Color: primary body, accent-hot tip, pulled slightly toward
        // key color on tonal passages so the bloom reads musical.
        let cs = state.currentChromaStrength
        let keyHSB = HSB(h: state.currentHue, s: 0.85, b: 1.0)
        let body: HSB = cs > 0.4
            ? archetypeBlend(scheme.primary, keyHSB, 0.25)
            : scheme.primary
        let tip: HSB = cs > 0.4
            ? archetypeBlend(scheme.accent, keyHSB, 0.20)
            : scheme.accent

        // Alpha: weight-scaled with a gentle boost from energy so louder
        // passages bloom brighter than quiet ones within the same biome.
        let energyBoost = 0.55 + 0.45 * state.currentEnergy
        let baseAlpha = weight * energyBoost

        // Petal width rides MFCC[1] — a proxy for spectral brightness.
        // Warm/dark timbre (low MFCC[1]) → wider, rounder petals; bright
        // timbre → narrower, sharper petals.
        let mfcc1 = state.currentMFCC.count > 1 ? state.currentMFCC[1] : 0.5
        let widthScale = 0.22 + 0.22 * (1 - mfcc1)

        for i in 0..<petalCount {
            let angle = rotation + Double(i) * (2 * .pi / Double(petalCount))
            drawPetal(
                ctx: &ctx,
                center: CGPoint(x: cx, y: cy),
                angle: angle,
                length: radius,
                width: radius * widthScale,
                bodyColor: body,
                tipColor: tip,
                alpha: baseAlpha
            )
        }

        // Inner core disc — anchors the bloom and picks up most beat swell.
        let coreColor = tip.color(opacity: baseAlpha * 0.55)
        let coreR = radius * 0.18 * beatSwell
        var coreCtx = ctx
        coreCtx.addFilter(.blur(radius: 6))
        coreCtx.fill(
            Path(ellipseIn: CGRect(
                x: cx - coreR, y: cy - coreR,
                width: coreR * 2, height: coreR * 2
            )),
            with: .color(coreColor)
        )
    }

    /// A teardrop petal: wide near the center, tapering outward. Filled
    /// with a radial gradient so the tip reads as the hot edge.
    private func drawPetal(
        ctx: inout GraphicsContext,
        center: CGPoint,
        angle: Double,
        length: Double,
        width: Double,
        bodyColor: HSB,
        tipColor: HSB,
        alpha: Double
    ) {
        let cosA = cos(angle)
        let sinA = sin(angle)
        let tip = CGPoint(
            x: center.x + cosA * length,
            y: center.y + sinA * length
        )
        // Side control points offset perpendicular to the petal axis.
        let perpX = -sinA * width
        let perpY = cosA * width
        let midR = length * 0.45
        let mid = CGPoint(
            x: center.x + cosA * midR,
            y: center.y + sinA * midR
        )
        let left = CGPoint(x: mid.x + perpX, y: mid.y + perpY)
        let right = CGPoint(x: mid.x - perpX, y: mid.y - perpY)

        var path = Path()
        path.move(to: center)
        path.addQuadCurve(to: tip, control: left)
        path.addQuadCurve(to: center, control: right)
        path.closeSubpath()

        // Radial gradient from body at base → tip color at end.
        let gradient = Gradient(colors: [
            bodyColor.color(opacity: alpha * 0.55),
            tipColor.color(opacity: alpha * 0.85),
            tipColor.color(opacity: 0)
        ])
        var petalCtx = ctx
        petalCtx.addFilter(.blur(radius: 3))
        petalCtx.fill(
            path,
            with: .radialGradient(
                gradient,
                center: center,
                startRadius: 0,
                endRadius: CGFloat(length)
            )
        )
    }
}

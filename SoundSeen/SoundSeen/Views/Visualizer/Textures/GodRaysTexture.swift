//
//  GodRaysTexture.swift
//  SoundSeen
//
//  Klsr-inspired cinematic god-rays. Layered soft radial light emanating
//  from a source slightly above center. Each shaft is a chain of blurred
//  ellipses along a radial direction, creating volumetric depth.
//
//  Emotional couplings:
//    - Bass drives brightness (hi-hats ignored via beat*bass gating).
//    - Snare bloom fires an accent-colored radial flash (300ms decay).
//    - Section build slowly extends and brightens shafts (2-3s ramp).
//    - Valence controls shaft count and spread (tight vs diffuse).
//    - Scene breathes in silence: faint haze + slow drift always present.
//

import SwiftUI

struct GodRaysTexture: View {
    @Bindable var state: VisualizerState
    let scheme: EmotionScheme
    let dialect: SectionDialect
    let now: Date

    private let lightCenter = CGPoint(x: 0.5, y: 0.35)

    var body: some View {
        if dialect.enabledTextures.contains(.godRays) {
            Canvas { ctx, size in
                draw(ctx: &ctx, size: size)
            }
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        }
    }

    private func draw(ctx: inout GraphicsContext, size: CGSize) {
        let t = now.timeIntervalSinceReferenceDate
        let w = size.width
        let h = size.height
        let minDim = min(w, h)

        // --- Signals ---
        let bass = state.bassEnergySmoothed
        let bassMasked = bass * (dialect.bandMask.count > 1
            ? (dialect.bandMask[0] + dialect.bandMask[1]) * 0.5
            : 1.0)
        let beat = state.beatPulse
        let snareBloom = state.snareBloomEnvelope
        let sectionBuild = state.sectionBuildEnvelope
        let valence = state.smoothedValence

        // Brightness: plan-doc formula with bass gating on beats.
        let brightness = min(1.5, 0.15
            + 0.55 * bassMasked
            + 0.20 * beat * bassMasked
            + 0.60 * snareBloom
            + 0.30 * sectionBuild)

        // Light source with slow organic drift.
        let cx = w * (lightCenter.x + 0.025 * sin(t * 0.06))
        let cy = h * (lightCenter.y + 0.018 * cos(t * 0.045))

        // Color: pull toward song's key when tonal.
        let cs = state.currentChromaStrength
        let keyHSB = HSB(h: state.currentHue, s: 0.6, b: 0.9)
        let shaftColor = blend2(scheme.primary, keyHSB, min(1.0, cs * 0.35))
        let hazeColor = blend2(scheme.atmosphere, keyHSB, min(1.0, cs * 0.2))

        // --- 1. Deep atmospheric haze ---
        let hazeRadius = minDim * (0.70 + 0.20 * sectionBuild)
        let hazeAlpha = brightness * 0.35
        drawGlow(
            ctx: &ctx,
            center: CGPoint(x: cx, y: cy),
            radius: hazeRadius,
            color: hazeColor,
            alpha: hazeAlpha,
            blur: 60
        )

        // --- 2. Light shafts ---
        // Each shaft = a chain of 3 blurred ellipses along a radial direction,
        // fading from bright near the source to transparent at the tip.
        let shaftCount = Int(5 + 3 * valence)
        let shaftReach = minDim * (0.45 + 0.30 * bassMasked + 0.20 * sectionBuild)

        for i in 0..<shaftCount {
            let fi = Double(i)
            // Golden-angle spacing for organic non-uniform distribution.
            let baseAngle = fi * 2.39996323 + t * 0.015
            let breathPhase = sin(t * 0.12 + fi * 1.7) * 0.12
            let angle = baseAngle + breathPhase

            let cosA = cos(angle)
            let sinA = sin(angle)

            // Per-shaft length variation — some reach further.
            let lengthVar = 0.7 + 0.3 * abs(sin(fi * 2.1 + t * 0.08))
            let thisReach = shaftReach * lengthVar

            // Width narrows with valence: tight/focused vs diffuse.
            let baseWidth = minDim * (0.06 + 0.08 * (1.0 - valence * 0.4))
            let widthVar = 0.8 + 0.4 * abs(sin(fi * 3.7 + t * 0.1))
            let thisWidth = baseWidth * widthVar

            // Draw 3 blob segments along the shaft direction, fading outward.
            let segments = 3
            for seg in 0..<segments {
                let segT = Double(seg + 1) / Double(segments + 1)
                let dist = thisReach * segT

                let blobCx = cx + cosA * dist
                let blobCy = cy + sinA * dist

                // Fade with distance from source.
                let distFade = 1.0 - segT * 0.7
                let segAlpha = brightness * 0.30 * distFade

                // Blobs further out are softer and wider.
                let segBlur = 22.0 + Double(seg) * 12.0
                let segWidth = thisWidth * (1.0 + Double(seg) * 0.3)
                let segLength = thisWidth * (2.0 + Double(seg) * 0.5)

                let blobRect = CGRect(
                    x: blobCx - segLength * 0.5,
                    y: blobCy - segWidth * 0.5,
                    width: segLength,
                    height: segWidth
                )

                var segCtx = ctx
                segCtx.addFilter(.blur(radius: segBlur))
                segCtx.fill(
                    Path(ellipseIn: blobRect),
                    with: .color(shaftColor.color(opacity: segAlpha))
                )
            }
        }

        // --- 3. Core glow ---
        let coreRadius = minDim * (0.15 + 0.12 * bassMasked)
        drawGlow(
            ctx: &ctx,
            center: CGPoint(x: cx, y: cy),
            radius: coreRadius,
            color: scheme.primary,
            alpha: brightness * 0.50,
            blur: 20
        )

        // --- 4. Snare bloom flash ---
        if snareBloom > 0.01 {
            let bloomRadius = minDim * (0.35 + 0.25 * snareBloom)
            drawGlow(
                ctx: &ctx,
                center: CGPoint(x: cx, y: cy),
                radius: bloomRadius,
                color: scheme.accent,
                alpha: snareBloom * 0.45,
                blur: 30
            )
        }

        // --- 5. Dust motes ---
        let arousal = state.smoothedArousal
        let dustCount = Int(6 + 18 * arousal)
        let dustBaseAlpha = 0.10 + 0.15 * bassMasked

        for j in 0..<dustCount {
            let seed = Double(j) * 137.508
            let dx = fract(sin(seed * 12.9898 + t * 0.018) * 43758.5453)
            let dy = fract(sin(seed * 78.233 + t * 0.012) * 43758.5453)

            let mx = w * dx
            let my = h * dy

            let distToLight = hypot(mx - cx, my - cy) / minDim
            let falloff = max(0, 1.0 - distToLight * 1.5)
            let moteAlpha = dustBaseAlpha * falloff * falloff

            guard moteAlpha > 0.005 else { continue }

            let moteSize = 2.0 + 3.0 * fract(seed * 0.618)
            let moteRect = CGRect(
                x: mx - moteSize, y: my - moteSize,
                width: moteSize * 2, height: moteSize * 2
            )

            var moteCtx = ctx
            moteCtx.addFilter(.blur(radius: 3))
            moteCtx.fill(
                Path(ellipseIn: moteRect),
                with: .color(scheme.secondary.color(opacity: moteAlpha))
            )
        }
    }

    // MARK: - Helpers

    private func drawGlow(
        ctx: inout GraphicsContext,
        center: CGPoint,
        radius: Double,
        color: HSB,
        alpha: Double,
        blur: CGFloat
    ) {
        let rect = CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        )
        var glowCtx = ctx
        glowCtx.addFilter(.blur(radius: blur))
        glowCtx.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: [
                    color.color(opacity: alpha),
                    color.color(opacity: alpha * 0.25),
                    Color.clear
                ]),
                center: center,
                startRadius: 0,
                endRadius: radius
            )
        )
    }

    private func fract(_ x: Double) -> Double {
        x - floor(x)
    }

    private func blend2(_ a: HSB, _ b: HSB, _ t: Double) -> HSB {
        var dh = b.h - a.h
        if dh > 0.5 { dh -= 1 }
        if dh < -0.5 { dh += 1 }
        var h = a.h + dh * t
        h = h.truncatingRemainder(dividingBy: 1); if h < 0 { h += 1 }
        return HSB(
            h: h,
            s: a.s + (b.s - a.s) * t,
            b: a.b + (b.b - a.b) * t
        )
    }
}

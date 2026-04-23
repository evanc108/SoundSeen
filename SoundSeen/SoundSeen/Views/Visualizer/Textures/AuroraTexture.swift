//
//  AuroraTexture.swift
//  SoundSeen
//
//  Horizontal ribbons of gaussian-soft blurred gradient flowing across
//  the SKY zone. Round 2 makes three dimensions dynamic:
//
//  - Ribbon count combines arousal + harmonic_ratio: harmonic richness
//    adds ribbons (layered tonal energy); noise suppresses them.
//  - Each ribbon's vertical anchor breathes (sinusoidal over ~10s) —
//    real aurora waves, static stripes do not.
//  - Color cycle speed scales with arousal: calm aurora drifts colors
//    slowly (~0.8×), high-arousal chorus paints quickly (~2.2×). The
//    cycle's current color is additionally pulled toward the song's
//    currentHue when chroma strength is high.
//

import SwiftUI

struct AuroraTexture: View {
    @Bindable var state: VisualizerState
    let scheme: EmotionScheme
    let dialect: SectionDialect
    let now: Date

    var body: some View {
        if dialect.enabledTextures.contains(.aurora) {
            Canvas { ctx, size in
                let brilliance = (state.currentBands.count > 6 ? state.currentBands[6] : 0) * dialect.bandMask[6]
                let presence   = (state.currentBands.count > 5 ? state.currentBands[5] : 0) * dialect.bandMask[5]
                let upperMid   = (state.currentBands.count > 4 ? state.currentBands[4] : 0) * dialect.bandMask[4]
                let sky = max(brilliance, presence * 0.8, upperMid * 0.6)
                guard sky > 0.06 else { return }

                // Ribbon count: A · 3 baseline + HR · 2 bonus, clamped 1..5.
                // Chorus (mirrorX) gets the full 5; other sections cap at 3.
                let arousal = state.smoothedArousal
                let harm = state.currentHarmonicRatio
                let raw = arousal * 3.0 + harm * 2.0
                let cap = dialect.mirrorX ? 5 : 3
                let ribbonCount = max(1, min(cap, Int(ceil(raw))))

                let t = now.timeIntervalSinceReferenceDate
                for i in 0..<ribbonCount {
                    drawRibbon(
                        ctx: &ctx, size: size,
                        index: i, total: ribbonCount,
                        t: t, sky: sky, arousal: arousal, harm: harm
                    )
                }
            }
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        }
    }

    private func drawRibbon(
        ctx: inout GraphicsContext,
        size: CGSize,
        index: Int,
        total: Int,
        t: Double,
        sky: Double,
        arousal: Double,
        harm: Double
    ) {
        // Base v: evenly space ribbons across SKY. Add a slow per-ribbon
        // breath so the ladder isn't rigid.
        let vBase: Double = {
            if total == 1 { return 0.18 }
            return 0.08 + Double(index) / Double(total - 1) * 0.20
        }()
        let vBreath = 0.03 * sin(t * 0.2 + Double(index) * 0.9)
        let vAnchor = vBase + vBreath
        let yBase = vAnchor * size.height

        // Amplitude gets an extra kick from noise (1 − HR) so noisy mids
        // add turbulence to the flow.
        let amp = size.height * (0.035 + 0.065 * arousal * sky + 0.03 * (1 - harm))
        let freq = 0.35 + 0.15 * Double(index)
        let phase = t * (0.22 + 0.08 * Double(index))

        let samples = 64
        var topPoints: [CGPoint] = []
        var botPoints: [CGPoint] = []
        topPoints.reserveCapacity(samples + 1)
        botPoints.reserveCapacity(samples + 1)
        let thickness = size.height * (0.05 + 0.06 * sky)
        for s in 0...samples {
            let x = size.width * Double(s) / Double(samples)
            let wave = sin((x / size.width) * 2 * .pi * freq + phase * 2 * .pi)
            let yCenter = yBase + CGFloat(wave) * amp
            topPoints.append(CGPoint(x: x, y: yCenter - thickness / 2))
            botPoints.append(CGPoint(x: x, y: yCenter + thickness / 2))
        }

        var ribbon = Path()
        if let firstTop = topPoints.first {
            ribbon.move(to: firstTop)
            for p in topPoints.dropFirst() { ribbon.addLine(to: p) }
            for p in botPoints.reversed() { ribbon.addLine(to: p) }
            ribbon.closeSubpath()
        }

        // Cycle speed scales with arousal. 0.8× when calm (period ~7.5s),
        // 2.2× at peak (period ~2.7s). Period = base / speedMult.
        let speedMult = 0.8 + arousal * 1.4
        let cyclePeriod: Double = 6.0 / speedMult
        let cycle = ((t / cyclePeriod) + Double(index) * 0.22).truncatingRemainder(dividingBy: 1)
        let schemeColor = interpolateSchemeCycle(scheme: scheme, phase: cycle)

        // Blend toward song's key when tonal.
        let cs = state.currentChromaStrength
        let keyHSB = HSB(h: state.currentHue, s: 0.8, b: 1.0)
        let color = blend2(schemeColor, keyHSB, min(1.0, cs * 0.4))

        let opacity = 0.18 + 0.40 * sky

        var ribbonCtx = ctx
        ribbonCtx.addFilter(.blur(radius: 18))
        ribbonCtx.fill(ribbon, with: .color(color.color(opacity: opacity)))
    }

    private func interpolateSchemeCycle(scheme: EmotionScheme, phase: Double) -> HSB {
        let stops: [HSB] = [scheme.primary, scheme.secondary, scheme.accent, scheme.primary]
        let segments = stops.count - 1
        let scaled = phase * Double(segments)
        let i = min(segments - 1, Int(scaled))
        let t = scaled - Double(i)
        return blend2(stops[i], stops[i + 1], t)
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

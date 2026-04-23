//
//  MelancholicDropletArchetype.swift
//  SoundSeen
//
//  Low-V, low-A protagonist form — slow falling droplets on a vertical
//  axis. Carries the somber/rainy/introspective read that the palette
//  alone can't convey. Droplets are few and slow; the form is legible
//  precisely because it *refuses* to be busy.
//
//  Each droplet is a persistent object with a phase that advances with
//  real time, so the fall is continuous rather than re-spawned per beat.
//  Horizontal drift is a slow sinusoid per droplet so they don't feel
//  like bullets on a grid.
//

import SwiftUI

private let dropletCount: Int = 5
/// Seconds for a droplet to traverse the viewport top → bottom at the
/// baseline fall rate. Slower than any real rain to read as emotion,
/// not weather.
private let baseFallPeriod: Double = 8.0

struct MelancholicDropletArchetype: View {
    @Bindable var state: VisualizerState
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

        // Energy modulates fall speed slightly so quiet passages drift
        // slower than driving ones, but the range is narrow — this is
        // mood, not weather.
        let energy = state.currentEnergy
        let period = baseFallPeriod / (1.0 + energy * 0.35)

        // Color stays close to the biome's own palette — melancholic primary
        // and secondary blend. No key-pulling: the droplet belongs to mood,
        // not to the note being played.
        let body = archetypeBlend(scheme.primary, scheme.secondary, 0.5)
        let highlight = scheme.accent

        // Weight drives overall brightness; minimal energy boost keeps
        // quiet introspective passages readable.
        let baseAlpha = weight * (0.55 + 0.25 * energy)

        let shortEdge = min(size.width, size.height)

        for i in 0..<dropletCount {
            // Phase per droplet is offset so they don't fall in unison.
            let phase = (t / period + Double(i) / Double(dropletCount))
                .truncatingRemainder(dividingBy: 1)

            // Horizontal lane per droplet, with slow sinusoidal drift so
            // the fall feels uncertain, not mechanical.
            let laneU = 0.20 + Double(i) * (0.60 / Double(dropletCount - 1))
            let drift = 0.03 * sin(t * 0.27 + Double(i) * 1.3)
            let u = laneU + drift

            // Vertical: phase 0 → top, phase 1 → bottom.
            let v = -0.05 + phase * 1.10

            let cx = u * size.width
            let cy = v * size.height
            let r = shortEdge * (0.022 + 0.008 * sin(t * 0.4 + Double(i)))

            // Fade at the edges so droplets don't pop in/out.
            let edgeFade: Double
            if phase < 0.06 {
                edgeFade = phase / 0.06
            } else if phase > 0.92 {
                edgeFade = (1.0 - phase) / 0.08
            } else {
                edgeFade = 1.0
            }

            drawDroplet(
                ctx: &ctx,
                center: CGPoint(x: cx, y: cy),
                radius: r,
                body: body,
                highlight: highlight,
                alpha: baseAlpha * max(0, edgeFade)
            )
        }
    }

    /// A teardrop glyph: a soft circle with a vertical tail trailing upward
    /// (the air the droplet just fell through). Drawn with a blur so it
    /// reads as mist rather than geometry.
    private func drawDroplet(
        ctx: inout GraphicsContext,
        center: CGPoint,
        radius: Double,
        body: HSB,
        highlight: HSB,
        alpha: Double
    ) {
        guard alpha > 0.01 else { return }

        // Trail — a soft vertical smear above the droplet.
        let trailHeight = radius * 5
        let trailRect = CGRect(
            x: center.x - radius * 0.45,
            y: center.y - trailHeight,
            width: radius * 0.9,
            height: trailHeight
        )
        var trailCtx = ctx
        trailCtx.addFilter(.blur(radius: 8))
        trailCtx.fill(
            Path(roundedRect: trailRect, cornerRadius: radius * 0.45),
            with: .linearGradient(
                Gradient(colors: [
                    body.color(opacity: 0),
                    body.color(opacity: alpha * 0.35)
                ]),
                startPoint: CGPoint(x: trailRect.midX, y: trailRect.minY),
                endPoint: CGPoint(x: trailRect.midX, y: trailRect.maxY)
            )
        )

        // Body — a circle with a highlight specular on the upper left.
        let bodyRect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        var bodyCtx = ctx
        bodyCtx.addFilter(.blur(radius: 3))
        bodyCtx.fill(
            Path(ellipseIn: bodyRect),
            with: .radialGradient(
                Gradient(colors: [
                    highlight.color(opacity: alpha * 0.9),
                    body.color(opacity: alpha * 0.75),
                    body.color(opacity: 0)
                ]),
                center: CGPoint(x: center.x - radius * 0.3, y: center.y - radius * 0.35),
                startRadius: 0,
                endRadius: CGFloat(radius * 1.4)
            )
        )
    }
}

//
//  SereneOrbArchetype.swift
//  SoundSeen
//
//  High-V, low-A protagonist form — a soft floating orb that breathes on
//  a slow ~0.15 Hz cycle. Reads as morning-light / tide / breath. Gated
//  on harmonic ratio: dissonant passages retract the orb because "serene"
//  with a clang of atonality is visually dishonest.
//
//  Beat pulse modulates scale very gently (5%) so the orb is nominally
//  tempo-aware without feeling percussive — the primary breath is time-
//  based, the beat is a whisper on top.
//

import SwiftUI

/// Approximately 6.7-second breath cycle. Slow enough to read as ambient
/// presence rather than animation.
private let breathFrequencyHz: Double = 0.15

struct SereneOrbArchetype: View {
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

        // Harmonic gate: the orb dims in noisy passages so it doesn't
        // contradict what the ear hears. Fades smoothly rather than cutting.
        let hr = state.currentHarmonicRatio
        let harmonicGate = smoothstep(0.35, 0.75, hr)
        guard harmonicGate > 0.02 else { return }

        // Breath: slow sinusoid on a ~6.7s cycle. Maps [-1, 1] → [0.82, 1.0]
        // so the orb never fully deflates.
        let breath = 0.91 + 0.09 * sin(t * 2 * .pi * breathFrequencyHz)
        // Barely-there beat pulse — enough to feel alive without spiking.
        let beatSwell = 1.0 + state.beatPulse * 0.05

        // Orb sits just above center in the SKY zone, drifts gently.
        let cx = size.width * (0.5 + 0.025 * sin(t * 0.09))
        let cy = size.height * (0.42 + 0.02 * cos(t * 0.07))
        let shortEdge = min(size.width, size.height)
        let radius = shortEdge * 0.24 * breath * beatSwell

        // Color: soft teal primary blended with peach secondary, warmed by
        // accent buttercream at the core. No key-pulling — serene reads as
        // mood, not melody.
        let surface = archetypeBlend(scheme.primary, scheme.secondary, 0.45)
        let core = archetypeBlend(surface, scheme.accent, 0.55)

        // Alpha: weight × harmonic gate × mild energy boost.
        let energyBoost = 0.60 + 0.40 * state.currentEnergy
        let alpha = weight * harmonicGate * energyBoost

        drawOrb(
            ctx: &ctx,
            center: CGPoint(x: cx, y: cy),
            radius: radius,
            core: core,
            surface: surface,
            alpha: alpha
        )

        // Halo — a second larger glow that breathes in counter-phase, so
        // the orb feels like it's *breathing out* as the core breathes in.
        let haloScale = 1.45 - 0.15 * sin(t * 2 * .pi * breathFrequencyHz)
        drawHalo(
            ctx: &ctx,
            center: CGPoint(x: cx, y: cy),
            radius: radius * haloScale,
            color: surface,
            alpha: alpha * 0.35
        )
    }

    private func drawOrb(
        ctx: inout GraphicsContext,
        center: CGPoint,
        radius: Double,
        core: HSB,
        surface: HSB,
        alpha: Double
    ) {
        let rect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        var orbCtx = ctx
        orbCtx.addFilter(.blur(radius: 14))
        orbCtx.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: [
                    core.color(opacity: alpha * 0.85),
                    surface.color(opacity: alpha * 0.55),
                    surface.color(opacity: 0)
                ]),
                center: CGPoint(x: center.x - radius * 0.15, y: center.y - radius * 0.2),
                startRadius: 0,
                endRadius: CGFloat(radius * 1.1)
            )
        )
    }

    private func drawHalo(
        ctx: inout GraphicsContext,
        center: CGPoint,
        radius: Double,
        color: HSB,
        alpha: Double
    ) {
        let rect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        var haloCtx = ctx
        haloCtx.addFilter(.blur(radius: 30))
        haloCtx.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: [
                    color.color(opacity: alpha * 0.55),
                    color.color(opacity: 0)
                ]),
                center: .init(x: center.x, y: center.y),
                startRadius: 0,
                endRadius: CGFloat(radius)
            )
        )
    }

    /// Smoothstep: Hermite interpolation between 0 and 1 as x moves from
    /// `edge0` to `edge1`. Clamps outside the range.
    private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - edge0) / max(1e-6, edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
}

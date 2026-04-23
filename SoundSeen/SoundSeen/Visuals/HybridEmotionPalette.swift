//
//  HybridEmotionPalette.swift
//  SoundSeen
//
//  Four-anchor continuous palette. Each emotion quadrant (from BiomeWeights)
//  contributes a 4-color scheme — primary / secondary / accent / atmosphere —
//  and the current color is a weighted blend using the softmax weights already
//  computed in VisualizerState. Optionally modulates hue toward the song's
//  live chroma when the passage is tonal, so the palette reflects *musical*
//  content, not just mood.
//
//  Every voice reads from here — never from raw (valence, arousal) — so the
//  whole scene stays color-coherent.
//

import SwiftUI

struct EmotionScheme {
    /// Dominant color of the scene (sky, central mass).
    let primary: HSB
    /// Supporting color (ribbons, secondary blooms).
    let secondary: HSB
    /// Punch / highlight color (downbeat flash, drop-moment highlight).
    let accent: HSB
    /// Deep ambient wash used at screen edges / behind everything.
    let atmosphere: HSB
}

struct HSB {
    var h: Double  // [0, 1), shortest-path interpolated
    var s: Double  // [0, 1]
    var b: Double  // [0, 1]

    func color(opacity: Double = 1) -> Color {
        Color(hue: h.wrappedHue, saturation: s.clamped01, brightness: b.clamped01)
            .opacity(opacity.clamped01)
    }
}

enum HybridEmotionPalette {
    // Four anchors, one per Biome. These are tuned to read distinctly on a
    // dark background and to blend cleanly through intermediate quadrants.

    static let euphoric = EmotionScheme(
        // High-V, high-A: hot magenta / gold — carnival, sunset, rave.
        primary:    HSB(h: 0.92, s: 0.85, b: 0.98),  // hot pink
        secondary:  HSB(h: 0.08, s: 0.90, b: 1.00),  // tangerine
        accent:     HSB(h: 0.14, s: 0.95, b: 1.00),  // gold flash
        atmosphere: HSB(h: 0.97, s: 0.70, b: 0.45)   // wine deep
    )

    static let serene = EmotionScheme(
        // High-V, low-A: warm pastels — morning, beach, drift.
        primary:    HSB(h: 0.52, s: 0.45, b: 0.92),  // soft teal
        secondary:  HSB(h: 0.10, s: 0.35, b: 0.95),  // peach
        accent:     HSB(h: 0.15, s: 0.55, b: 1.00),  // buttercream
        atmosphere: HSB(h: 0.58, s: 0.35, b: 0.35)   // deep teal
    )

    static let intense = EmotionScheme(
        // Low-V, high-A: electric red-black — storm, fight, danger.
        primary:    HSB(h: 0.99, s: 0.88, b: 0.92),  // hot red
        secondary:  HSB(h: 0.66, s: 0.80, b: 0.92),  // electric blue
        accent:     HSB(h: 0.00, s: 0.00, b: 1.00),  // white strike
        atmosphere: HSB(h: 0.00, s: 0.75, b: 0.22)   // oxblood
    )

    static let melancholic = EmotionScheme(
        // Low-V, low-A: cool desaturated indigo — rain, night, grief.
        primary:    HSB(h: 0.67, s: 0.55, b: 0.65),  // indigo
        secondary:  HSB(h: 0.58, s: 0.40, b: 0.55),  // slate blue
        accent:     HSB(h: 0.75, s: 0.50, b: 0.80),  // lavender highlight
        atmosphere: HSB(h: 0.68, s: 0.60, b: 0.18)   // deep midnight
    )

    /// Blend the four anchors by BiomeWeights, then optionally pull hue
    /// toward the song's current chroma color weighted by chromaStrength.
    static func scheme(
        from weights: BiomeWeights,
        chromaHue: Double = 0,
        chromaStrength: Double = 0
    ) -> EmotionScheme {
        let anchors: [(Biome, EmotionScheme)] = [
            (.euphoric, euphoric),
            (.serene, serene),
            (.intense, intense),
            (.melancholic, melancholic)
        ]
        let primary    = blendHSB(anchors.map { ($0.1.primary,    weights[$0.0]) })
        let secondary  = blendHSB(anchors.map { ($0.1.secondary,  weights[$0.0]) })
        let accent     = blendHSB(anchors.map { ($0.1.accent,     weights[$0.0]) })
        let atmosphere = blendHSB(anchors.map { ($0.1.atmosphere, weights[$0.0]) })

        // Chroma nudge: tonal passages pull primary + secondary hue toward
        // the song's key color. Capped at 0.5 so the emotion anchor is never
        // fully overwritten, and atmosphere/accent are untouched so the
        // deepest and brightest colors keep their emotional read.
        let chromaPull = max(0, min(0.5, chromaStrength * 0.5))
        let chromaH = chromaHue.wrappedHue
        let primaryNudged = HSB(
            h: shortestHueLerp(from: primary.h, to: chromaH, t: chromaPull),
            s: primary.s,
            b: primary.b
        )
        let secondaryNudged = HSB(
            h: shortestHueLerp(from: secondary.h, to: chromaH, t: chromaPull * 0.8),
            s: secondary.s,
            b: secondary.b
        )

        return EmotionScheme(
            primary: primaryNudged,
            secondary: secondaryNudged,
            accent: accent,
            atmosphere: atmosphere
        )
    }

    // MARK: - Weighted HSB blend

    /// Weighted blend of HSB colors with shortest-path hue interpolation.
    /// Weights don't need to sum to 1 — we normalize internally, which keeps
    /// this robust if a caller passes raw unnormalized weights.
    private static func blendHSB(_ samples: [(HSB, Double)]) -> HSB {
        let totalW = samples.reduce(0) { $0 + max(0, $1.1) }
        guard totalW > 1e-6 else { return HSB(h: 0, s: 0, b: 0.5) }

        // Hue lives on a circle — sum unit vectors weighted by their weight,
        // then take the angle of the resultant. This is the correct way to
        // average circular quantities.
        var hx = 0.0, hy = 0.0
        var sSum = 0.0, bSum = 0.0
        for (hsb, w) in samples {
            let nw = max(0, w) / totalW
            let angle = hsb.h * 2 * .pi
            hx += cos(angle) * nw
            hy += sin(angle) * nw
            sSum += hsb.s * nw
            bSum += hsb.b * nw
        }
        var h = atan2(hy, hx) / (2 * .pi)
        if h < 0 { h += 1 }
        return HSB(h: h, s: sSum, b: bSum)
    }

    /// Linear interpolate from `a` to `b` on the hue circle, taking the
    /// shortest path. Used for chroma-nudge; the main biome blend uses the
    /// unit-vector sum above since it handles >2 samples cleanly.
    private static func shortestHueLerp(from a: Double, to b: Double, t: Double) -> Double {
        var delta = b - a
        if delta > 0.5 { delta -= 1 }
        if delta < -0.5 { delta += 1 }
        var out = a + delta * t
        out = out.truncatingRemainder(dividingBy: 1)
        if out < 0 { out += 1 }
        return out
    }
}

// MARK: - Section transform

extension EmotionScheme {
    /// Apply a section's palette transform: scale saturation + brightness,
    /// rotate hue. Operates slot-by-slot so every texture sees the same
    /// transformed scheme and the image stays color-coherent.
    ///
    /// Saturation scale above 1 is clamped by HSB at draw time (values >1
    /// saturate fully). Brightness scale above 1 is allowed so sections like
    /// chorus / drop can actually read brighter than baseline.
    func transformed(by dialect: SectionDialect) -> EmotionScheme {
        func apply(_ c: HSB) -> HSB {
            var h = (c.h + dialect.hueShift).truncatingRemainder(dividingBy: 1)
            if h < 0 { h += 1 }
            return HSB(
                h: h,
                s: max(0, min(1, c.s * dialect.saturationScale)),
                b: max(0, min(1, c.b * dialect.brightnessScale))
            )
        }
        return EmotionScheme(
            primary: apply(primary),
            secondary: apply(secondary),
            accent: apply(accent),
            atmosphere: apply(atmosphere)
        )
    }
}

// MARK: - Numeric helpers

extension Double {
    fileprivate var clamped01: Double { max(0, min(1, self)) }
    fileprivate var wrappedHue: Double {
        var h = self.truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        return h
    }
}

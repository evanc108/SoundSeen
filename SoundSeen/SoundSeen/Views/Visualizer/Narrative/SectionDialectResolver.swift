//
//  SectionDialectResolver.swift
//  SoundSeen
//
//  Maps (section.label, sectionProgress, energyProfile) to a SectionDialect.
//  Seven named constants — one per section in the backend's labels —
//  plus a `default` for anything unrecognized.
//
//  The outro dialect interpolates over section progress: textures fade in
//  reverse build-up order (highs first, bass last), and the composition
//  origin sinks. Other sections are static — the dialect is constant for
//  the section's whole duration.
//

import CoreGraphics
import Foundation

enum SectionDialectResolver {

    /// Resolve the active dialect. Call per frame; cheap (returns constants
    /// except for outro which interpolates).
    static func resolve(
        label: String,
        progress: Double,
        energyProfile: String
    ) -> SectionDialect {
        switch label.lowercased() {
        case "intro":   return intro
        case "verse":   return verse
        case "chorus":  return chorus
        case "bridge":  return bridge
        case "break":   return breakSec
        case "drop":    return drop
        case "outro":   return outro(progress: progress)
        default:        return verse  // safe fallback — looks like baseline
        }
    }

    // MARK: - Per-section constants

    /// intro — narrow central column, muted. Dashboard-quiet: just the key
    /// indicator, valence lean, and sub-bass anchor.
    static let intro = SectionDialect(
        activeUBounds: 0.42...0.58,
        activeVBounds: 0.40...0.70,
        bandMask: [1.0, 0.9, 0.6, 0.3, 0.1, 0.05, 0.0, 0.0],
        compositionOrigin: CGPoint(x: 0.5, y: 0.5),
        rotationDegrees: 0,
        translateOffset: .zero,
        mirrorX: false,
        enabledTextures: [
            .smoke, .inkBleed, .velvetDarkness,
            .keyRail, .valenceGradient, .subBassRipple
        ],
        saturationScale: 0.55,
        brightnessScale: 0.75,
        hueShift: 0,
        grainOpacity: 0.02,
        allowOffscreen: false,
        outroFadeProgress: 0
    )

    /// verse — baseline. Every signal visible at moderate levels.
    static let verse = SectionDialect(
        activeUBounds: 0...1,
        activeVBounds: 0.25...0.85,
        bandMask: [1.0, 1.0, 1.0, 1.0, 0.6, 0.4, 0.25, 0.15],
        compositionOrigin: CGPoint(x: 0.5, y: 0.5),
        rotationDegrees: 0,
        translateOffset: .zero,
        mirrorX: false,
        enabledTextures: [
            .smoke, .inkBleed, .aurora, .ember, .glowPulse, .filmGrain,
            .chromaSlick, .keyRail, .valenceGradient, .subBassRipple, .godRays
        ],
        saturationScale: 1.0,
        brightnessScale: 1.0,
        hueShift: 0,
        grainOpacity: 0.03,
        allowOffscreen: false,
        outroFadeProgress: 0
    )

    /// chorus — elevated, full palette. Every texture on but restrained.
    static let chorus = SectionDialect(
        activeUBounds: 0...1,
        activeVBounds: 0.05...0.95,
        bandMask: [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.8],
        compositionOrigin: CGPoint(x: 0.5, y: 0.5),
        rotationDegrees: 0,
        translateOffset: .zero,
        mirrorX: true,
        enabledTextures: Set(TextureID.allCases),
        saturationScale: 1.05,
        brightnessScale: 1.05,
        hueShift: 0,
        grainOpacity: 0,
        allowOffscreen: false,
        outroFadeProgress: 0
    )

    /// bridge — off-axis dreamscape. KeyRail removed: you shouldn't be
    /// able to read the key easily (that's the point of a bridge).
    static let bridge = SectionDialect(
        activeUBounds: 0.30...1.0,
        activeVBounds: 0.05...0.70,
        bandMask: [0.6, 0.8, 1.0, 1.0, 1.0, 0.9, 0.7, 0.5],
        compositionOrigin: CGPoint(x: 0.65, y: 0.35),
        rotationDegrees: 12,
        translateOffset: .zero,
        mirrorX: false,
        enabledTextures: [
            .smoke, .inkBleed, .aurora, .thermalShimmer, .glowPulse, .filmGrain,
            .chromaSlick, .fluxShatter, .valenceGradient, .godRays
        ],
        saturationScale: 0.95,
        brightnessScale: 0.95,
        hueShift: 0.15,
        grainOpacity: 0.04,
        allowOffscreen: false,
        outroFadeProgress: 0
    )

    /// break — the floor. Sub-bass anchor + cool-diagonal mood only.
    static let breakSec = SectionDialect(
        activeUBounds: 0...1,
        activeVBounds: 0.80...0.98,
        bandMask: [1.0, 0.3, 0, 0, 0, 0, 0, 0],
        compositionOrigin: CGPoint(x: 0.5, y: 0.90),
        rotationDegrees: 0,
        translateOffset: .zero,
        mirrorX: false,
        enabledTextures: [
            .velvetDarkness, .smoke, .filmGrain, .glowPulse,
            .subBassRipple, .valenceGradient
        ],
        saturationScale: 0.20,
        brightnessScale: 0.60,
        hueShift: 0,
        grainOpacity: 0.12,
        allowOffscreen: false,
        outroFadeProgress: 0
    )

    /// drop — release, expanded bounds. All textures unlocked.
    static let drop = SectionDialect(
        activeUBounds: -0.15...1.15,
        activeVBounds: -0.10...1.10,
        bandMask: [1.2, 1.2, 1.0, 1.0, 1.1, 1.2, 1.2, 1.3],
        compositionOrigin: CGPoint(x: 0.5, y: 0.5),
        rotationDegrees: 0,
        translateOffset: .zero,
        mirrorX: false,
        enabledTextures: Set(TextureID.allCases),
        saturationScale: 1.08,
        brightnessScale: 1.08,
        hueShift: 0,
        grainOpacity: 0.05,
        allowOffscreen: true,
        outroFadeProgress: 0
    )

    /// outro — interpolates over progress. Retires highs-first, then
    /// dashboards, then the sub-bass anchor. Composition sinks.
    static func outro(progress p: Double) -> SectionDialect {
        let pClamped = max(0, min(1, p))

        // Outro retires textures in reverse build-up order: highs first,
        // dashboards next, sub-bass last. The archetype shapes retire
        // alongside the dashboard layer since they're the scene protagonist.
        var active: Set<TextureID> = [
            .smoke, .inkBleed, .aurora, .ember, .frost,
            .filmGrain, .glowPulse, .velvetDarkness,
            .chromaSlick, .keyRail, .valenceGradient, .subBassRipple, .godRays
        ]
        if pClamped > 0.25 { active.remove(.frost); active.remove(.godRays) }
        if pClamped > 0.40 { active.remove(.filmGrain); active.remove(.aurora); active.remove(.chromaSlick) }
        if pClamped > 0.55 { active.remove(.ember); active.remove(.glowPulse) }
        if pClamped > 0.70 { active.remove(.inkBleed); active.remove(.keyRail) }
        if pClamped > 0.85 { active.remove(.valenceGradient) }
        if pClamped > 0.92 { active.remove(.subBassRipple) }
        if pClamped > 0.95 { active.remove(.smoke) }

        let sat = 0.80 - pClamped * 0.55
        let bri = 0.90 - pClamped * 0.60
        let origin = CGPoint(x: 0.5, y: 0.50 + pClamped * 0.15)

        return SectionDialect(
            activeUBounds: 0...1,
            activeVBounds: 0.20...0.98,
            bandMask: [1.0, 1.0, 1.0, 0.9, 0.7, 0.5, 0.3, 0.15].map { $0 * (1 - pClamped * 0.7) },
            compositionOrigin: origin,
            rotationDegrees: 0,
            translateOffset: .zero,
            mirrorX: false,
            enabledTextures: active,
            saturationScale: sat,
            brightnessScale: bri,
            hueShift: 0,
            grainOpacity: 0.02,
            allowOffscreen: false,
            outroFadeProgress: pClamped
        )
    }
}

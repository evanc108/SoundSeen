//
//  SectionDialect.swift
//  SoundSeen
//
//  Per-section spatial + palette + texture rules. Every texture reads a
//  SectionDialect each frame and applies its restrictions:
//
//    - activeUBounds / activeVBounds: clamps where the texture is allowed
//      to draw. Ignored at draw time; each texture uses these to clip its
//      sampling / emission range.
//    - bandMask: per-band multiplier. Textures tied to a specific mel band
//      multiply opacity by bandMask[i] before rendering.
//    - enabledTextures: if a texture's ID isn't here, it draws nothing.
//    - compositionOrigin / rotationDegrees / translateOffset / mirrorX:
//      global transform applied to every texture's coordinate frame.
//    - saturationScale / brightnessScale / hueShift: palette transform
//      applied via EmotionScheme.transformed(by:).
//    - grainOpacity: film grain floor this section commands regardless
//      of flux (break wants constant grain; chorus wants none).
//    - allowOffscreen: lets particle textures emit outside the viewport
//      (drop only).
//    - outroFadeProgress: 0 outside outro; 0..1 during outro so textures
//      can fade themselves in reverse build-up order.
//

import Foundation
import SwiftUI

enum TextureID: String, CaseIterable, Sendable {
    case smoke
    case velvetDarkness
    case glowPulse
    case inkBleed
    case aurora
    case ember
    case frost
    case filmGrain
    case thermalShimmer
    case chromaSlick
    case keyRail
    case valenceGradient
    case fluxShatter
    case subBassRipple
    case godRays
}

/// Named coordinate zones shared by every texture. `u` is horizontal
/// [0, 1], `v` is vertical [0, 1] with 0 at top. Textures consult these
/// when the plan pins them to a specific region of the frame.
enum VizZone {
    /// Left rail — chromatic key indicators.
    static let gutterL_u: ClosedRange<Double> = 0.00...0.08
    static let gutterL_v: ClosedRange<Double> = 0.10...0.90
    /// Left rail, lower half — KeyRail.
    static let gutterL_lower_v: ClosedRange<Double> = 0.48...0.90
    /// Left rail, upper half — SpectralStaircase.
    static let gutterL_upper_v: ClosedRange<Double> = 0.10...0.46

    /// Right rail — tonality / consonance indicators.
    static let gutterR_u: ClosedRange<Double> = 0.92...1.00
    static let gutterR_v: ClosedRange<Double> = 0.10...0.90

    /// Horizon band — linear event slashes (flux ruptures).
    static let horizon_v: ClosedRange<Double> = 0.46...0.54

    /// Four corner squares (0.15×0.15). Coordinates are top-left of each.
    static let cornerTL: CGPoint = CGPoint(x: 0.00, y: 0.00)
    static let cornerTR: CGPoint = CGPoint(x: 0.85, y: 0.00)
    static let cornerBL: CGPoint = CGPoint(x: 0.00, y: 0.85)
    static let cornerBR: CGPoint = CGPoint(x: 0.85, y: 0.85)
    static let cornerSize: Double = 0.15

    /// Perimeter width as a fraction of the shorter screen edge.
    static let perimeterThickness: Double = 0.06
}

struct SectionDialect: Equatable {
    let activeUBounds: ClosedRange<Double>
    let activeVBounds: ClosedRange<Double>
    let bandMask: [Double]           // 8 multipliers, one per mel band
    let compositionOrigin: CGPoint   // (u, v) in unit-square
    let rotationDegrees: Double
    let translateOffset: CGSize
    let mirrorX: Bool
    let enabledTextures: Set<TextureID>
    let saturationScale: Double
    let brightnessScale: Double
    let hueShift: Double
    let grainOpacity: Double
    let allowOffscreen: Bool
    let outroFadeProgress: Double

    /// A safe default used before the first section resolves.
    static let idle = SectionDialect(
        activeUBounds: 0...1,
        activeVBounds: 0...1,
        bandMask: Array(repeating: 1.0, count: 8),
        compositionOrigin: CGPoint(x: 0.5, y: 0.5),
        rotationDegrees: 0,
        translateOffset: .zero,
        mirrorX: false,
        enabledTextures: Set(TextureID.allCases),
        saturationScale: 1.0,
        brightnessScale: 1.0,
        hueShift: 0,
        grainOpacity: 0,
        allowOffscreen: false,
        outroFadeProgress: 0
    )
}

//
//  HUDStyles.swift
//  SoundSeen
//
//  Design tokens for the playback HUD. Dark-glass surfaces on top of a
//  continuously changing visualizer — so every surface needs enough
//  opacity + contrast to stay legible even when the scene behind it is
//  bright magenta or deep indigo. Tokens live here so the HUD's look
//  can be tuned in one place without hunting through views.
//

import SwiftUI

enum HUDStyles {
    // MARK: - Surfaces

    /// Dark glass background used under HUD controls. Opaque enough to read,
    /// translucent enough to let the scene breathe through.
    static let surface: Color = Color.black.opacity(0.42)
    static let surfaceElevated: Color = Color.black.opacity(0.55)

    /// Stroke used on circular control backings (back button, menu button).
    static let hairline: Color = Color.white.opacity(0.16)

    // MARK: - Text

    static let textPrimary: Color = .white
    static let textSecondary: Color = Color.white.opacity(0.78)
    static let textMuted: Color = Color.white.opacity(0.55)

    /// Section caption: large, uppercase, heavy. This is the DHH user's
    /// primary written read of "where we are in the song" — must be
    /// immediately legible across any palette behind it.
    static func captionFont(relative size: CGFloat = 48) -> Font {
        .system(size: size, weight: .black, design: .rounded)
    }

    // MARK: - Corners + spacing

    static let cornerLarge: CGFloat = 20
    static let cornerPill: CGFloat = 999
    static let touchTargetMin: CGFloat = 44

    // MARK: - Shadows

    /// Outer shadow used on the play button and pill chips — gives a soft
    /// lift against bright palettes without a hard edge.
    static let lift: Color = Color.black.opacity(0.40)
}

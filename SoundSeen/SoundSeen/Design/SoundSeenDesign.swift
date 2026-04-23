//
//  SoundSeenDesign.swift
//  SoundSeen
//
//  App-wide design tokens. One place to tune palette, typography,
//  spacing, radii, shadows. HUDStyles (inside the player) pulls from
//  here so the player and the library stay visually coherent.
//
//  Design bias: deep blacks, a single cool accent, and a very small
//  palette. The visualizer provides all the color drama — everywhere
//  else, we keep it restrained so the music leads.
//

import SwiftUI

enum SSDesign {
    // MARK: - Palette

    enum Palette {
        /// Deepest black used behind large scenes (library, upload sheet).
        static let base: Color = Color(red: 0.05, green: 0.05, blue: 0.08)
        /// One step up — used for surfaces that need to separate from base.
        static let surface: Color = Color(red: 0.10, green: 0.10, blue: 0.14)
        /// Raised surface — cards, sheets, pills that sit above surface.
        static let surfaceRaised: Color = Color(red: 0.14, green: 0.14, blue: 0.18)
        /// Pressed / hover surface — slightly brighter for tactile feedback.
        static let surfaceActive: Color = Color(red: 0.18, green: 0.18, blue: 0.23)

        /// Hairline strokes on cards and surfaces. Sits at ~10% white.
        static let hairline: Color = Color.white.opacity(0.10)
        static let hairlineStrong: Color = Color.white.opacity(0.18)

        /// Primary text. Pure white for maximum contrast on dark.
        static let textPrimary: Color = .white
        /// Secondary — subtitles, meta, time stamps.
        static let textSecondary: Color = Color.white.opacity(0.72)
        /// Muted — placeholders, tertiary labels.
        static let textMuted: Color = Color.white.opacity(0.48)

        /// The app's single chromatic accent. Used sparingly — active
        /// chips, primary buttons, focus rings. Everything else is dark.
        /// Intentionally not hot-pink: we want the VISUALIZER to be the
        /// loudest color in the app, not the chrome.
        static let accent: Color = Color(red: 0.52, green: 0.82, blue: 1.00)
        /// Accent used on large fills (CTAs). Slightly deeper so white
        /// text on top reads comfortably.
        static let accentSolid: Color = Color(red: 0.32, green: 0.60, blue: 0.98)

        /// Destructive / warning.
        static let danger: Color = Color(red: 1.00, green: 0.42, blue: 0.42)
    }

    // MARK: - Typography

    enum Typography {
        /// Big display headline. Library title, upload sheet title.
        static func display(_ size: CGFloat = 34) -> Font {
            .system(size: size, weight: .black, design: .rounded)
        }
        /// Page / section title inside screens.
        static func title(_ size: CGFloat = 22) -> Font {
            .system(size: size, weight: .bold, design: .rounded)
        }
        /// Track title on a card, button label.
        static func headline(_ size: CGFloat = 17) -> Font {
            .system(size: size, weight: .semibold, design: .default)
        }
        /// Default body text.
        static func body(_ size: CGFloat = 15) -> Font {
            .system(size: size, weight: .regular, design: .default)
        }
        /// Meta text: artist name, duration, BPM.
        static func meta(_ size: CGFloat = 13) -> Font {
            .system(size: size, weight: .medium, design: .rounded).monospacedDigit()
        }
        /// Small caption / chip text.
        static func caption(_ size: CGFloat = 11) -> Font {
            .system(size: size, weight: .bold, design: .rounded)
        }
    }

    // MARK: - Spacing

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
        static let xxxl: CGFloat = 40
    }

    // MARK: - Corner radii

    enum Radius {
        static let s: CGFloat = 8
        static let m: CGFloat = 14
        static let l: CGFloat = 20
        static let xl: CGFloat = 28
        static let pill: CGFloat = 999
    }

    // MARK: - Shadows

    enum Shadow {
        static let card = ShadowToken(color: .black.opacity(0.35), radius: 18, y: 8)
        static let lift = ShadowToken(color: .black.opacity(0.55), radius: 24, y: 12)
    }
}

struct ShadowToken {
    let color: Color
    let radius: CGFloat
    let y: CGFloat
}

extension View {
    func ssShadow(_ token: ShadowToken) -> some View {
        shadow(color: token.color, radius: token.radius, x: 0, y: token.y)
    }
}

// MARK: - Reusable surfaces

/// Ambient dark background used behind the library, upload sheet, and any
/// other full-screen scenes outside the visualizer. Subtle vertical
/// gradient so the top of the screen reads a shade lighter and the
/// content feels anchored.
struct AppBackground: View {
    var body: some View {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: SSDesign.Palette.surface, location: 0.0),
                .init(color: SSDesign.Palette.base, location: 0.55),
                .init(color: .black, location: 1.0)
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

/// Standard card surface. Rounded, hairline border, raised fill, card
/// shadow — the library's track rows and the upload zone both use it.
struct CardSurface<Content: View>: View {
    var radius: CGFloat = SSDesign.Radius.l
    var active: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(active ? SSDesign.Palette.surfaceActive : SSDesign.Palette.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(SSDesign.Palette.hairline, lineWidth: 0.5)
            )
            .ssShadow(SSDesign.Shadow.card)
    }
}

/// Pill button with primary / secondary / destructive tint.
struct PillButtonStyle: ButtonStyle {
    enum Tint { case primary, secondary, destructive }
    var tint: Tint = .primary

    func makeBody(configuration: Configuration) -> some View {
        let (bg, fg): (Color, Color) = {
            switch tint {
            case .primary:     return (SSDesign.Palette.accentSolid, .white)
            case .secondary:   return (SSDesign.Palette.surfaceActive, SSDesign.Palette.textPrimary)
            case .destructive: return (SSDesign.Palette.danger.opacity(0.18), SSDesign.Palette.danger)
            }
        }()
        return configuration.label
            .font(SSDesign.Typography.caption(12))
            .kerning(0.6)
            .textCase(.uppercase)
            .padding(.horizontal, SSDesign.Space.m)
            .padding(.vertical, SSDesign.Space.s)
            .background(
                Capsule().fill(bg)
                    .overlay(Capsule().stroke(SSDesign.Palette.hairline, lineWidth: 0.5))
            )
            .foregroundStyle(fg)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

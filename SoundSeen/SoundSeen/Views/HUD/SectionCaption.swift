//
//  SectionCaption.swift
//  SoundSeen
//
//  Large accessibility caption that names the current structural section
//  of the song (INTRO, VERSE, CHORUS, BRIDGE, BREAK, DROP, OUTRO) in big
//  type. For DHH users this is the primary written signal of where we
//  are in the song — loud sections sound loud, but they also read loud.
//
//  A subtle cross-fade keeps the caption from snapping between sections,
//  and VoiceOver announces every change via accessibilityLabel + a
//  stable identifier so screen-reader users hear transitions the same
//  moment hearing users would feel them.
//

import SwiftUI

struct SectionCaption: View {
    @Bindable var state: VisualizerState

    /// Dim the caption when the scene is already intense — during a drop
    /// section with full-energy bands, a 48pt uppercase word on top can
    /// overload. Section progress (0..1) lets us fade at the tail end of
    /// long sections so the caption doesn't outstay its welcome.
    private var opacity: Double {
        let p = state.currentSectionProgress
        // Fade in over first 8% of section, hold to 70%, fade out by 100%.
        let fadeIn = min(1, p / 0.08)
        let fadeOut = min(1, max(0, (1 - p) / 0.25))
        return fadeIn * fadeOut * 0.95
    }

    private var text: String {
        state.currentSectionLabel.uppercased()
    }

    var body: some View {
        VStack(spacing: 6) {
            if !text.isEmpty {
                Text(text)
                    .font(HUDStyles.captionFont(relative: 44))
                    .kerning(4)
                    .foregroundStyle(HUDStyles.textPrimary)
                    .shadow(color: HUDStyles.lift, radius: 12, x: 0, y: 4)
                    .opacity(opacity)
                    .accessibilityLabel("Now in \(text.capitalized) section")
                    .accessibilityAddTraits(.updatesFrequently)
                    .animation(.easeInOut(duration: 0.35), value: text)

                if !state.currentSectionEnergyProfile.isEmpty {
                    Text(state.currentSectionEnergyProfile.uppercased())
                        .font(.caption.weight(.bold))
                        .kerning(2)
                        .foregroundStyle(HUDStyles.textMuted)
                        .opacity(opacity * 0.7)
                        .accessibilityHidden(true)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

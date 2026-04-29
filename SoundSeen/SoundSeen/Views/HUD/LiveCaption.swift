//
//  LiveCaption.swift
//  SoundSeen
//
//  HUD caption for live-microphone mode. Replaces SectionCaption here
//  because live analysis has no "intro / verse / chorus" structure — the
//  rolling energy-profile classifier (LiveEnergyProfiler) is the closest
//  analog. This view renders that one label plus an unobtrusive "LOCKING
//  TEMPO…" affordance while the beat tracker hasn't converged yet.
//

import SwiftUI

struct LiveCaption: View {
    @Bindable var state: VisualizerState
    /// nil until LiveBeatTracker has locked; drives the tempo-warmup hint.
    let lockedBPM: Double?

    private var profileText: String {
        state.currentSectionEnergyProfile.uppercased()
    }

    var body: some View {
        VStack(spacing: 8) {
            if !profileText.isEmpty {
                Text(profileText)
                    .font(HUDStyles.captionFont(relative: 44))
                    .kerning(4)
                    .foregroundStyle(HUDStyles.textPrimary)
                    .shadow(color: HUDStyles.lift, radius: 12, x: 0, y: 4)
                    .accessibilityLabel("Energy is \(profileText.capitalized)")
                    .accessibilityAddTraits(.updatesFrequently)
                    .animation(.easeInOut(duration: 0.35), value: profileText)
            }

            Group {
                if let bpm = lockedBPM {
                    Text("\(Int(bpm.rounded())) BPM")
                        .accessibilityLabel("Tempo \(Int(bpm.rounded())) beats per minute")
                } else {
                    Text("LOCKING TEMPO…")
                        .accessibilityLabel("Locking tempo")
                }
            }
            .font(.caption.weight(.bold))
            .kerning(2)
            .foregroundStyle(HUDStyles.textMuted)
        }
        .allowsHitTesting(false)
    }
}

//
//  LiveView.swift
//  SoundSeen
//
//  Placeholder while live visuals are on hold. Server-rendered MP4
//  previews replaced the Metal canvas in the analyzed player; live
//  mode needs a fresh visual surface designed against the same
//  vocabulary. Until that lands, this tab is intentionally quiet.
//

import SwiftUI

struct LiveView: View {
    var body: some View {
        ZStack {
            AppBackground()
                .ignoresSafeArea()

            VStack(spacing: SSDesign.Space.l) {
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(SSDesign.Palette.textMuted)

                VStack(spacing: SSDesign.Space.s) {
                    Text("Live visuals on hold")
                        .font(SSDesign.Typography.title(22))
                        .foregroundStyle(SSDesign.Palette.textPrimary)
                    Text("Server-rendered previews replaced the canvas. Live mode is paused while a new visual surface gets designed.")
                        .font(SSDesign.Typography.body())
                        .foregroundStyle(SSDesign.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, SSDesign.Space.xl)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    LiveView()
        .preferredColorScheme(.dark)
}

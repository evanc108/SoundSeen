//
//  RenderProgressView.swift
//  SoundSeen
//
//  Shown when the user opens an analyzed track whose render isn't ready
//  yet — queued, rendering, downloading, or failed. Modal doesn't stream
//  progress today so we don't fake a percent; just an animated indicator
//  and the title of the track that's brewing.
//

import SwiftUI

struct RenderProgressView: View {
    let track: LibraryTrack
    let job: RenderJob?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AppBackground()
                .ignoresSafeArea()

            VStack(spacing: SSDesign.Space.xl) {
                Spacer()

                ProgressView()
                    .controlSize(.large)
                    .tint(SSDesign.Palette.accent)

                VStack(spacing: SSDesign.Space.s) {
                    Text(headline)
                        .font(SSDesign.Typography.title(24))
                        .foregroundStyle(SSDesign.Palette.textPrimary)
                        .multilineTextAlignment(.center)
                    Text(subline)
                        .font(SSDesign.Typography.body())
                        .foregroundStyle(SSDesign.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, SSDesign.Space.xl)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Text("Back")
                        .font(SSDesign.Typography.caption(11))
                        .kerning(1.5)
                        .textCase(.uppercase)
                        .padding(.horizontal, SSDesign.Space.xl)
                        .padding(.vertical, SSDesign.Space.m)
                        .background(Capsule().fill(SSDesign.Palette.surfaceRaised))
                        .overlay(Capsule().stroke(SSDesign.Palette.hairline, lineWidth: 0.5))
                        .foregroundStyle(SSDesign.Palette.textPrimary)
                }
                .buttonStyle(.plain)
                .padding(.bottom, SSDesign.Space.xxxl)
            }
        }
        .navigationBarBackButtonHidden(true)
    }

    private var headline: String {
        guard let job else { return "Preparing visuals" }
        switch job.status {
        case .queued, .rendering: return "Rendering visuals"
        case .complete:           return "Downloading"
        case .failed:             return "Render failed"
        case .unavailable:        return "Visuals offline"
        }
    }

    private var subline: String {
        guard let job else {
            return "\u{201C}\(track.title)\u{201D} is queued for the server. This usually takes 30 seconds to a few minutes."
        }
        switch job.status {
        case .queued, .rendering:
            return "\u{201C}\(track.title)\u{201D} is being rendered on the server. Hang tight — feel free to leave the app."
        case .complete:
            return "\u{201C}\(track.title)\u{201D} just finished — downloading the video now."
        case .failed:
            return job.error ?? "The renderer hit an unexpected error. Try again from the track menu."
        case .unavailable:
            return "Server-side rendering isn't reachable right now. You can still play the audio once it's available."
        }
    }
}

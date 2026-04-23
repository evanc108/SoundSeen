//
//  PlaybackHUD.swift
//  SoundSeen
//
//  Transport overlay for the analyzed player. Minimal by design: a back
//  button and track meta at the top, a large play/pause centered near
//  the bottom, and a scrubber + time with BPM and section chip. All
//  surfaces are dark-glass so they read on any palette the visualizer
//  produces.
//
//  Built as a single View so AnalyzedPlayerView can drop it on top of
//  VisualizerRoot without worrying about layout bookkeeping.
//

import SwiftUI

struct PlaybackHUD: View {
    @Bindable var player: AudioPlayer
    let track: LibraryTrack
    let analysis: SongAnalysis
    let sectionLabel: String
    var onBack: () -> Void
    var onReanalyze: () -> Void

    @State private var showReanalyzeConfirmation: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 20)
                .padding(.top, 8)
            Spacer()
            transport
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
        }
    }

    // MARK: - Top

    private var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            circleButton(symbol: "chevron.backward", label: "Back", action: onBack)

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(HUDStyles.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    chip(text: "\(Int(analysis.bpm.rounded())) BPM", emphasized: true)
                    if !sectionLabel.isEmpty {
                        chip(text: sectionLabel.capitalized, emphasized: false)
                    }
                }
            }

            Spacer(minLength: 0)

            Menu {
                Button(role: .destructive) {
                    showReanalyzeConfirmation = true
                } label: {
                    Label("Re-analyze this track", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(HUDStyles.textPrimary)
                    .frame(width: HUDStyles.touchTargetMin, height: HUDStyles.touchTargetMin)
                    .background(HUDStyles.surface, in: Circle())
                    .overlay(Circle().stroke(HUDStyles.hairline, lineWidth: 0.5))
            }
            .accessibilityLabel("Track options")
        }
        .confirmationDialog(
            "Re-analyze this track?",
            isPresented: $showReanalyzeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Re-analyze", role: .destructive) { onReanalyze() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This discards the existing analysis and uploads the track again. Takes ~5\u{2013}15 seconds.")
        }
    }

    // MARK: - Transport

    private var transport: some View {
        let total = max(analysis.durationSeconds, 0.001)
        let current = min(max(player.currentTime, 0), total)
        return VStack(spacing: 14) {
            HStack {
                Text(formatTime(current))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(HUDStyles.textSecondary)
                Spacer()
                Text(formatTime(total))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(HUDStyles.textSecondary)
            }
            Slider(
                value: Binding(
                    get: { current },
                    set: { player.seek(to: $0) }
                ),
                in: 0...total
            )
            .tint(HUDStyles.textPrimary)
            .accessibilityLabel("Playback position")
            .accessibilityValue(formatTime(current))

            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 72, weight: .regular))
                    .foregroundStyle(HUDStyles.textPrimary)
                    .shadow(color: HUDStyles.lift, radius: 18, y: 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .padding(.top, 4)
        }
    }

    // MARK: - Primitives

    private func circleButton(
        symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(HUDStyles.textPrimary)
                .frame(width: HUDStyles.touchTargetMin, height: HUDStyles.touchTargetMin)
                .background(HUDStyles.surface, in: Circle())
                .overlay(Circle().stroke(HUDStyles.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func chip(text: String, emphasized: Bool) -> some View {
        Text(text)
            .font(.caption.monospacedDigit().weight(emphasized ? .bold : .medium))
            .foregroundStyle(HUDStyles.textPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                (emphasized ? HUDStyles.surfaceElevated : HUDStyles.surface),
                in: Capsule()
            )
            .overlay(Capsule().stroke(HUDStyles.hairline, lineWidth: 0.5))
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

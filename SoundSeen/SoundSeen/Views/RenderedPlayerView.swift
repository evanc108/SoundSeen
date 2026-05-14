//
//  RenderedPlayerView.swift
//  SoundSeen
//
//  Replaces the canvas-based AnalyzedPlayerView. The visualizer is a
//  pre-rendered MP4 now; this view drives an AVPlayer and fans its
//  clock out to HapticVocabulary so the haptic vocabulary stays in sync
//  with what the user sees.
//

import AVKit
import SwiftUI

struct RenderedPlayerView: View {
    let track: LibraryTrack
    let analysis: SongAnalysis
    let videoURL: URL
    var onRequestReanalyze: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @StateObject private var playback = VideoPlayback()
    @State private var haptics = HapticVocabulary()
    @State private var didStart: Bool = false
    @State private var loadError: String? = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoPlayer(player: playback.player)
                .disabled(true)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            PlaybackHUD(
                player: playback,
                track: track,
                analysis: analysis,
                onBack: { dismiss() },
                onReanalyze: {
                    dismiss()
                    onRequestReanalyze?()
                }
            )

            if let error = loadError {
                ContentUnavailableView(
                    "Can't play this track",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .foregroundStyle(.white)
            }
        }
        .preferredColorScheme(.dark)
        .navigationBarBackButtonHidden(true)
        .task { await start() }
        .onDisappear {
            playback.pause()
            haptics.stop()
        }
    }

    // MARK: - Lifecycle

    private func start() async {
        guard !didStart else { return }
        didStart = true

        await playback.load(url: videoURL)

        haptics.start()
        haptics.prepare(analysis: analysis)
        haptics.setEnabled(true)

        playback.removeAllTickHandlers()
        playback.addTickHandler { [analysis] prev, now in
            MainActor.assumeIsolated {
                let intensity = sumLowBands(at: now, frames: analysis.frames)
                haptics.tick(
                    prevTime: prev,
                    currentTime: now,
                    lowBandIntensity: intensity
                )
            }
        }

        playback.play()
    }
}

/// Sum sub_bass + bass at the frame closest to `time`, clamped to [0, 1].
/// Matches the AnalyzedPlayerView shaping that drove the continuous hum.
private func sumLowBands(at time: TimeInterval, frames: Frames) -> Double {
    guard frames.count > 0, frames.frameDurationMs > 0 else { return 0 }
    let idx = max(0, min(frames.count - 1,
                         Int(time * 1000.0 / frames.frameDurationMs)))
    guard idx < frames.bands.count else { return 0 }
    let row = frames.bands[idx]
    let sub = row.indices.contains(0) ? row[0] : 0
    let bass = row.indices.contains(1) ? row[1] : 0
    return max(0, min(1, (sub + bass) * 0.7))
}

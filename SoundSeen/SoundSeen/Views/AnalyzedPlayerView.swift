//
//  AnalyzedPlayerView.swift
//  SoundSeen
//
//  Thin composition root for analyzed playback. Owns the five coordinated
//  objects — AudioPlayer, VisualizerState, HapticVocabulary,
//  ParticleDustEmitter, DropChoreography — wires a single tick handler
//  that fans out to each, and renders the three UI layers:
//
//    VisualizerRoot  — scene (7 voices + particles + drop overlay)
//    SectionCaption  — DHH-legible section name in large type
//    PlaybackHUD     — transport + scrubber + meta
//
//  Everything visual lives in those three files. This view's only job is
//  to assemble them.
//

import SwiftUI

struct AnalyzedPlayerView: View {
    let track: LibraryTrack
    let analysis: SongAnalysis
    /// Called after the user confirms re-analysis in the HUD menu. View
    /// dismisses first so the parent can safely replace the cached
    /// analysis without this view observing a half-written state.
    var onRequestReanalyze: (() -> Void)? = nil

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var player = AudioPlayer()
    @State private var visualizer: VisualizerState? = nil
    @State private var haptics = HapticVocabulary()
    @State private var choreography: DropChoreography? = nil
    @State private var narrative: SceneNarrative? = nil

    @State private var loadError: String? = nil
    @State private var didStart: Bool = false

    var body: some View {
        ZStack {
            if let viz = visualizer, let choreo = choreography, let nar = narrative {
                VisualizerRoot(
                    state: viz,
                    choreography: choreo,
                    narrative: nar
                )

                VStack {
                    SectionCaption(state: viz)
                        .padding(.top, 72)
                    Spacer()
                }
                .allowsHitTesting(false)

                PlaybackHUD(
                    player: player,
                    track: track,
                    analysis: analysis,
                    sectionLabel: viz.currentSectionLabel,
                    onBack: { dismiss() },
                    onReanalyze: {
                        dismiss()
                        onRequestReanalyze?()
                    }
                )
            } else {
                Color.black
            }

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
            player.pause()
            player.stop()
            haptics.stop()
        }
    }

    // MARK: - Lifecycle

    private func start() async {
        guard !didStart else { return }
        didStart = true

        guard let audioURL = library.playbackURL(for: track) else {
            loadError = "Missing audio file for \"\(track.title)\"."
            return
        }

        let viz = VisualizerState(analysis: analysis)
        let choreo = DropChoreography(state: viz)
        let nar = SceneNarrative(state: viz)
        visualizer = viz
        choreography = choreo
        narrative = nar

        // Haptic vocabulary fires the drop .ahap in lockstep with the
        // visual flash phase — one callback bridges the two modalities.
        let hapticsRef = haptics
        choreo.onDropReleased = { [weak hapticsRef] in
            hapticsRef?.playPattern(named: "drop")
        }

        do {
            try player.load(url: audioURL)
        } catch {
            loadError = "Couldn't load audio: \(error.localizedDescription)"
            return
        }

        haptics.start()
        haptics.prepare(analysis: analysis)
        haptics.setEnabled(true)

        player.removeAllTickHandlers()
        player.addTickHandler { [weak viz, weak choreo, weak nar, weak hapticsRef] prev, now in
            MainActor.assumeIsolated {
                viz?.update(prevTime: prev, currentTime: now)
                choreo?.tick(prevTime: prev, currentTime: now)
                nar?.tick(prevTime: prev, currentTime: now)
                if let viz {
                    // Sum sub_bass + bass (clamped) for the haptic hum.
                    let bands = viz.currentBands
                    let low = (bands.count > 0 ? bands[0] : 0) + (bands.count > 1 ? bands[1] : 0)
                    let lowClamped = max(0, min(1, low * 0.7))
                    hapticsRef?.tick(
                        prevTime: prev,
                        currentTime: now,
                        lowBandIntensity: lowClamped
                    )
                }
            }
        }

        // Seed initial frame so the scene isn't a flash-of-default-color
        // before the first display-link tick lands.
        viz.update(prevTime: 0, currentTime: 0)
    }
}

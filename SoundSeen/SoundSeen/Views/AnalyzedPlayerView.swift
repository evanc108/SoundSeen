//
//  AnalyzedPlayerView.swift
//  SoundSeen
//
//  Dedicated player screen for tracks that have a backend-computed
//  SongAnalysis. Owns its own AudioPlayer, VisualizerState, and
//  HapticEngine — separate from the realtime AudioReactivePlayer used
//  by the default VisualizerView. One tick handler fans out to both the
//  visualizer and haptic cursors so all derived state moves on a single
//  playback clock.
//

import SwiftUI

struct AnalyzedPlayerView: View {
    let track: LibraryTrack
    let analysis: SongAnalysis
    /// Called when the user taps Re-analyze in the top-bar menu AFTER the
    /// confirmation dialog resolves. The player dismisses itself before
    /// calling this so the parent can safely replace the cached analysis
    /// without the player observing a half-written state.
    var onRequestReanalyze: (() -> Void)? = nil

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var audioReactivePlayer: AudioReactivePlayer
    @Environment(\.dismiss) private var dismiss

    // @Observable classes can be stored in @State for view-local ownership.
    @State private var player = AudioPlayer()
    @State private var visualizer: VisualizerState? = nil
    @State private var haptics = HapticEngine()
    @State private var onsetController: OnsetParticleController? = nil
    @State private var beatScheduler: BeatScheduler? = nil

    @State private var loadError: String? = nil
    @State private var didStart: Bool = false
    @State private var showReanalyzeConfirmation: Bool = false

    var body: some View {
        ZStack {
            BiomePaletteBackground(
                weights: visualizer?.biomeWeights ?? BiomeWeights(),
                beatPulse: visualizer?.beatPulse ?? 0
            )
            .ignoresSafeArea()

            QuadrantBiomeLayer(
                weights: visualizer?.biomeWeights ?? BiomeWeights(),
                beatPulse: visualizer?.beatPulse ?? 0
            )
            .ignoresSafeArea()

            if let viz = visualizer, let beats = beatScheduler {
                let palette = paletteColor(
                    v: viz.currentValence,
                    a: viz.currentArousal,
                    chromaHue: viz.currentHue,
                    chromaStrength: viz.currentChromaStrength
                )
                let paletteSecondary = paletteColor(
                    v: viz.currentValence,
                    a: viz.currentArousal,
                    hueShift: 0.08,
                    brightnessScale: 0.55,
                    saturationScale: 0.8,
                    chromaHue: viz.currentHue,
                    chromaStrength: viz.currentChromaStrength
                )

                AuroraRibbons(
                    visualizer: viz,
                    paletteColor: palette,
                    paletteSecondary: paletteSecondary
                )

                ScreenEdgeGlow(
                    visualizer: viz,
                    paletteColor: palette,
                    paletteSecondary: paletteSecondary
                )

                CymaticCenter(
                    visualizer: viz,
                    scheduler: beats,
                    paletteColor: palette,
                    paletteSecondary: paletteSecondary
                )
                .padding(.horizontal, 24)

                FluxHaloLayer(visualizer: viz, paletteColor: paletteSecondary)
                    .ignoresSafeArea()

                CentroidSparkleLayer(visualizer: viz, paletteColor: palette)
                    .ignoresSafeArea()

                if let controller = onsetController {
                    OnsetParticleLayer(controller: controller)
                        .allowsHitTesting(false)
                        .ignoresSafeArea()
                }

                BeatFlashLayer(scheduler: beats, paletteColor: palette)

                BassFloorView(
                    scheduler: beats,
                    palettePrimary: palette,
                    paletteSecondary: paletteSecondary
                )
            } else if let controller = onsetController {
                // Fallback: before the scheduler is built, still render onsets.
                OnsetParticleLayer(controller: controller)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }

            if let error = loadError {
                ContentUnavailableView(
                    "Can't play this track",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .foregroundStyle(.white)
            } else {
                content
            }
        }
        .preferredColorScheme(.dark)
        .navigationBarBackButtonHidden(true)
        .task {
            await start()
        }
        .onDisappear {
            player.pause()
            player.stop()
            haptics.stop()
        }
    }

    // MARK: - Layout

    private var content: some View {
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

    private var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text("\(Int(analysis.bpm.rounded())) BPM")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(SoundSeenTheme.purpleAccent.opacity(0.45),
                                    in: Capsule())

                    if let label = currentSectionLabelText {
                        Text(label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.82))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.14),
                                        in: Capsule())
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
                Image(systemName: "ellipsis.circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .accessibilityLabel("Track options")
        }
        .confirmationDialog(
            "Re-analyze this track?",
            isPresented: $showReanalyzeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Re-analyze", role: .destructive) {
                dismiss()
                onRequestReanalyze?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This discards the existing analysis and uploads the track again. Takes ~5\u{2013}15 seconds.")
        }
    }

    private var transport: some View {
        VStack(spacing: 12) {
            let total = max(analysis.durationSeconds, 0.001)
            let current = min(max(player.currentTime, 0), total)
            let skylineColor = paletteColor(
                v: visualizer?.currentValence ?? 0.5,
                a: visualizer?.currentArousal ?? 0.5,
                chromaHue: visualizer?.currentHue ?? 0,
                chromaStrength: visualizer?.currentChromaStrength ?? 0
            )

            BeatRibbonView(
                beats: analysis.beatEvents,
                currentTime: player.currentTime
            )
            .frame(height: 36)

            SectionTimelineView(
                sections: analysis.sections,
                currentTime: player.currentTime,
                totalDuration: analysis.durationSeconds
            )
            .frame(height: 54)

            EnergySkyline(
                analysis: analysis,
                currentTime: player.currentTime,
                paletteColor: skylineColor
            )

            Slider(
                value: Binding(
                    get: { current },
                    set: { player.seek(to: $0) }
                ),
                in: 0...total
            )
            .tint(SoundSeenTheme.purpleAccent)

            HStack {
                Text(formatTime(current))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(formatTime(total))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
            }

            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64, weight: .regular))
                    .foregroundStyle(.white)
                    .shadow(color: SoundSeenTheme.purpleAccent.opacity(0.6), radius: 18, y: 6)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
    }

    // MARK: - Lifecycle

    private func start() async {
        guard !didStart else { return }
        didStart = true

        // Release the other engine so this screen has an unobstructed audio
        // session. AudioReactivePlayer has no explicit stop(), but toggling
        // playback to paused cedes output; the shared AVAudioSession is then
        // free for our AudioPlayer (AVAudioPlayer).
        if audioReactivePlayer.isPlaying {
            audioReactivePlayer.togglePlayPause()
        }

        guard let audioURL = library.playbackURL(for: track) else {
            loadError = "Missing audio file for \"\(track.title)\"."
            return
        }

        let viz = VisualizerState(analysis: analysis)
        visualizer = viz

        let onsets = OnsetParticleController(onsets: analysis.onsetEvents)
        onsetController = onsets

        let beats = BeatScheduler(beats: analysis.beatEvents)
        beatScheduler = beats

        do {
            try player.load(url: audioURL)
        } catch {
            loadError = "Couldn't load audio: \(error.localizedDescription)"
            return
        }

        haptics.start()
        haptics.prepare(beats: analysis.beatEvents)
        haptics.setEnabled(true)

        player.removeAllTickHandlers()
        player.addTickHandler { [weak viz, weak haptics, weak onsets, weak beats] prev, now in
            // AudioPlayer.handleTick runs on the main actor, so these
            // @MainActor calls are safe without an explicit Task hop.
            MainActor.assumeIsolated {
                viz?.update(prevTime: prev, currentTime: now)
                haptics?.tick(prevTime: prev, currentTime: now)
                beats?.tick(prevTime: prev, currentTime: now)
                if let viz, let onsets {
                    onsets.tick(
                        prevTime: prev,
                        currentTime: now,
                        valence: viz.currentValence,
                        arousal: viz.currentArousal
                    )
                }
            }
        }

        // Initial frame so the palette doesn't show a default color before
        // the first display-link tick.
        viz.update(prevTime: 0, currentTime: 0)
    }

    // MARK: - Helpers

    private var currentSectionLabelText: String? {
        guard let label = visualizer?.currentSectionLabel, !label.isEmpty else {
            return nil
        }
        return label.capitalized
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Same V/A → HSB formula used in BiomePaletteBackground so foreground
    /// layers (cymatic center, beat flash, bass floor, flux halos, sparkles)
    /// visually match the atmosphere. `hueShift` / scales derive secondary
    /// palette colors. `chromaHue` + `chromaStrength` (both optional; default
    /// to no effect) blend the mood hue toward the song's current perceptual
    /// hue when the passage is tonal, and desaturate when it's noisy — so
    /// the *color* of the scene reflects musical content, not just emotion.
    private func paletteColor(
        v: Double,
        a: Double,
        hueShift: Double = 0,
        brightnessScale: Double = 1.0,
        saturationScale: Double = 1.0,
        chromaHue: Double = 0,
        chromaStrength: Double = 0
    ) -> Color {
        let vc = max(0.0, min(1.0, v))
        let ac = max(0.0, min(1.0, a))
        let moodH = lerpPalette(0.55, 0.92, vc)
        // Chroma blend: cap at 0.7 so mood still contributes even on
        // strongly tonal passages — avoids the palette feeling unmoored
        // from the emotion when the song modulates through a bright key.
        let chromaWeight = max(0.0, min(0.7, chromaStrength * 0.65))
        let chromaH = chromaHue.truncatingRemainder(dividingBy: 1.0)
        let blendedH = hueBlend(from: moodH, to: (chromaH < 0 ? chromaH + 1 : chromaH), t: chromaWeight)

        // Saturation tracks tonal strength — noisy passages desaturate
        // visibly (0.55× floor), tonal passages punch up to 1.0×.
        let chromaSatBoost = 0.55 + 0.45 * max(0.0, min(1.0, chromaStrength))
        let s = lerpPalette(0.45, 1.00, ac) * saturationScale * chromaSatBoost
        let b = lerpPalette(0.45, 0.85, ac) * brightnessScale
        var hue = (blendedH + hueShift).truncatingRemainder(dividingBy: 1.0)
        if hue < 0 { hue += 1 }
        return Color(
            hue: hue,
            saturation: max(0.0, min(1.0, s)),
            brightness: max(0.0, min(1.0, b))
        )
    }

    /// Shortest-path hue interpolation on the unit circle. Straight linear
    /// lerp on [0, 1] would take the long way around for hues on opposite
    /// sides (e.g. 0.05 → 0.95 would pass through yellow/green instead of
    /// through red). Wraps the delta into [−0.5, 0.5] before blending.
    private func hueBlend(from a: Double, to b: Double, t: Double) -> Double {
        var delta = b - a
        if delta > 0.5 { delta -= 1.0 }
        if delta < -0.5 { delta += 1.0 }
        var result = a + delta * t
        result = result.truncatingRemainder(dividingBy: 1.0)
        if result < 0 { result += 1 }
        return result
    }

    private func lerpPalette(_ a: Double, _ b: Double, _ t: Double) -> Double {
        let c = max(0.0, min(1.0, t))
        return a + (b - a) * c
    }
}

//
//  LiveView.swift
//  SoundSeen
//
//  Live-microphone entry point. Parallel to AnalyzedPlayerView but driven
//  by LiveAudioEngine instead of a preanalyzed SongAnalysis. Reuses the
//  same VisualizerRoot + HapticVocabulary + DropChoreography / SceneNarrative
//  stack — the narrative layers stay dormant because live mode has no
//  section labels for them to fire on.
//

import SwiftUI

#if os(iOS)
import AVFoundation
#endif

struct LiveView: View {
    @State private var engine = LiveAudioEngine()
    @State private var visualizer = VisualizerState(liveBandNames: [
        "sub_bass", "bass", "low_mid", "mid",
        "upper_mid", "presence", "brilliance", "ultra_high",
    ])
    @State private var haptics = HapticVocabulary()
    @State private var choreography: DropChoreography?
    @State private var narrative: SceneNarrative?

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if let choreo = choreography, let nar = narrative {
                VisualizerRoot(
                    state: visualizer,
                    choreography: choreo,
                    narrative: nar
                )
            } else {
                Color.black
            }

            overlay
        }
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
        .task {
            if choreography == nil { choreography = DropChoreography(state: visualizer) }
            if narrative == nil { narrative = SceneNarrative(state: visualizer) }
            engine.refreshPermissionState()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                Task { await engine.stop() }
            }
        }
        .onDisappear {
            Task { await engine.stop() }
        }
    }

    // MARK: - Overlay

    @ViewBuilder
    private var overlay: some View {
        switch overlayKind {
        case .prePermission:
            prePermissionCard
        case .denied:
            deniedCard
        case .starting:
            ProgressView().tint(.white)
        case .running:
            runningChrome
        case .failed(let msg):
            failedCard(message: msg)
        }
    }

    private enum OverlayKind {
        case prePermission, denied, starting, running
        case failed(String)
    }

    private var overlayKind: OverlayKind {
        if case .failed(let msg) = engine.engineState { return .failed(msg) }
        if engine.engineState == .running { return .running }
        if engine.engineState == .starting { return .starting }
        switch engine.permissionState {
        case .denied: return .denied
        case .unknown, .granted: return .prePermission
        }
    }

    // MARK: - States

    private var prePermissionCard: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 68, weight: .light))
                .foregroundStyle(.white.opacity(0.9))
            VStack(spacing: 8) {
                Text("Let SoundSeen listen")
                    .font(.title2.weight(.semibold))
                Text("Point your phone at a speaker or let it hear the room. Your audio stays on-device for visuals and haptics; only short 2-second clips go to the server for emotion.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Button {
                Task { await start() }
            } label: {
                Text("Start Live")
                    .font(.headline)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 32)
                    .background(.white.opacity(0.95), in: .capsule)
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 32)
        .foregroundStyle(.white)
    }

    private var deniedCard: some View {
        VStack(spacing: 18) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.85))
            Text("Microphone access denied")
                .font(.title3.weight(.semibold))
            Text("Enable the microphone in Settings to use live mode.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            #if os(iOS)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            #endif
        }
        .foregroundStyle(.white)
    }

    private func failedCard(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Live mode unavailable")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try Again") {
                Task { await start() }
            }
            .buttonStyle(.bordered)
        }
        .foregroundStyle(.white)
    }

    // MARK: - Running chrome

    private var runningChrome: some View {
        VStack {
            HStack(alignment: .top) {
                liveIndicator
                Spacer()
                stopButton
            }
            .padding(.top, 60)
            .padding(.horizontal, 20)

            Spacer()

            LiveCaption(state: visualizer, lockedBPM: engine.lockedBPM)
                .padding(.bottom, 48)
        }
        .allowsHitTesting(true)
    }

    private var liveIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.red)
                .frame(width: 9, height: 9)
                .shadow(color: .red.opacity(0.6), radius: 4)
            Text("LIVE")
                .font(.caption2.weight(.bold))
                .kerning(1.5)
                .foregroundStyle(.white)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(.black.opacity(0.35), in: .capsule)
        .accessibilityLabel("Live microphone active")
    }

    private var stopButton: some View {
        Button {
            Task { await engine.stop() }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.black.opacity(0.45), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop live")
    }

    // MARK: - Lifecycle

    private func start() async {
        if choreography == nil { choreography = DropChoreography(state: visualizer) }
        if narrative == nil { narrative = SceneNarrative(state: visualizer) }
        await engine.start(visualizer: visualizer, haptics: haptics)
    }
}

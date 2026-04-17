//
//  BeatFlashLayer.swift
//  SoundSeen
//
//  Full-screen radial flash gated to strong beats. Caps at 0.28 alpha and
//  requires 0.3s between flashes to prevent visual fatigue — effectively
//  only peak downbeats fire this.
//

import SwiftUI
import QuartzCore

struct BeatFlashLayer: View {
    let scheduler: BeatScheduler
    let paletteColor: Color

    @State private var currentOpacity: Double = 0.0
    @State private var lastFlashAt: TimeInterval = 0

    var body: some View {
        RadialGradient(
            colors: [paletteColor.opacity(currentOpacity), .clear],
            center: .center,
            startRadius: 0,
            endRadius: 600
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            scheduler.subscribe { beat in
                handleBeat(beat)
            }
        }
    }

    private func handleBeat(_ beat: BeatEvent) {
        let now = CACurrentMediaTime()
        guard beat.intensity > 0.7, (now - lastFlashAt) > 0.3 else { return }
        lastFlashAt = now

        withAnimation(.easeOut(duration: 0.06)) {
            currentOpacity = 0.28
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(.easeOut(duration: 0.18)) {
                currentOpacity = 0.0
            }
        }
    }
}

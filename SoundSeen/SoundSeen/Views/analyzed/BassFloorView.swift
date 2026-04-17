//
//  BassFloorView.swift
//  SoundSeen
//
//  Bottom-edge horizontal bar whose height jumps proportional to
//  beat.bassIntensity on every beat, then springs back to a 4pt baseline.
//  Downbeats add a brief magenta overlay for emphasis.
//

import SwiftUI

struct BassFloorView: View {
    let scheduler: BeatScheduler
    let palettePrimary: Color
    let paletteSecondary: Color

    @State private var currentHeight: CGFloat = 4
    @State private var isDownbeatFlash: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [paletteSecondary, palettePrimary, paletteSecondary],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: currentHeight)
                .overlay(
                    isDownbeatFlash
                        ? Color(red: 0.95, green: 0.35, blue: 0.8).opacity(0.4)
                        : Color.clear
                )
        }
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
        .onAppear {
            scheduler.subscribe { beat in
                handleBeat(beat)
            }
        }
    }

    private func handleBeat(_ beat: BeatEvent) {
        let bass = max(0.0, min(1.0, beat.bassIntensity))
        let targetHeight: CGFloat = 4 + CGFloat(80.0 * bass)

        withAnimation(.easeOut(duration: 0.04)) {
            currentHeight = targetHeight
        }

        if beat.isDownbeat {
            isDownbeatFlash = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                isDownbeatFlash = false
            }
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            withAnimation(.interpolatingSpring(duration: 0.2, bounce: 0.15)) {
                currentHeight = 4
            }
        }
    }
}

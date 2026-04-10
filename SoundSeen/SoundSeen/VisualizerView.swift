//
//  VisualizerView.swift
//  SoundSeen
//

import SwiftUI

struct VisualizerView: View {
    let onBack: () -> Void

    @EnvironmentObject private var player: AudioReactivePlayer

    var body: some View {
        ZStack {
            layeredBackground

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 4)
                visualizerCore
                Spacer(minLength: 28)
                nowPlayingSection
                Spacer(minLength: 18)
                playbackControls
            }
            .padding(.horizontal, 20)
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                onBack()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                    Text("Library")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(SoundSeenTheme.purpleAccent)
            }
            .accessibilityLabel("Back to library")

            Spacer()

            Text("Now Playing")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.top, 4)
    }

    private var layeredBackground: some View {
        ZStack {
            SoundSeenBackground()

            // Deep cyan / magenta wash
            RadialGradient(
                colors: [
                    Color(red: 0.1, green: 0.45, blue: 0.55).opacity(0.35 + Double(player.beatPulse) * 0.15),
                    Color.clear,
                ],
                center: .topLeading,
                startRadius: 20,
                endRadius: 380
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [
                    Color(red: 0.95, green: 0.35, blue: 0.45).opacity(0.22 + Double(player.beatPulse) * 0.2),
                    Color.clear,
                ],
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: 420
            )
            .ignoresSafeArea()

            // Floating orbs (depth)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(0..<6, id: \.self) { i in
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        orbColor(index: i).opacity(0.35 + Double(player.beatPulse) * 0.2),
                                        Color.clear,
                                    ],
                                    center: .center,
                                    startRadius: 4,
                                    endRadius: 80 + CGFloat(i) * 12
                                )
                            )
                            .frame(width: 120 + CGFloat(i * 18), height: 120 + CGFloat(i * 18))
                            .offset(
                                x: CGFloat(sin(t * 0.4 + Double(i))) * 40,
                                y: CGFloat(cos(t * 0.35 + Double(i) * 0.7)) * 50
                            )
                            .blur(radius: 28)
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func orbColor(index: Int) -> Color {
        let palette: [Color] = [
            Color(red: 0.55, green: 0.35, blue: 1.0),
            Color(red: 0.2, green: 0.85, blue: 0.95),
            Color(red: 1.0, green: 0.45, blue: 0.55),
            Color(red: 0.95, green: 0.65, blue: 0.25),
            Color(red: 0.45, green: 0.55, blue: 1.0),
            SoundSeenTheme.purpleAccent,
        ]
        return palette[index % palette.count]
    }

    private var visualizerCore: some View {
        ZStack {
            RadialGlow(beatPulse: player.beatPulse, bass: player.bassEnergy)
                .frame(maxWidth: 440, maxHeight: 440)

            if let err = player.loadError {
                Text(err)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.orange.opacity(0.9))
                    .padding()
            } else {
                AudioSpectrumBarsView(
                    levels: player.barLevels,
                    beatPulse: player.beatPulse,
                    isPaused: !player.isPlaying
                )
                .frame(height: 212)
                .accessibilityLabel("Music spectrum visualizer driven by audio")
            }
        }
    }

    private var nowPlayingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(player.trackTitle.isEmpty ? "—" : player.trackTitle)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)

            if !player.artistName.isEmpty {
                Text(player.artistName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
            }

            ProgressView(value: player.progress)
                .tint(
                    LinearGradient(
                        colors: [
                            Color(red: 0.3, green: 0.75, blue: 1.0),
                            SoundSeenTheme.purpleAccent,
                            Color(red: 1.0, green: 0.45, blue: 0.55),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .padding(.top, 4)
        }
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var playbackControls: some View {
        HStack(spacing: 0) {
            Button {
                player.restartFromBeginning()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start over")

            Spacer()

            Button {
                player.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    SoundSeenTheme.purpleAccent,
                                    Color(red: 0.38, green: 0.20, blue: 0.85),
                                    Color(red: 0.25, green: 0.55, blue: 1.0),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 76, height: 76)
                        .shadow(
                            color: SoundSeenTheme.purpleAccent.opacity(0.45 + Double(player.beatPulse) * 0.35),
                            radius: 14 + CGFloat(player.beatPulse * 10),
                            y: 5
                        )

                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Spacer()

            Button {
                // Single bundled track — no next item yet
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.plain)
            .disabled(true)
            .accessibilityLabel("Next track unavailable")
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

// MARK: - Glow (reactive)

private struct RadialGlow: View {
    let beatPulse: CGFloat
    let bass: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.55 + Double(bass) * 0.25),
                            SoundSeenTheme.purpleAccent.opacity(0.45 + Double(beatPulse) * 0.25),
                            Color(red: 0.2, green: 0.75, blue: 0.95).opacity(0.25),
                            Color.clear,
                        ],
                        center: .center,
                        startRadius: 8,
                        endRadius: 200 + CGFloat(beatPulse * 40)
                    )
                )
                .blur(radius: 35)

            Circle()
                .stroke(
                    AngularGradient(
                        colors: [
                            Color(red: 0.3, green: 0.9, blue: 1.0),
                            SoundSeenTheme.purpleAccent,
                            Color(red: 1.0, green: 0.4, blue: 0.55),
                            Color(red: 0.95, green: 0.7, blue: 0.2),
                            Color(red: 0.3, green: 0.9, blue: 1.0),
                        ],
                        center: .center,
                        angle: .degrees(0)
                    ),
                    lineWidth: 2
                )
                .opacity(0.35 + Double(beatPulse) * 0.4)
                .frame(width: 260 + CGFloat(beatPulse * 30), height: 260 + CGFloat(beatPulse * 30))
                .blur(radius: 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Bars (audio-driven)

private struct AudioSpectrumBarsView: View {
    let levels: [CGFloat]
    let beatPulse: CGFloat
    let isPaused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isPaused)) { timeline in
            GeometryReader { geo in
                let barCount = max(1, levels.count)
                let spacing: CGFloat = 2
                let totalSpacing = spacing * CGFloat(max(0, barCount - 1))
                let barW = max(2, (geo.size.width - totalSpacing) / CGFloat(barCount))
                let t = timeline.date.timeIntervalSinceReferenceDate

                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(0..<barCount, id: \.self) { i in
                        let base = i < levels.count ? levels[i] : 0.1
                        let wobble = isPaused ? 0.04 : sin(t * 3 + Double(i) * 0.2) * 0.04
                        let boosted = min(1, max(0.05, base + CGFloat(wobble) * (0.15 + beatPulse * 0.25)))
                        SpectrumBar(
                            intensity: boosted,
                            width: barW,
                            maxHeight: geo.size.height,
                            index: i,
                            barCount: barCount,
                            beatPulse: beatPulse
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

private struct SpectrumBar: View {
    let intensity: CGFloat
    let width: CGFloat
    let maxHeight: CGFloat
    let index: Int
    let barCount: Int
    let beatPulse: CGFloat

    var body: some View {
        let t = CGFloat(index) / CGFloat(max(1, barCount - 1))
        let hueShift = t * 0.35 + Double(beatPulse) * 0.08
        let bottom = Color(
            hue: 0.72 + hueShift * 0.08,
            saturation: 0.85,
            brightness: 0.95 + Double(intensity) * 0.05
        )
        let mid = Color(
            hue: 0.88 + hueShift * 0.06,
            saturation: 0.75,
            brightness: 1.0
        )
        let top = Color(
            hue: 0.08 + hueShift * 0.1,
            saturation: 0.65,
            brightness: 1.0
        )

        RoundedRectangle(cornerRadius: width / 2, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [bottom, mid, top],
                    startPoint: .bottom,
                    endPoint: .top
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: width / 2, style: .continuous)
                    .stroke(Color.white.opacity(0.25 + Double(intensity) * 0.35), lineWidth: 0.5)
            }
            .frame(width: width, height: max(5, intensity * maxHeight))
            .shadow(color: bottom.opacity(0.55 + Double(beatPulse) * 0.25), radius: 6 + CGFloat(beatPulse * 6), y: -2)
    }
}

#Preview {
    VisualizerView(onBack: {})
        .environmentObject(AudioReactivePlayer())
}

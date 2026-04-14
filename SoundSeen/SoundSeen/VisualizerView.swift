//
//  VisualizerView.swift
//  SoundSeen
//

import SwiftUI

struct VisualizerView: View {
    let onBack: () -> Void

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioReactivePlayer
    @State private var scrubProgress: Double = 0
    @State private var isScrubbing = false
    @State private var showQueueSheet = false
    @State private var selectedThemeMode: VisualThemeMode = .adaptive

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
        .sheet(isPresented: $showQueueSheet) {
            QueueSheet(player: player, onPickIndex: { index in
                player.jumpToQueueIndex(index, libraryTracks: library.tracks)
                showQueueSheet = false
            })
        }
        .onAppear {
            scrubProgress = player.progress
        }
        .onChange(of: player.activeTrackId) { _, _ in
            scrubProgress = player.progress
        }
        .onChange(of: player.progress) { _, newVal in
            if !isScrubbing {
                scrubProgress = newVal
            }
        }
        .onChange(of: player.isPlaying) { _, _ in
            if !isScrubbing {
                scrubProgress = player.progress
            }
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

            HStack(spacing: 10) {
                Text("Now Playing")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.45))

                Menu {
                    ForEach(VisualThemeMode.allCases, id: \.self) { mode in
                        Button {
                            selectedThemeMode = mode
                        } label: {
                            Label(mode.label, systemImage: selectedThemeMode == mode ? "checkmark.circle.fill" : "circle")
                        }
                    }
                } label: {
                    Image(systemName: "paintpalette.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(themeAccent.opacity(0.95))
                        .padding(8)
                        .background(themeAccent.opacity(0.18))
                        .clipShape(Circle())
                }
                .accessibilityLabel("Theme mode")
            }
        }
        .padding(.top, 4)
    }

    private var layeredBackground: some View {
        ZStack {
            SoundSeenBackground()

            // Deep cyan / magenta wash
            RadialGradient(
                colors: [
                    themePrimary.opacity(0.28 + Double(player.beatPulse) * 0.16 + Double(player.perceptualLoudness) * 0.18),
                    Color.clear,
                ],
                center: .topLeading,
                startRadius: 20,
                endRadius: 380
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [
                    themeSecondary.opacity(0.2 + Double(player.beatPulse) * 0.2 + Double(player.perceptualLoudness) * 0.14),
                    Color.clear,
                ],
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: 420
            )
            .ignoresSafeArea()

            // Floating orbs (depth)
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
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
            themePrimary,
            themeSecondary,
            themeAccent,
            themePrimary.opacity(0.9),
            themeSecondary.opacity(0.9),
            SoundSeenTheme.purpleAccent.opacity(0.92),
        ]
        return palette[index % palette.count]
    }

    private var visualizerCore: some View {
        ZStack {
            RadialGlow(
                beatPulse: player.beatPulse,
                bass: player.bassEnergy,
                timbreAir: player.timbreAir,
                sheen: player.timbreSheen
            )
            .frame(maxWidth: 440, maxHeight: 440)
            .opacity(0.22)

            DropCinematicOverlay(
                section: currentSection,
                beatPulse: player.beatPulse,
                bass: player.bassEnergy,
                isPlaying: player.isPlaying,
                countdownToDrop: nextDropCountdown
            )
            .frame(maxWidth: 460, maxHeight: 460)
            .allowsHitTesting(false)

            if let err = player.loadError {
                Text(err)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.orange.opacity(0.9))
                    .padding()
            } else {
                TimbreSpaceVisualizer(isPaused: !player.isPlaying)
                    .frame(minHeight: 320, maxHeight: 380)
                    .hueRotation(.degrees(themeHueRotation))
                    .saturation(1 + themeSaturationBoost + Double(player.perceptualLoudness) * 0.22)
                    .contrast(1 + themeContrastBoost)
                    .accessibilityLabel("3D spectrum around the sound field")
            }
        }
    }

    private var nowPlayingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.trackTitle.isEmpty ? "—" : player.trackTitle)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                if !player.artistName.isEmpty {
                    Text(player.artistName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }

            semanticOverlay
            progressTimeline
        }
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var semanticOverlay: some View {
        HStack(spacing: 10) {
            ForEach(activeSemanticKinds, id: \.rawValue) { kind in
                Label(kind.rawValue, systemImage: symbol(for: kind))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent(for: kind).opacity(0.98))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(accent(for: kind).opacity(0.18))
                    .overlay(
                        Capsule()
                            .stroke(accent(for: kind).opacity(0.45), lineWidth: 1)
                    )
                    .clipShape(Capsule())
            }

            if isEnergyFalling {
                Label("Energy Falling", systemImage: "arrow.down.right.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.72, green: 0.86, blue: 1.0).opacity(0.98))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(red: 0.34, green: 0.52, blue: 0.92).opacity(0.16))
                    .overlay(
                        Capsule()
                            .stroke(Color(red: 0.62, green: 0.8, blue: 1.0).opacity(0.42), lineWidth: 1)
                    )
                    .clipShape(Capsule())
            }

            Text(sectionSubtitle)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.64))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }

    private var currentSection: SongStructureKind {
        if isDropActive {
            return .drop
        }
        if isBuildupActive {
            return .buildup
        }
        return .verse
    }

    private var activeSemanticKinds: [SongStructureKind] {
        var kinds: [SongStructureKind] = [.verse]
        if isBuildupActive {
            kinds.append(.buildup)
        }
        if isDropActive {
            kinds = [.drop]
        }
        return kinds
    }

    private var nextDropCountdown: TimeInterval? {
        let now = player.currentTimeSeconds
        guard let nextDrop = player.structureMarkers
            .filter({ $0.kind == .drop && $0.timeSeconds >= now })
            .map(\.timeSeconds)
            .min()
        else {
            return nil
        }
        let cd = nextDrop - now
        // Only show a countdown when the drop is truly imminent.
        guard cd > 0, cd <= 16 else { return nil }
        return cd
    }

    private var isDropActive: Bool {
        let now = player.currentTimeSeconds
        let dropHold: TimeInterval = 6.0
        let markerDrop = player.structureMarkers.contains {
            $0.kind == .drop && now >= $0.timeSeconds && now <= $0.timeSeconds + dropHold
        }
        let realtimeDrop = player.dropLikelihood > 0.56 && player.bassEnergy > 0.22 && player.beatPulse > 0.3
        return markerDrop || realtimeDrop
    }

    private var isBuildupActive: Bool {
        if isDropActive { return false }
        let now = player.currentTimeSeconds
        // Avoid labeling the very start of a track as "Buildup" just because loudness is rising.
        // Real buildups are typically contextual and appear after an intro/verse has established.
        if now < 8.0 { return false }
        let buildupStarts = player.structureMarkers
            .filter { $0.kind == .buildup && $0.timeSeconds <= now }
            .map(\.timeSeconds)
            .max()
        let nextDrop = player.structureMarkers
            .filter { $0.kind == .drop && $0.timeSeconds >= now }
            .map(\.timeSeconds)
            .min()

        if let start = buildupStarts, let drop = nextDrop {
            // If energy is clearly falling and the drop is not imminent, prefer "Energy Falling".
            if player.loudnessFall > 0.25, drop - now > 3.0 {
                return false
            }
            return now >= start && now < drop
        }

        // Fallback 1: if scanner missed explicit buildup boundaries, treat pre-drop as buildup.
        if let drop = nextDrop,
           drop - now <= 12, drop - now > 0,
           player.loudnessRise > 0.16 || drop - now <= 3.0 {
            return true
        }
        // Fallback 2: rising loudness trend (lets Verse + Buildup happen early in the track).
        if player.loudnessFall > 0.24 {
            return false
        }
        return player.loudnessRise > 0.26 && player.perceptualLoudness > 0.12
    }

    private func symbol(for kind: SongStructureKind) -> String {
        switch kind {
        case .verse: return "music.note"
        case .buildup: return "arrow.up.right.circle.fill"
        case .drop: return "bolt.fill"
        }
    }

    private func accent(for kind: SongStructureKind) -> Color {
        switch kind {
        case .verse: return Color(red: 0.45, green: 0.8, blue: 1.0)
        case .buildup: return Color(red: 1.0, green: 0.72, blue: 0.26)
        case .drop: return Color(red: 1.0, green: 0.35, blue: 0.55)
        }
    }

    private var sectionSubtitle: String {
        switch currentSection {
        case .verse:
            if isEnergyFalling {
                return "Energy falling"
            }
            return "Steady groove"
        case .buildup:
            if let t = nextDropCountdown, t > 0, t < 16 {
                return String(format: "Drop in %.1fs", t)
            }
            return "Energy rising"
        case .drop:
            return "Impact moment"
        }
    }

    private var isEnergyFalling: Bool {
        !isDropActive && !isBuildupActive && player.loudnessFall > 0.22 && player.loudnessRise < 0.28
    }

    private var effectiveTheme: VisualTheme {
        switch selectedThemeMode {
        case .adaptive:
            if currentSection == .drop { return .pulsefire }
            if currentSection == .buildup { return .pulsefire }
            if player.timbreAir > 0.62 { return .aurora }
            return .nocturne
        case .aurora:
            return .aurora
        case .pulsefire:
            return .pulsefire
        case .nocturne:
            return .nocturne
        }
    }

    private var themePrimary: Color { effectiveTheme.primary }
    private var themeSecondary: Color { effectiveTheme.secondary }
    private var themeAccent: Color { effectiveTheme.accent }
    private var themeHueRotation: Double { effectiveTheme.hueRotation }
    private var themeSaturationBoost: Double { effectiveTheme.saturationBoost }
    private var themeContrastBoost: Double { effectiveTheme.contrastBoost }

    private var progressTimeline: some View {
        VStack(spacing: 6) {
            TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !player.isPlaying && !isScrubbing)) { _ in
                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubProgress : player.progress },
                        set: { scrubProgress = $0 }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        player.setScrubbing(editing)
                        if editing {
                            scrubProgress = player.progress
                        } else {
                            player.seek(toProgress: scrubProgress)
                            player.endScrubSession()
                        }
                    }
                )
                .tint(.white)
            }

            HStack {
                Text(player.formattedCurrentTime)
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(player.formattedDuration)
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.top, 2)
        }
    }

    private var playbackControls: some View {
        let sideInactive = Color(white: 0.45)
        let sideActive = Color.white.opacity(0.92)

        return HStack(spacing: 0) {
            Button {
                guard !library.tracks.isEmpty else { return }
                player.toggleShuffle(allTracks: library.tracks)
            } label: {
                VStack(spacing: 5) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(player.isShuffleEnabled ? SoundSeenTheme.purpleAccent : sideInactive)
                        .shadow(
                            color: player.isShuffleEnabled ? SoundSeenTheme.purpleAccent.opacity(0.9) : .clear,
                            radius: player.isShuffleEnabled ? 12 : 0
                        )
                    if player.isShuffleEnabled {
                        Circle()
                            .fill(SoundSeenTheme.purpleAccent)
                            .frame(width: 4, height: 4)
                            .shadow(color: SoundSeenTheme.purpleAccent.opacity(0.85), radius: 4)
                    } else {
                        Color.clear.frame(width: 4, height: 4)
                    }
                }
                .frame(width: 52, height: 58)
            }
            .buttonStyle(.plain)
            .disabled(library.tracks.isEmpty)
            .accessibilityLabel(player.isShuffleEnabled ? "Shuffle on" : "Shuffle off")

            Spacer()

            Button {
                player.playPreviousFromLibrary()
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(player.hasPreviousTrack ? sideActive : sideInactive)
                    .frame(width: 48, height: 56)
            }
            .buttonStyle(.plain)
            .disabled(!player.hasPreviousTrack)
            .accessibilityLabel("Previous track")

            Spacer()

            Button {
                player.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 72, height: 72)
                        .shadow(color: .black.opacity(0.28), radius: 10, y: 4)

                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.black)
                        .offset(x: player.isPlaying ? 0 : 2)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Spacer()

            Button {
                player.playNextFromLibrary()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(player.hasNextTrack ? sideActive : sideInactive)
                    .frame(width: 48, height: 56)
            }
            .buttonStyle(.plain)
            .disabled(!player.hasNextTrack)
            .accessibilityLabel(player.hasNextTrack ? "Next track" : "Next track unavailable")

            Spacer()

            Button {
                showQueueSheet = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(sideActive)
                    .frame(width: 52, height: 56)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Upcoming songs")
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

// MARK: - Queue sheet

private struct QueueSheet: View {
    @ObservedObject var player: AudioReactivePlayer
    var onPickIndex: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if player.orderedQueueTracks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("Queue is empty")
                            .font(.headline)
                        Text("Play a song from your library to build a queue.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(Array(player.orderedQueueTracks.enumerated()), id: \.offset) { index, track in
                                queueRow(
                                    index: index,
                                    track: track,
                                    isCurrent: index == player.currentQueueIndex
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onPickIndex(index)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func queueRow(index: Int, track: LibraryTrack, isCurrent: Bool) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Text("\(index + 1)")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if isCurrent {
                Text("Playing")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SoundSeenTheme.purpleAccent)
            }

            Text(track.formattedDuration ?? "—")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Glow (reactive)

private struct RadialGlow: View {
    let beatPulse: CGFloat
    let bass: CGFloat
    /// High-frequency timbre share — shifts cool ↔ warm in the wash.
    var timbreAir: CGFloat = 0.5
    /// Spectral “shimmer” — widens the glow when the spectrum moves quickly.
    var sheen: CGFloat = 0

    var body: some View {
        let air = Double(timbreAir)
        let sh = Double(sheen)
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.55 + Double(bass) * 0.25),
                            Color(hue: 0.72 + air * 0.12, saturation: 0.55 + sh * 0.2, brightness: 0.92)
                                .opacity(0.45 + Double(beatPulse) * 0.25),
                            Color(red: 0.2 + air * 0.15, green: 0.75 - air * 0.2, blue: 0.95).opacity(0.25 + sh * 0.15),
                            Color.clear,
                        ],
                        center: .center,
                        startRadius: 8,
                        endRadius: 200 + CGFloat(beatPulse * 40) + CGFloat(sh * 35)
                    )
                )
                .blur(radius: 35)

            Circle()
                .stroke(
                    AngularGradient(
                        colors: [
                            Color(red: 0.3, green: 0.9, blue: 1.0),
                            SoundSeenTheme.purpleAccent,
                            Color(hue: 0.95 - air * 0.08, saturation: 0.75, brightness: 1),
                            Color(red: 0.95, green: 0.7, blue: 0.2),
                            Color(red: 0.3, green: 0.9, blue: 1.0),
                        ],
                        center: .center,
                        angle: .degrees(0)
                    ),
                    lineWidth: 2
                )
                .opacity(0.35 + Double(beatPulse) * 0.4 + sh * 0.2)
                .frame(width: 260 + CGFloat(beatPulse * 30), height: 260 + CGFloat(beatPulse * 30))
                .blur(radius: 1)
        }
        .allowsHitTesting(false)
    }
}

private struct DropCinematicOverlay: View {
    let section: SongStructureKind
    let beatPulse: CGFloat
    let bass: CGFloat
    let isPlaying: Bool
    let countdownToDrop: TimeInterval?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = Double(beatPulse)
            let low = Double(bass)
            let preDropTension: Double = {
                guard section == .buildup else { return 0 }
                guard let cd = countdownToDrop else { return 0.25 }
                let clamped = min(1, max(0, (8 - cd) / 8))
                return clamped
            }()

            ZStack {
                if section == .buildup {
                    Circle()
                        .stroke(
                            Color.white.opacity(0.16 + preDropTension * 0.24 + pulse * 0.18),
                            lineWidth: 2 + preDropTension * 4
                        )
                        .frame(width: 190 + preDropTension * 120, height: 190 + preDropTension * 120)
                        .scaleEffect(0.92 + preDropTension * 0.08 + sin(t * 6) * 0.01)
                        .blur(radius: 0.6)

                    Circle()
                        .fill(Color.black.opacity(0.08 + preDropTension * 0.12))
                        .frame(width: 220 + preDropTension * 130, height: 220 + preDropTension * 130)
                        .blendMode(.multiply)
                }

                if section == .drop {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.white.opacity(0.15 + pulse * 0.38 + low * 0.18),
                                    Color(red: 1.0, green: 0.35, blue: 0.6).opacity(0.09 + pulse * 0.16),
                                    Color.clear,
                                ],
                                center: .center,
                                startRadius: 8,
                                endRadius: 170 + CGFloat(pulse * 90)
                            )
                        )
                        .frame(width: 300 + CGFloat(low * 120), height: 300 + CGFloat(low * 120))
                        .scaleEffect(1.0 + CGFloat(pulse * 0.08))
                        .blendMode(.screen)
                }
            }
        }
    }
}

private enum VisualThemeMode: CaseIterable {
    case adaptive
    case aurora
    case pulsefire
    case nocturne

    var label: String {
        switch self {
        case .adaptive: return "Adaptive"
        case .aurora: return "Aurora"
        case .pulsefire: return "Pulsefire"
        case .nocturne: return "Nocturne"
        }
    }
}

private enum VisualTheme {
    case aurora
    case pulsefire
    case nocturne

    var primary: Color {
        switch self {
        case .aurora: return Color(red: 0.12, green: 0.78, blue: 0.88)
        case .pulsefire: return Color(red: 0.98, green: 0.33, blue: 0.45)
        case .nocturne: return Color(red: 0.35, green: 0.42, blue: 0.92)
        }
    }

    var secondary: Color {
        switch self {
        case .aurora: return Color(red: 0.55, green: 0.45, blue: 1.0)
        case .pulsefire: return Color(red: 1.0, green: 0.72, blue: 0.24)
        case .nocturne: return Color(red: 0.26, green: 0.8, blue: 0.98)
        }
    }

    var accent: Color {
        switch self {
        case .aurora: return Color(red: 0.56, green: 0.92, blue: 0.84)
        case .pulsefire: return Color(red: 1.0, green: 0.44, blue: 0.65)
        case .nocturne: return Color(red: 0.72, green: 0.58, blue: 1.0)
        }
    }

    var hueRotation: Double {
        switch self {
        case .aurora: return -8
        case .pulsefire: return 16
        case .nocturne: return 0
        }
    }

    var saturationBoost: Double {
        switch self {
        case .aurora: return 0.12
        case .pulsefire: return 0.2
        case .nocturne: return 0.08
        }
    }

    var contrastBoost: Double {
        switch self {
        case .aurora: return 0.04
        case .pulsefire: return 0.08
        case .nocturne: return 0.03
        }
    }
}

#Preview {
    VisualizerView(onBack: {})
        .environmentObject(LibraryStore())
        .environmentObject(AudioReactivePlayer())
}

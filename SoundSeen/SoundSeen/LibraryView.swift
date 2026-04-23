//
//  LibraryView.swift
//  SoundSeen
//
//  The app's home. Premium dark aesthetic — the visualizer is meant to
//  be the loudest thing in the app, so this screen restrains itself to
//  deep surfaces, one accent, and clean typography. Cards present
//  tracks as objects a user can reach into; taps go straight to the
//  analyzed player (no "Listen" tab).
//

import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var analysisStore: AnalysisStore
    @State private var query = ""
    @State private var analyzeTask = AnalyzeTask()
    @State private var analyzingTrackId: UUID? = nil
    @State private var trackPendingReanalysis: LibraryTrack? = nil
    @State private var showUploadSheet = false

    private var filtered: [LibraryTrack] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return library.tracks }
        return library.tracks.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: SSDesign.Space.xl) {
                        header
                            .padding(.top, SSDesign.Space.m)
                        searchField
                        if library.tracks.isEmpty {
                            emptyState
                        } else if filtered.isEmpty {
                            noSearchResults
                        } else {
                            tracksList
                        }
                    }
                    .padding(.horizontal, SSDesign.Space.xl)
                    .padding(.bottom, 60)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { trackId in
                analyzedPlayerDestination(for: trackId)
            }
            .sheet(isPresented: $showUploadSheet) {
                UploadView()
                    .environmentObject(library)
                    .environmentObject(analysisStore)
                    .presentationBackground(SSDesign.Palette.base)
            }
            .alert(
                "Analysis failed",
                isPresented: Binding(
                    get: { analyzeTask.errorMessage != nil },
                    set: { if !$0 { analyzeTask.reset() } }
                ),
                presenting: analyzeTask.errorMessage
            ) { _ in
                Button("OK", role: .cancel) { analyzeTask.reset() }
            } message: { msg in
                Text(msg)
            }
            .confirmationDialog(
                "Re-analyze this track?",
                isPresented: Binding(
                    get: { trackPendingReanalysis != nil },
                    set: { if !$0 { trackPendingReanalysis = nil } }
                ),
                titleVisibility: .visible,
                presenting: trackPendingReanalysis
            ) { track in
                Button("Re-analyze", role: .destructive) {
                    let target = track
                    trackPendingReanalysis = nil
                    Task { await reanalyze(track: target) }
                }
                Button("Cancel", role: .cancel) { trackPendingReanalysis = nil }
            } message: { track in
                Text("Discard the current analysis for \u{201C}\(track.title)\u{201D} and upload again. Takes ~5\u{2013}15 seconds.")
            }
        }
        .tint(SSDesign.Palette.accent)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: SSDesign.Space.l) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SoundSeen")
                    .font(SSDesign.Typography.display(36))
                    .foregroundStyle(SSDesign.Palette.textPrimary)
                Text("see music   ·   feel music")
                    .font(SSDesign.Typography.caption(11))
                    .kerning(2)
                    .textCase(.uppercase)
                    .foregroundStyle(SSDesign.Palette.textMuted)
            }

            Spacer(minLength: 0)

            Button {
                showUploadSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(
                        Circle().fill(SSDesign.Palette.accent)
                    )
                    .foregroundStyle(SSDesign.Palette.base)
            }
            .buttonStyle(.plain)
            .ssShadow(SSDesign.Shadow.card)
            .accessibilityLabel("Upload a song")
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: SSDesign.Space.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SSDesign.Palette.textMuted)
            TextField(
                "",
                text: $query,
                prompt: Text("Search tracks or artists")
                    .foregroundStyle(SSDesign.Palette.textMuted)
            )
            .font(SSDesign.Typography.body(15))
            .foregroundStyle(SSDesign.Palette.textPrimary)
            .tint(SSDesign.Palette.accent)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SSDesign.Palette.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, SSDesign.Space.l)
        .padding(.vertical, SSDesign.Space.m)
        .background(
            Capsule().fill(SSDesign.Palette.surfaceRaised)
                .overlay(Capsule().stroke(SSDesign.Palette.hairline, lineWidth: 0.5))
        )
    }

    // MARK: - Tracks list

    private var tracksList: some View {
        VStack(alignment: .leading, spacing: SSDesign.Space.s) {
            HStack {
                Text("\(filtered.count) track\(filtered.count == 1 ? "" : "s")")
                    .font(SSDesign.Typography.caption(11))
                    .kerning(1.5)
                    .textCase(.uppercase)
                    .foregroundStyle(SSDesign.Palette.textMuted)
                Spacer()
                let analyzedCount = library.tracks.filter { analysisStore.has(trackId: $0.id) }.count
                if analyzedCount > 0 {
                    Text("\(analyzedCount) analyzed")
                        .font(SSDesign.Typography.caption(11))
                        .kerning(1.5)
                        .textCase(.uppercase)
                        .foregroundStyle(SSDesign.Palette.accent)
                }
            }
            .padding(.horizontal, SSDesign.Space.xs)

            VStack(spacing: SSDesign.Space.m) {
                ForEach(filtered) { track in
                    TrackCard(
                        track: track,
                        isAnalyzed: analysisStore.has(trackId: track.id),
                        isAnalyzing: analyzingTrackId == track.id,
                        anyAnalyzeInFlight: analyzeTask.isWorking,
                        onOpen: { open(track: track) },
                        onAnalyze: { Task { await analyze(track: track) } },
                        onReanalyze: { trackPendingReanalysis = track },
                        onRemove: {
                            analysisStore.remove(trackId: track.id)
                            library.remove(track)
                        }
                    )
                }
            }
        }
    }

    // MARK: - Empty states

    private var emptyState: some View {
        VStack(spacing: SSDesign.Space.l) {
            Spacer(minLength: 40)
            ZStack {
                Circle()
                    .fill(SSDesign.Palette.surfaceRaised)
                    .frame(width: 96, height: 96)
                Image(systemName: "waveform")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(SSDesign.Palette.accent)
            }
            .ssShadow(SSDesign.Shadow.card)

            VStack(spacing: SSDesign.Space.s) {
                Text("Your library is empty")
                    .font(SSDesign.Typography.title(20))
                    .foregroundStyle(SSDesign.Palette.textPrimary)
                Text("Upload a song to watch — and feel — its energy, structure, and emotion.")
                    .font(SSDesign.Typography.body())
                    .foregroundStyle(SSDesign.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, SSDesign.Space.l)

            Button {
                showUploadSheet = true
            } label: {
                Text("Upload a song")
            }
            .buttonStyle(PillButtonStyle(tint: .primary))
            .padding(.top, SSDesign.Space.s)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SSDesign.Space.xxxl)
    }

    private var noSearchResults: some View {
        VStack(spacing: SSDesign.Space.m) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(SSDesign.Palette.textMuted)
            Text("No matches")
                .font(SSDesign.Typography.headline())
                .foregroundStyle(SSDesign.Palette.textPrimary)
            Text("Try a different search.")
                .font(SSDesign.Typography.body(13))
                .foregroundStyle(SSDesign.Palette.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SSDesign.Space.xxxl)
    }

    // MARK: - Navigation destination

    @ViewBuilder
    private func analyzedPlayerDestination(for trackId: UUID) -> some View {
        if let track = library.tracks.first(where: { $0.id == trackId }),
           let analysis = try? analysisStore.load(trackId: trackId) {
            AnalyzedPlayerView(
                track: track,
                analysis: analysis,
                onRequestReanalyze: {
                    Task { await reanalyze(track: track) }
                }
            )
        } else {
            ZStack {
                AppBackground()
                ContentUnavailableView(
                    "Analysis unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The backend analysis for this track couldn't be loaded.")
                )
                .foregroundStyle(SSDesign.Palette.textPrimary)
            }
        }
    }

    // MARK: - Actions

    private func open(track: LibraryTrack) {
        if analysisStore.has(trackId: track.id) {
            // Navigation is handled by NavigationLink inside the card; this
            // exists for tap-on-card-body when there's no navigation link.
        } else {
            Task { await analyze(track: track) }
        }
    }

    @MainActor
    private func analyze(track: LibraryTrack) async {
        guard !analyzeTask.isWorking else { return }
        guard let audioURL = library.playbackURL(for: track) else { return }
        let mime = AudioFileStore.mimeType(for: audioURL)
        let uploadFilename = audioURL.lastPathComponent
        analyzingTrackId = track.id
        await analyzeTask.run(
            trackId: track.id,
            displayName: uploadFilename,
            audioURL: audioURL,
            mimeType: mime,
            store: analysisStore
        )
        analyzingTrackId = nil
    }

    @MainActor
    func reanalyze(track: LibraryTrack) async {
        guard !analyzeTask.isWorking else { return }
        analysisStore.remove(trackId: track.id)
        await analyze(track: track)
    }
}

// MARK: - Track card

private struct TrackCard: View {
    let track: LibraryTrack
    let isAnalyzed: Bool
    let isAnalyzing: Bool
    let anyAnalyzeInFlight: Bool
    let onOpen: () -> Void
    let onAnalyze: () -> Void
    let onReanalyze: () -> Void
    let onRemove: () -> Void

    var body: some View {
        // When analyzed, the whole card is a NavigationLink. When not, the
        // card is a plain button that kicks off analysis.
        Group {
            if isAnalyzed {
                NavigationLink(value: track.id) {
                    cardBody
                }
                .buttonStyle(.plain)
            } else {
                Button(action: onAnalyze) { cardBody }
                    .buttonStyle(.plain)
                    .disabled(isAnalyzing || anyAnalyzeInFlight)
            }
        }
        .contextMenu {
            if isAnalyzed {
                Button {
                    onReanalyze()
                } label: {
                    Label("Re-analyze", systemImage: "arrow.clockwise")
                }
                .disabled(anyAnalyzeInFlight)
            }
            if !track.isBundled {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove from library", systemImage: "trash")
                }
            }
        }
    }

    private var cardBody: some View {
        CardSurface {
            HStack(spacing: SSDesign.Space.l) {
                mark
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(SSDesign.Typography.headline())
                        .foregroundStyle(SSDesign.Palette.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if !track.artist.isEmpty {
                            Text(track.artist)
                                .font(SSDesign.Typography.body(13))
                                .foregroundStyle(SSDesign.Palette.textSecondary)
                                .lineLimit(1)
                        }
                        if let dur = track.formattedDuration {
                            metaSeparator
                            Text(dur)
                                .font(SSDesign.Typography.meta(12))
                                .foregroundStyle(SSDesign.Palette.textMuted)
                        }
                    }
                }
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, SSDesign.Space.l)
            .padding(.vertical, SSDesign.Space.m)
        }
    }

    private var metaSeparator: some View {
        Circle()
            .fill(SSDesign.Palette.textMuted)
            .frame(width: 3, height: 3)
    }

    /// Circular disc on the left. Glows with the accent color when the
    /// track is analyzed (ready to play), neutral gray when it isn't.
    private var mark: some View {
        ZStack {
            Circle()
                .fill(isAnalyzed ? SSDesign.Palette.accent.opacity(0.22) : SSDesign.Palette.surfaceActive)
                .overlay(
                    Circle()
                        .stroke(
                            isAnalyzed ? SSDesign.Palette.accent.opacity(0.7) : SSDesign.Palette.hairlineStrong,
                            lineWidth: isAnalyzed ? 1.2 : 0.6
                        )
                )
            Image(systemName: isAnalyzed ? "waveform" : "music.note")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isAnalyzed ? SSDesign.Palette.accent : SSDesign.Palette.textMuted)
        }
        .frame(width: 44, height: 44)
    }

    @ViewBuilder
    private var trailing: some View {
        if isAnalyzing {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(SSDesign.Palette.accent)
                Text("Analyzing")
                    .font(SSDesign.Typography.caption(10))
                    .kerning(1)
                    .textCase(.uppercase)
                    .foregroundStyle(SSDesign.Palette.textSecondary)
            }
        } else if isAnalyzed {
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(SSDesign.Palette.accent)
        } else {
            Text("Analyze")
                .font(SSDesign.Typography.caption(10))
                .kerning(1)
                .textCase(.uppercase)
                .padding(.horizontal, SSDesign.Space.m)
                .padding(.vertical, 6)
                .background(Capsule().fill(SSDesign.Palette.surfaceActive))
                .overlay(Capsule().stroke(SSDesign.Palette.hairlineStrong, lineWidth: 0.5))
                .foregroundStyle(SSDesign.Palette.textPrimary)
        }
    }
}

#Preview {
    LibraryView()
        .environmentObject(LibraryStore())
        .environmentObject(AnalysisStore())
        .preferredColorScheme(.dark)
}

//
//  LibraryView.swift
//  SoundSeen
//

import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var analysisStore: AnalysisStore
    @State private var query = ""
    @State private var analyzeTask = AnalyzeTask()
    @State private var analyzingTrackId: UUID? = nil
    /// Set when the user taps "Re-analyze" from a row's context menu. Drives
    /// the confirmation dialog; nil otherwise.
    @State private var trackPendingReanalysis: LibraryTrack? = nil

    /// Play track and switch to the listener (handled by parent).
    var onPlayTrack: (LibraryTrack) -> Void

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
                SoundSeenBackground()

                Group {
                    if library.tracks.isEmpty {
                        emptyState
                    } else if filtered.isEmpty {
                        noSearchResults
                    } else {
                        trackList
                    }
                }
            }
            .navigationTitle("Your Library")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(library.tracks.count) track\(library.tracks.count == 1 ? "" : "s")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(SoundSeenTheme.purpleAccent.opacity(0.42))
                        .clipShape(Capsule())
                }
            }
            .searchable(text: $query, prompt: "Search tracks or artists")
            .navigationDestination(for: UUID.self) { trackId in
                analyzedPlayerDestination(for: trackId)
            }
            .modifier(LibraryDialogs(
                analyzeTask: analyzeTask,
                trackPendingReanalysis: $trackPendingReanalysis,
                onReanalyzeConfirmed: { track in
                    Task { @MainActor in
                        await reanalyze(track: track)
                    }
                }
            ))
        }
    }

    @ViewBuilder
    private func analyzedPlayerDestination(for trackId: UUID) -> some View {
        if let track = library.tracks.first(where: { $0.id == trackId }) {
            if let analysis = try? analysisStore.load(trackId: trackId) {
                AnalyzedPlayerView(
                    track: track,
                    analysis: analysis,
                    onRequestReanalyze: {
                        Task { @MainActor in
                            await reanalyze(track: track)
                        }
                    }
                )
            } else {
                ContentUnavailableView(
                    "Analysis unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The backend analysis for this track couldn't be loaded.")
                )
            }
        } else {
            ContentUnavailableView(
                "Track not found",
                systemImage: "music.note",
                description: Text("This track is no longer in your library.")
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "music.note.list")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            SoundSeenTheme.tabAccent.opacity(0.9),
            
                            
                            Color(red: 0.95, green: 0.45, blue: 0.75),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 8) {
                Text("No tracks yet")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Tap the + button below to add MP3, M4A, or other audio files. They’ll appear here.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noSearchResults: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.white.opacity(0.45))
            Text("No matches")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("Try a different search.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var trackList: some View {
        List {
            Section {
                ForEach(filtered) { track in
                    HStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.45, green: 0.28, blue: 0.85).opacity(0.9),
                                        Color(red: 0.85, green: 0.35, blue: 0.55).opacity(0.85),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 52, height: 52)
                            .overlay {
                                Image(systemName: "waveform")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.95))
                            }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            if !track.artist.isEmpty {
                                Text(track.artist)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Text(track.isBundled ? "Included with SoundSeen" : track.addedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        Spacer(minLength: 0)

                        if analysisStore.has(trackId: track.id) {
                            NavigationLink(value: track.id) {
                                HStack(spacing: 4) {
                                    Image(systemName: "sparkles")
                                    Text("Open")
                                }
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(SoundSeenTheme.tabAccent)
                                )
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open analyzed player")
                        } else if analyzingTrackId == track.id {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .tint(.white)
                                Text("Analyzing")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(Color.white.opacity(0.15))
                            )
                        } else {
                            Button {
                                Task { @MainActor in
                                    await analyze(track: track)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "wand.and.stars")
                                    Text("Analyze")
                                }
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(SoundSeenTheme.purpleAccent)
                                )
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(analyzeTask.isWorking)
                            .opacity(analyzeTask.isWorking ? 0.5 : 1.0)
                            .accessibilityLabel("Analyze track")
                        }

                        Text(track.formattedDuration ?? "—")
                            .font(.subheadline.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)

                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(SoundSeenTheme.purpleAccent.opacity(0.9))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onPlayTrack(track)
                    }
                    .listRowBackground(Color.white.opacity(0.06))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if !track.isBundled {
                            Button(role: .destructive) {
                                analysisStore.remove(trackId: track.id)
                                library.remove(track)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                    .contextMenu {
                        if analysisStore.has(trackId: track.id) {
                            Button(role: .destructive) {
                                trackPendingReanalysis = track
                            } label: {
                                Label("Re-analyze", systemImage: "arrow.clockwise")
                            }
                            .disabled(analyzeTask.isWorking)
                        }
                    }
                }
            } header: {
                Text("\(library.tracks.count) track\(library.tracks.count == 1 ? "" : "s")")
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.insetGrouped)
    }

    // MARK: - Analyze on demand

    /// Discards the existing analysis for `track` and runs the upload +
    /// analyze flow again. Called by the context menu and by the player's
    /// top-bar Re-analyze action (after the player dismisses itself).
    @MainActor
    func reanalyze(track: LibraryTrack) async {
        guard !analyzeTask.isWorking else { return }
        analysisStore.remove(trackId: track.id)
        await analyze(track: track)
    }

    @MainActor
    private func analyze(track: LibraryTrack) async {
        guard !analyzeTask.isWorking else { return }
        guard let audioURL = library.playbackURL(for: track) else { return }
        let mime = AudioFileStore.mimeType(for: audioURL)
        // Backend sniffs by extension from the multipart filename; pass the
        // on-disk filename (e.g. "feel U luv Me.mp3") rather than track.title
        // which may be missing the extension.
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
}

/// Extracted to keep LibraryView.body's modifier chain short enough for the
/// SwiftUI type-checker. Both dialogs share state readers, so bundling them
/// in one modifier also keeps the presentation logic in one place.
private struct LibraryDialogs: ViewModifier {
    let analyzeTask: AnalyzeTask
    @Binding var trackPendingReanalysis: LibraryTrack?
    let onReanalyzeConfirmed: (LibraryTrack) -> Void

    private var isAnalyzeErrorPresented: Binding<Bool> {
        Binding(
            get: { analyzeTask.errorMessage != nil },
            set: { if !$0 { analyzeTask.reset() } }
        )
    }

    private var isReanalyzeConfirmPresented: Binding<Bool> {
        Binding(
            get: { trackPendingReanalysis != nil },
            set: { if !$0 { trackPendingReanalysis = nil } }
        )
    }

    func body(content: Content) -> some View {
        content
            .alert(
                "Analysis failed",
                isPresented: isAnalyzeErrorPresented,
                presenting: analyzeTask.errorMessage
            ) { _ in
                Button("OK", role: .cancel) { analyzeTask.reset() }
            } message: { msg in
                Text(msg)
            }
            .confirmationDialog(
                "Re-analyze this track?",
                isPresented: isReanalyzeConfirmPresented,
                titleVisibility: .visible,
                presenting: trackPendingReanalysis
            ) { track in
                Button("Re-analyze", role: .destructive) {
                    let target = track
                    trackPendingReanalysis = nil
                    onReanalyzeConfirmed(target)
                }
                Button("Cancel", role: .cancel) {
                    trackPendingReanalysis = nil
                }
            } message: { track in
                Text("This discards the existing analysis for \u{201C}\(track.title)\u{201D} and uploads the track again. Takes ~5\u{2013}15 seconds.")
            }
    }
}

#Preview {
    LibraryView { _ in }
        .environmentObject(LibraryStore())
        .environmentObject(AnalysisStore())
}

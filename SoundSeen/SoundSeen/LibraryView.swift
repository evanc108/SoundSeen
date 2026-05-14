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
    @EnvironmentObject private var jobStore: RenderJobStore
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
                        renderState: renderState(for: track),
                        anyAnalyzeInFlight: analyzeTask.isWorking,
                        onOpen: { open(track: track) },
                        onAnalyze: { Task { await analyze(track: track) } },
                        onReanalyze: { trackPendingReanalysis = track },
                        onRetryRender: { Task { await retryRender(track: track) } },
                        onRemove: {
                            jobStore.remove(trackId: track.id)
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
            let job = jobStore.job(for: trackId)
            if let job, job.status == .complete,
               let videoURL = resolvePlaybackURL(job: job) {
                RenderedPlayerView(
                    track: track,
                    analysis: analysis,
                    videoURL: videoURL,
                    onRequestReanalyze: {
                        Task { await reanalyze(track: track) }
                    }
                )
            } else {
                RenderProgressView(track: track, job: job)
            }
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

    /// Pick a playable URL for a completed job. Prefers the on-disk file
    /// when it exists, otherwise streams from Supabase.
    private func resolvePlaybackURL(job: RenderJob) -> URL? {
        if let local = job.localVideoURL, FileManager.default.fileExists(atPath: local.path) {
            return local
        }
        return job.videoURL
    }

    // MARK: - State derivation

    private func renderState(for track: LibraryTrack) -> TrackRenderState {
        if analyzingTrackId == track.id { return .analyzing }
        guard analysisStore.has(trackId: track.id) else { return .uploaded }
        guard let job = jobStore.job(for: track.id) else { return .renderPending }
        switch job.status {
        case .queued, .rendering:
            return .rendering
        case .complete:
            return job.localVideoURL == nil ? .downloading : .ready
        case .failed:
            return .renderFailed
        case .unavailable:
            return .renderUnavailable
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
        // Pick up the auto-rendered job the backend just kicked off.
        if let analysis = try? analysisStore.load(trackId: track.id) {
            jobStore.registerSong(songId: analysis.songId, trackId: track.id)
            Task {
                await RenderJobResumer.shared.resume(
                    library: library,
                    analysisStore: analysisStore,
                    jobStore: jobStore
                )
            }
        }
    }

    @MainActor
    func reanalyze(track: LibraryTrack) async {
        guard !analyzeTask.isWorking else { return }
        jobStore.remove(trackId: track.id)
        analysisStore.remove(trackId: track.id)
        await analyze(track: track)
    }

    @MainActor
    private func retryRender(track: LibraryTrack) async {
        guard let analysis = try? analysisStore.load(trackId: track.id) else { return }
        guard let status = try? await APIClient.shared.startRender(songId: analysis.songId) else { return }
        let mapped = RenderJob.Status(rawValue: status.status) ?? .failed
        let job = RenderJob(
            jobId: status.jobId,
            trackId: track.id,
            songId: analysis.songId,
            status: mapped,
            videoURL: status.videoUrl,
            localVideoURL: nil,
            error: status.error,
            updatedAt: Date()
        )
        try? jobStore.upsert(job)
        RenderJobResumer.shared.startPolling(jobStore: jobStore)
    }
}

// MARK: - Track render state

enum TrackRenderState: Equatable {
    case uploaded
    case analyzing
    /// Analysis exists but we haven't heard back from the server about
    /// a job yet (transient — resumer will populate on next tick).
    case renderPending
    case rendering
    case downloading
    case ready
    case renderFailed
    case renderUnavailable
}

// MARK: - Track card

private struct TrackCard: View {
    let track: LibraryTrack
    let renderState: TrackRenderState
    let anyAnalyzeInFlight: Bool
    let onOpen: () -> Void
    let onAnalyze: () -> Void
    let onReanalyze: () -> Void
    let onRetryRender: () -> Void
    let onRemove: () -> Void

    private var isAnalyzed: Bool {
        switch renderState {
        case .uploaded, .analyzing: return false
        default: return true
        }
    }

    private var navigable: Bool {
        // Tappable states: ready (full playback) and renderUnavailable
        // (audio-only fallback in the destination view). Other analyzed
        // states navigate into the progress view too — Phase D's
        // RenderedPlayerView handles audio-only fallback when no video.
        switch renderState {
        case .ready, .renderUnavailable, .rendering, .downloading, .renderFailed, .renderPending:
            return true
        case .uploaded, .analyzing:
            return false
        }
    }

    var body: some View {
        Group {
            if navigable {
                NavigationLink(value: track.id) { cardBody }
                    .buttonStyle(.plain)
            } else {
                Button(action: onAnalyze) { cardBody }
                    .buttonStyle(.plain)
                    .disabled(renderState == .analyzing || anyAnalyzeInFlight)
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
            if renderState == .renderFailed || renderState == .renderUnavailable {
                Button {
                    onRetryRender()
                } label: {
                    Label("Retry render", systemImage: "arrow.clockwise")
                }
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

    /// Circular disc on the left. Accents when the render is ready to play.
    private var mark: some View {
        let glow = renderState == .ready
        return ZStack {
            Circle()
                .fill(glow ? SSDesign.Palette.accent.opacity(0.22) : SSDesign.Palette.surfaceActive)
                .overlay(
                    Circle()
                        .stroke(
                            glow ? SSDesign.Palette.accent.opacity(0.7) : SSDesign.Palette.hairlineStrong,
                            lineWidth: glow ? 1.2 : 0.6
                        )
                )
            Image(systemName: glow ? "waveform" : "music.note")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(glow ? SSDesign.Palette.accent : SSDesign.Palette.textMuted)
        }
        .frame(width: 44, height: 44)
    }

    @ViewBuilder
    private var trailing: some View {
        switch renderState {
        case .analyzing:
            inlineProgress(label: "Analyzing")
        case .renderPending, .rendering:
            inlineProgress(label: "Rendering")
        case .downloading:
            inlineProgress(label: "Downloading")
        case .ready:
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(SSDesign.Palette.accent)
        case .renderFailed:
            statusPill(text: "Retry", tint: .red)
        case .renderUnavailable:
            statusPill(text: "Offline", tint: SSDesign.Palette.textMuted)
        case .uploaded:
            statusPill(text: "Analyze", tint: SSDesign.Palette.textPrimary)
        }
    }

    private func inlineProgress(label: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .scaleEffect(0.7)
                .tint(SSDesign.Palette.accent)
            Text(label)
                .font(SSDesign.Typography.caption(10))
                .kerning(1)
                .textCase(.uppercase)
                .foregroundStyle(SSDesign.Palette.textSecondary)
        }
    }

    private func statusPill(text: String, tint: Color) -> some View {
        Text(text)
            .font(SSDesign.Typography.caption(10))
            .kerning(1)
            .textCase(.uppercase)
            .padding(.horizontal, SSDesign.Space.m)
            .padding(.vertical, 6)
            .background(Capsule().fill(SSDesign.Palette.surfaceActive))
            .overlay(Capsule().stroke(SSDesign.Palette.hairlineStrong, lineWidth: 0.5))
            .foregroundStyle(tint)
    }
}

#Preview {
    LibraryView()
        .environmentObject(LibraryStore())
        .environmentObject(AnalysisStore())
        .environmentObject(RenderJobStore())
        .preferredColorScheme(.dark)
}

//
//  UploadView.swift
//  SoundSeen
//

import SwiftUI
import UniformTypeIdentifiers

struct UploadView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var analysisStore: AnalysisStore
    @Environment(\.dismiss) private var dismiss
    @State private var isImporterPresented = false
    @State private var importError: String?
    @State private var isImporting = false
    @State private var analyzeTask = AnalyzeTask()

    var body: some View {
        NavigationStack {
            ZStack {
                SoundSeenBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        headerCard

                        Button {
                            isImporterPresented = true
                        } label: {
                            Label("Choose audio file", systemImage: "folder.badge.plus")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(SoundSeenTheme.tabAccent)
                        .disabled(isImporting || analyzeTask.isWorking)

                        statusBanner

                        tipsSection
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Upload")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task { @MainActor in
                        await handleImport(url: url)
                    }
                case .failure(let error):
                    importError = error.localizedDescription
                }
            }
            .alert("Could not import", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    // MARK: - Import + analyze

    @MainActor
    private func handleImport(url: URL) async {
        isImporting = true
        defer { isImporting = false }

        let track: LibraryTrack
        do {
            track = try library.importAudioFile(from: url)
            importError = nil
        } catch {
            importError = error.localizedDescription
            return
        }

        guard let audioURL = track.importedFileURL else { return }
        let mimeType = AudioFileStore.mimeType(for: audioURL)
        await analyzeTask.run(
            trackId: track.id,
            displayName: track.title,
            audioURL: audioURL,
            mimeType: mimeType,
            store: analysisStore
        )
    }

    // MARK: - Status banner

    @ViewBuilder
    private var statusBanner: some View {
        if isImporting {
            bannerRow(spinner: true, text: "Importing…")
        } else {
            switch analyzeTask.state {
            case .uploading(let filename):
                bannerRow(spinner: true, text: "Uploading \(filename)…")
            case .analyzing(let filename):
                bannerRow(spinner: true, text: "Analyzing \(filename)…")
            case .done:
                bannerRow(
                    symbol: "sparkles",
                    tint: SoundSeenTheme.tabAccent,
                    text: "Analysis ready — open it from your Library."
                )
            case .failed(let message):
                bannerRow(
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange,
                    text: "Analysis unavailable: \(message)"
                )
            case .idle:
                EmptyView()
            }
        }
    }

    private func bannerRow(spinner: Bool = false,
                           symbol: String? = nil,
                           tint: Color = .white,
                           text: String) -> some View {
        HStack(spacing: 10) {
            if spinner {
                ProgressView()
            } else if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
            }
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.06))
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add to your library")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
            Text("Pick a song from Files or iCloud. We copy it into SoundSeen so it stays available offline, then send it to the analyzer for richer visuals and haptics.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.08))
        }
    }

    private var tipsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Supported formats", systemImage: "info.circle.fill")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.9))

            VStack(alignment: .leading, spacing: 8) {
                tipRow("MP3, M4A, WAV, AIFF, and other common audio")
                tipRow("Files are stored on this device only")
                tipRow("Analysis runs on your SoundSeen backend — offline import still works")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.05))
        }
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .foregroundStyle(SoundSeenTheme.tabAccent.opacity(0.95))
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}

#Preview {
    UploadView()
        .environmentObject(LibraryStore())
        .environmentObject(AnalysisStore())
}

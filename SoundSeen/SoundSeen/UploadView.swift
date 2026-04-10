//
//  UploadView.swift
//  SoundSeen
//

import SwiftUI
import UniformTypeIdentifiers

struct UploadView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var isImporterPresented = false
    @State private var importError: String?
    @State private var isImporting = false

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
                        .disabled(isImporting)

                        if isImporting {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Importing…")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            .frame(maxWidth: .infinity)
                        }

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
                    isImporting = true
                    Task { @MainActor in
                        defer { isImporting = false }
                        do {
                            try library.importAudioFile(from: url)
                            importError = nil
                        } catch {
                            importError = error.localizedDescription
                        }
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

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add to your library")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
            Text("Pick a song from Files or iCloud. We copy it into SoundSeen so it stays available offline in your library.")
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
                tipRow("Open Your Library to see imports")
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
}

//
//  UploadView.swift
//  SoundSeen
//
//  Sheet presented from LibraryView's + button. A single big tap target
//  replaces the former headline/button/tips stack — the interaction is
//  fundamentally "pick a file," so the UI treats that as the hero and
//  folds everything else (format hints, progress) into subdued context.
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
        ZStack {
            AppBackground()

            VStack(alignment: .leading, spacing: SSDesign.Space.xxl) {
                topBar
                header
                uploadZone
                statusBanner
                Spacer(minLength: 0)
                supportedFormats
            }
            .padding(SSDesign.Space.xl)
        }
        .preferredColorScheme(.dark)
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { @MainActor in await handleImport(url: url) }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert(
            "Could not import",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: - Sections

    private var topBar: some View {
        HStack {
            Text("Upload")
                .font(SSDesign.Typography.caption(11))
                .kerning(2)
                .textCase(.uppercase)
                .foregroundStyle(SSDesign.Palette.textMuted)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(SSDesign.Palette.surfaceRaised))
                    .overlay(Circle().stroke(SSDesign.Palette.hairline, lineWidth: 0.5))
                    .foregroundStyle(SSDesign.Palette.textPrimary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SSDesign.Space.s) {
            Text("Add a song")
                .font(SSDesign.Typography.display(32))
                .foregroundStyle(SSDesign.Palette.textPrimary)
            Text("Pick an audio file. We'll analyze its energy, structure, and emotion, then translate all three into visuals and haptics.")
                .font(SSDesign.Typography.body(15))
                .foregroundStyle(SSDesign.Palette.textSecondary)
        }
    }

    /// Dashed outline drop zone. Tapping opens the file importer. The big
    /// surface makes the action unmistakable; the dashed stroke reads as
    /// "this is where a file drops" even though iOS doesn't support
    /// dragging here.
    private var uploadZone: some View {
        Button {
            isImporterPresented = true
        } label: {
            VStack(spacing: SSDesign.Space.l) {
                ZStack {
                    Circle()
                        .fill(SSDesign.Palette.accent.opacity(0.18))
                        .frame(width: 74, height: 74)
                    Image(systemName: "arrow.up.doc.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(SSDesign.Palette.accent)
                }
                VStack(spacing: 6) {
                    Text("Tap to pick a file")
                        .font(SSDesign.Typography.headline(18))
                        .foregroundStyle(SSDesign.Palette.textPrimary)
                    Text("From Files, iCloud, or any document provider")
                        .font(SSDesign.Typography.body(13))
                        .foregroundStyle(SSDesign.Palette.textMuted)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, SSDesign.Space.xxl + 8)
            .background(
                RoundedRectangle(cornerRadius: SSDesign.Radius.xl, style: .continuous)
                    .fill(SSDesign.Palette.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SSDesign.Radius.xl, style: .continuous)
                    .stroke(
                        SSDesign.Palette.accent.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1.2, dash: [6, 4])
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isImporting || analyzeTask.isWorking)
        .opacity((isImporting || analyzeTask.isWorking) ? 0.6 : 1)
    }

    // MARK: - Status banner

    @ViewBuilder
    private var statusBanner: some View {
        if isImporting {
            banner(kind: .progress(label: "Importing"))
        } else {
            switch analyzeTask.state {
            case .uploading(let filename):
                banner(kind: .progress(label: "Uploading \(shortName(filename))"))
            case .analyzing(let filename):
                banner(kind: .progress(label: "Reading the song's feelings — \(shortName(filename))"))
            case .done:
                banner(kind: .success(label: "Analysis ready. Open it from your library."))
            case .failed(let message):
                banner(kind: .failure(label: message))
            case .idle:
                EmptyView()
            }
        }
    }

    private enum BannerKind {
        case progress(label: String)
        case success(label: String)
        case failure(label: String)
    }

    private func banner(kind: BannerKind) -> some View {
        HStack(spacing: SSDesign.Space.m) {
            switch kind {
            case .progress(let label):
                ProgressView().tint(SSDesign.Palette.accent)
                Text(label)
                    .font(SSDesign.Typography.body(14))
                    .foregroundStyle(SSDesign.Palette.textSecondary)
            case .success(let label):
                Image(systemName: "sparkles")
                    .foregroundStyle(SSDesign.Palette.accent)
                Text(label)
                    .font(SSDesign.Typography.body(14))
                    .foregroundStyle(SSDesign.Palette.textPrimary)
            case .failure(let label):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(SSDesign.Palette.danger)
                Text(label)
                    .font(SSDesign.Typography.body(13))
                    .foregroundStyle(SSDesign.Palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SSDesign.Space.l)
        .padding(.vertical, SSDesign.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SSDesign.Radius.m, style: .continuous)
                .fill(SSDesign.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SSDesign.Radius.m, style: .continuous)
                .stroke(SSDesign.Palette.hairline, lineWidth: 0.5)
        )
    }

    private var supportedFormats: some View {
        HStack(spacing: SSDesign.Space.s) {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SSDesign.Palette.textMuted)
            Text("MP3, M4A, WAV, AIFF — stored on this device only.")
                .font(SSDesign.Typography.body(12))
                .foregroundStyle(SSDesign.Palette.textMuted)
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

    /// File names from some pickers can be absurdly long. Trim so the
    /// banner doesn't blow out the layout.
    private func shortName(_ name: String) -> String {
        if name.count <= 32 { return name }
        return String(name.prefix(30)) + "\u{2026}"
    }
}

#Preview {
    UploadView()
        .environmentObject(LibraryStore())
        .environmentObject(AnalysisStore())
}

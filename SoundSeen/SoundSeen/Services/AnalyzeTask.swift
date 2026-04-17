//
//  AnalyzeTask.swift
//  SoundSeen
//
//  @Observable state machine driving the backend analysis import flow. Upload
//  an already-imported audio file to /analyze, persist the resulting SongAnalysis
//  to AnalysisStore keyed by LibraryTrack.id. LibraryStore handles file copying;
//  this task only owns the upload + decode + sidecar-write leg.
//

import Foundation
import Observation

@Observable
@MainActor
final class AnalyzeTask {
    enum State: Equatable {
        case idle
        case uploading(filename: String)
        case analyzing(filename: String)
        case failed(message: String)
        case done(trackId: UUID)
    }

    private(set) var state: State = .idle

    var isWorking: Bool {
        switch state {
        case .uploading, .analyzing: return true
        default: return false
        }
    }

    var errorMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    func reset() {
        state = .idle
    }

    func markFailed(_ message: String) {
        state = .failed(message: message)
    }

    /// Uploads `audioURL` to the backend and stores the resulting analysis in
    /// `store` keyed by `trackId`. Caller must ensure `audioURL` is readable
    /// (LibraryStore already copies security-scoped imports into Documents).
    func run(
        trackId: UUID,
        displayName: String,
        audioURL: URL,
        mimeType: String,
        store: AnalysisStore,
        api: APIClient = .shared
    ) async {
        guard !isWorking else { return }

        state = .uploading(filename: displayName)
        // Brief next-runloop yield so the UI can paint the uploading banner
        // before URLSession starts blocking our main actor on data read.
        await Task.yield()
        state = .analyzing(filename: displayName)

        let analysis: SongAnalysis
        do {
            analysis = try await api.analyze(
                fileURL: audioURL,
                filename: displayName,
                mimeType: mimeType
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            state = .failed(message: message)
            return
        }

        do {
            try store.save(analysis, for: trackId)
        } catch {
            state = .failed(message: "Could not save analysis: \(error.localizedDescription)")
            return
        }

        state = .done(trackId: trackId)
    }
}

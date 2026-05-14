//
//  RenderJobResumer.swift
//  SoundSeen
//
//  Reconciles the server's render_jobs table with the local RenderJobStore
//  whenever the app comes to foreground. Also drives a foreground 3-second
//  polling loop while any non-terminal jobs remain, so the library row
//  state animates Rendering → Downloading → Ready without the user pulling
//  to refresh.
//

import Foundation

@MainActor
final class RenderJobResumer {
    static let shared = RenderJobResumer()

    private var pollingTask: Task<Void, Never>? = nil

    /// One-shot reconciliation. Builds the song_id → trackId index from
    /// AnalysisStore, batch-polls /jobs, upserts each row, and kicks off
    /// downloads for anything already complete.
    func resume(
        library: LibraryStore,
        analysisStore: AnalysisStore,
        jobStore: RenderJobStore,
        api: APIClient = .shared
    ) async {
        // 1. Map songId → trackId for every analyzed track. Side-effect:
        //    populate jobStore's reverse index so trackId(forSongId:) works
        //    even for tracks that have no job row yet.
        var songIdsToFetch: [String] = []
        var analyzedTracks: [(UUID, String)] = []
        for track in library.tracks {
            guard let analysis = try? analysisStore.load(trackId: track.id) else { continue }
            analyzedTracks.append((track.id, analysis.songId))
            jobStore.registerSong(songId: analysis.songId, trackId: track.id)
            songIdsToFetch.append(analysis.songId)
        }

        // 2. Batch poll.
        if !songIdsToFetch.isEmpty {
            let statuses = (try? await api.renderJobs(songIds: songIdsToFetch)) ?? []
            for status in statuses {
                guard let trackId = jobStore.trackId(forSongId: status.songId) else { continue }
                let job = makeJob(from: status, trackId: trackId,
                                  previous: jobStore.job(for: trackId))
                try? jobStore.upsert(job)
                if job.status == .complete {
                    RenderDownloadCoordinator.shared.ensureDownloaded(job: job, store: jobStore)
                }
            }
        }

        // 3. For analyzed tracks lacking a job row, request one. Covers
        //    "song analyzed before /jobs landed" and spec-version drift.
        for (trackId, songId) in analyzedTracks where jobStore.job(for: trackId) == nil {
            Task {
                guard let status = try? await api.startRender(songId: songId) else { return }
                let job = makeJob(from: status, trackId: trackId, previous: nil)
                try? jobStore.upsert(job)
                if job.status == .complete {
                    RenderDownloadCoordinator.shared.ensureDownloaded(job: job, store: jobStore)
                }
            }
        }

        // 4. Start polling unterminated rows.
        startPolling(jobStore: jobStore, api: api)
    }

    /// 3-second poll loop for non-terminal rows. Cancels itself when
    /// nothing is left to watch.
    func startPolling(jobStore: RenderJobStore, api: APIClient = .shared) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let pending = jobStore.allUnterminated()
                if pending.isEmpty { break }
                for job in pending {
                    guard let status = try? await api.renderStatus(jobId: job.jobId) else { continue }
                    let updated = self?.makeJob(from: status, trackId: job.trackId, previous: job)
                                  ?? job
                    try? jobStore.upsert(updated)
                    if updated.status == .complete {
                        RenderDownloadCoordinator.shared.ensureDownloaded(job: updated, store: jobStore)
                    }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Reach into a server status response and build a RenderJob, preserving
    /// the local `localVideoURL` if it was already downloaded.
    private func makeJob(
        from status: RenderJobStatus,
        trackId: UUID,
        previous: RenderJob?
    ) -> RenderJob {
        let mapped = RenderJob.Status(rawValue: status.status) ?? .failed
        var localURL = previous?.localVideoURL
        // Sanity: if the file was deleted out from under us, drop the cache
        // so the download coordinator picks it back up.
        if let url = localURL, !FileManager.default.fileExists(atPath: url.path) {
            localURL = nil
        }
        return RenderJob(
            jobId: status.jobId,
            trackId: trackId,
            songId: status.songId,
            status: mapped,
            videoURL: status.videoUrl,
            localVideoURL: localURL,
            error: status.error,
            updatedAt: Date()
        )
    }
}

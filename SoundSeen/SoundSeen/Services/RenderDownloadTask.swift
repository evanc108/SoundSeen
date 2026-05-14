//
//  RenderDownloadTask.swift
//  SoundSeen
//
//  Downloads completed render MP4s into Documents/renders/<trackId>.mp4 so
//  playback doesn't have to stream over the network. One inflight download
//  per trackId; failures retry once after 5s, then surrender (the player
//  falls back to streaming the remote URL).
//

import Foundation

@MainActor
final class RenderDownloadCoordinator {
    static let shared = RenderDownloadCoordinator()

    private var inflight: Set<UUID> = []
    private let directory: URL

    init() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = docs.appendingPathComponent("renders", isDirectory: true)
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Kick off a download for `job` if one isn't already running. Updates
    /// the store with `localVideoURL` on success.
    func ensureDownloaded(job: RenderJob, store: RenderJobStore) {
        guard job.status == .complete,
              let remote = job.videoURL,
              job.localVideoURL == nil,
              !inflight.contains(job.trackId) else { return }
        inflight.insert(job.trackId)
        Task { [weak self] in
            await self?.run(job: job, remote: remote, store: store)
        }
    }

    func localFileURL(for trackId: UUID) -> URL {
        directory.appendingPathComponent("\(trackId.uuidString).mp4")
    }

    private func run(job: RenderJob, remote: URL, store: RenderJobStore) async {
        defer { inflight.remove(job.trackId) }
        for attempt in 0..<2 {
            if await download(remote: remote, to: localFileURL(for: job.trackId)) {
                var updated = job
                updated.localVideoURL = localFileURL(for: job.trackId)
                updated.updatedAt = Date()
                try? store.upsert(updated)
                return
            }
            if attempt == 0 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func download(remote: URL, to destination: URL) async -> Bool {
        do {
            let (tmp, response) = try await URLSession.shared.download(from: remote)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: tmp)
                return false
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tmp, to: destination)
            return true
        } catch {
            return false
        }
    }
}

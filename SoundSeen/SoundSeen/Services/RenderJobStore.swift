//
//  RenderJobStore.swift
//  SoundSeen
//
//  Codable JSON sidecar store for render jobs, keyed by LibraryTrack.id.
//  Mirrors AnalysisStore: one file per track at Documents/render_jobs/<id>.json,
//  one in-memory dict that LibraryView observes for row state.
//

import Combine
import Foundation

struct RenderJob: Codable, Hashable, Sendable, Identifiable {
    enum Status: String, Codable, Sendable {
        case queued, rendering, complete, failed, unavailable
    }

    /// Server-issued — Modal call object_id or a "cached-…"/"unavailable-…"/"spawn-fail-…" sentinel.
    let jobId: String
    let trackId: UUID
    /// Backend song uuid; matches SongAnalysis.songId.
    let songId: String
    var status: Status
    /// Remote (Supabase public URL) — present once the renderer uploads.
    var videoURL: URL?
    /// Documents/renders/<trackId>.mp4 once the client finishes downloading.
    var localVideoURL: URL?
    var error: String?
    var updatedAt: Date

    var id: String { jobId }

    var isTerminal: Bool {
        switch status {
        case .complete, .failed, .unavailable: return true
        case .queued, .rendering: return false
        }
    }
}

@MainActor
final class RenderJobStore: ObservableObject {
    @Published private(set) var jobsByTrackId: [UUID: RenderJob] = [:]
    /// Reverse index so /jobs responses (keyed by songId) can be reconciled
    /// back to library track ids without scanning every row.
    private var songIdToTrackId: [String: UUID] = [:]

    private let directory: URL

    init() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = docs.appendingPathComponent("render_jobs", isDirectory: true)
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        load()
    }

    func job(for trackId: UUID) -> RenderJob? {
        jobsByTrackId[trackId]
    }

    func trackId(forSongId songId: String) -> UUID? {
        songIdToTrackId[songId]
    }

    /// Register a (trackId, songId) pairing so resume can map server rows
    /// back to library rows. Called whenever a SongAnalysis lands.
    func registerSong(songId: String, trackId: UUID) {
        songIdToTrackId[songId] = trackId
    }

    func upsert(_ job: RenderJob) throws {
        let url = fileURL(for: job.trackId)
        let data = try JSONEncoder.soundSeen.encode(job)
        try data.write(to: url, options: .atomic)
        jobsByTrackId[job.trackId] = job
        songIdToTrackId[job.songId] = job.trackId
    }

    func remove(trackId: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: trackId))
        if let songId = jobsByTrackId[trackId]?.songId {
            songIdToTrackId.removeValue(forKey: songId)
        }
        jobsByTrackId.removeValue(forKey: trackId)
    }

    func allUnterminated() -> [RenderJob] {
        jobsByTrackId.values.filter { !$0.isTerminal }
    }

    func allComplete() -> [RenderJob] {
        jobsByTrackId.values.filter { $0.status == .complete }
    }

    // MARK: - Internals

    private func load() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory,
                                                       includingPropertiesForKeys: nil) else {
            return
        }
        var byTrack: [UUID: RenderJob] = [:]
        var bySong: [String: UUID] = [:]
        for url in entries where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url),
                  let job = try? JSONDecoder.soundSeen.decode(RenderJob.self, from: data) else {
                continue
            }
            byTrack[job.trackId] = job
            bySong[job.songId] = job.trackId
        }
        jobsByTrackId = byTrack
        songIdToTrackId = bySong
    }

    private func fileURL(for trackId: UUID) -> URL {
        directory.appendingPathComponent("\(trackId.uuidString).json")
    }
}

//
//  AnalysisStore.swift
//  SoundSeen
//
//  Sidecar JSON store for backend-computed SongAnalysis, keyed by LibraryTrack.id.
//  Blobs live at Documents/analyses/<track-id>.json. analyzedIds is published so
//  LibraryView can badge rows reactively without reading disk on every render.
//

import Combine
import Foundation

final class AnalysisStore: ObservableObject {
    @Published private(set) var analyzedIds: Set<UUID> = []

    private let directory: URL

    init() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = docs.appendingPathComponent("analyses", isDirectory: true)
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        analyzedIds = Self.scan(directory: directory)
    }

    func has(trackId: UUID) -> Bool {
        analyzedIds.contains(trackId)
    }

    func load(trackId: UUID) throws -> SongAnalysis {
        let url = fileURL(for: trackId)
        let data = try Data(contentsOf: url)
        return try JSONDecoder.soundSeen.decode(SongAnalysis.self, from: data)
    }

    func save(_ analysis: SongAnalysis, for trackId: UUID) throws {
        let data = try JSONEncoder.soundSeen.encode(analysis)
        try data.write(to: fileURL(for: trackId), options: .atomic)
        analyzedIds.insert(trackId)
    }

    func remove(trackId: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: trackId))
        analyzedIds.remove(trackId)
    }

    private func fileURL(for trackId: UUID) -> URL {
        directory.appendingPathComponent("\(trackId.uuidString).json")
    }

    private static func scan(directory: URL) -> Set<UUID> {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory,
                                                       includingPropertiesForKeys: nil) else {
            return []
        }
        var ids: Set<UUID> = []
        for url in entries where url.pathExtension.lowercased() == "json" {
            let base = url.deletingPathExtension().lastPathComponent
            if let id = UUID(uuidString: base) {
                ids.insert(id)
            }
        }
        return ids
    }
}

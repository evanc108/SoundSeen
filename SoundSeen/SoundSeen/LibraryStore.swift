//
//  LibraryStore.swift
//  SoundSeen
//

import AVFoundation
import Combine
import Foundation

struct LibraryTrack: Identifiable, Equatable {
    let id: UUID
    var title: String
    var artist: String
    var addedAt: Date
    var isBundled: Bool
    /// `Bundle.main.url(forResource:withExtension: "mp3")` base name, no extension.
    var bundledResourceBaseName: String?
    var importedFileURL: URL?
    /// Length in seconds; filled when file is available.
    var durationSeconds: TimeInterval?

    /// Imported tracks only — bundled files are resolved by `LibraryStore.playbackURL(for:)`.
    var importedPlaybackURL: URL? {
        importedFileURL
    }

    var formattedDuration: String? {
        guard let d = durationSeconds, d > 0, d.isFinite else { return nil }
        let s = Int(d.rounded(.down))
        let m = s / 60
        let r = s % 60
        return String(format: "%d:%02d", m, r)
    }
}

final class LibraryStore: ObservableObject {
    @Published private(set) var tracks: [LibraryTrack] = []

    /// Each bundled track id → file URL, matched by **exact** mp3 filename (no ambiguous `Bundle.url` lookups).
    private let bundledURLByTrackId: [UUID: URL]

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    init() {
        let seeded = Self.seedBundledTracks()
        let urlMap = Self.makeBundledURLMap(bundledTracks: seeded)
        self.bundledURLByTrackId = urlMap
        var withDuration = seeded
        for i in withDuration.indices {
            if let url = urlMap[withDuration[i].id] {
                withDuration[i].durationSeconds = Self.durationForURL(url)
            }
        }
        tracks = withDuration
    }

    /// Resolves the on-disk URL for a library row. Bundled tracks use the id → URL map built from actual bundle filenames.
    func playbackURL(for track: LibraryTrack) -> URL? {
        if let imported = track.importedFileURL {
            return imported
        }
        return bundledURLByTrackId[track.id]
    }

    private static func makeBundledURLMap(bundledTracks: [LibraryTrack]) -> [UUID: URL] {
        let mp3s = Bundle.main.urls(forResourcesWithExtension: "mp3", subdirectory: nil) ?? []
        var map: [UUID: URL] = [:]
        for t in bundledTracks {
            guard let base = t.bundledResourceBaseName?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty else { continue }
            if let hit = mp3s.first(where: { $0.deletingPathExtension().lastPathComponent == base }) {
                map[t.id] = hit
                continue
            }
            if let hit = mp3s.first(where: {
                $0.deletingPathExtension().lastPathComponent.compare(base, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) {
                map[t.id] = hit
            }
        }
        return map
    }

    private static func seedBundledTracks() -> [LibraryTrack] {
        let seeds: [(String, String, String)] = [
            ("Knock2 - feel U luv Me", "feel U luv Me", "Knock2"),
            ("BLIND RAVE MIX", "BLIND (RAVE MIX)", ""),
            ("ILLENIUM WYLDE - Ur Alive", "Ur Alive", "ILLENIUM, WYLDE"),
            ("ILLENIUM Jon Bellion - Good Things Fall Apart", "Good Things Fall Apart", "ILLENIUM, Jon Bellion"),
            ("ILLENIUM Chandler Leighton - Lonely", "Lonely", "ILLENIUM, Chandler Leighton"),
            ("Knock2 - crank the bass play the muzik", "crank the bass, play the muzik", "Knock2"),
        ]
        return seeds.enumerated().map { index, item in
            let (base, title, artist) = item
            return LibraryTrack(
                id: Self.bundledIDs[index],
                title: title,
                artist: artist,
                addedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                isBundled: true,
                bundledResourceBaseName: base,
                importedFileURL: nil,
                durationSeconds: nil
            )
        }
    }

    private static let bundledIDs: [UUID] = [
        UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
        UUID(uuidString: "10000000-0000-4000-8000-000000000002")!,
        UUID(uuidString: "10000000-0000-4000-8000-000000000003")!,
        UUID(uuidString: "10000000-0000-4000-8000-000000000004")!,
        UUID(uuidString: "10000000-0000-4000-8000-000000000005")!,
        UUID(uuidString: "10000000-0000-4000-8000-000000000006")!,
    ]

    private static func durationForURL(_ url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let len = file.length
        guard len > 0 else { return nil }
        return Double(len) / file.processingFormat.sampleRate
    }

    /// Copies the user-selected file into Documents and appends to the library.
    /// Returns the newly inserted track so callers can chain follow-up work
    /// (e.g. kick off an AnalyzeTask) without looking it up by index.
    @discardableResult
    func importAudioFile(from sourceURL: URL) throws -> LibraryTrack {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let originalName = sourceURL.lastPathComponent
        let base = (originalName as NSString).deletingPathExtension
        let ext = (originalName as NSString).pathExtension
        let uniqueName = "\(UUID().uuidString)_\(base).\(ext.isEmpty ? "mp3" : ext)"
        let destination = documentsDirectory.appendingPathComponent(uniqueName)

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)

        let (title, artist) = Self.parseArtistTitle(fromFilenameBase: base)
        var track = LibraryTrack(
            id: UUID(),
            title: title,
            artist: artist,
            addedAt: Date(),
            isBundled: false,
            bundledResourceBaseName: nil,
            importedFileURL: destination,
            durationSeconds: nil
        )
        track.durationSeconds = Self.durationForURL(destination)
        tracks.insert(track, at: 0)
        return track
    }

    static func parseArtistTitle(fromFilenameBase base: String) -> (String, String) {
        if let range = base.range(of: " - ") {
            let artist = String(base[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            var rest = String(base[range.upperBound...])
            if let paren = rest.range(of: " (") {
                rest = String(rest[..<paren.lowerBound])
            }
            return (rest.trimmingCharacters(in: .whitespaces), artist)
        }
        return (base, "")
    }

    func remove(_ track: LibraryTrack) {
        guard !track.isBundled else { return }
        if let url = track.importedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        tracks.removeAll { $0.id == track.id }
    }
}

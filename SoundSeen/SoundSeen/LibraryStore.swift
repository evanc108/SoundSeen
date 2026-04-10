//
//  LibraryStore.swift
//  SoundSeen
//

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

    var playbackURL: URL? {
        if let base = bundledResourceBaseName {
            return Bundle.main.url(forResource: base, withExtension: "mp3")
        }
        return importedFileURL
    }
}

final class LibraryStore: ObservableObject {
    @Published private(set) var tracks: [LibraryTrack] = []

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    init() {
        tracks = Self.seedBundledTracks()
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
                importedFileURL: nil
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

    /// Copies the user-selected file into Documents and appends to the library.
    func importAudioFile(from sourceURL: URL) throws {
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
        let track = LibraryTrack(
            id: UUID(),
            title: title,
            artist: artist,
            addedAt: Date(),
            isBundled: false,
            bundledResourceBaseName: nil,
            importedFileURL: destination
        )
        tracks.insert(track, at: 0)
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

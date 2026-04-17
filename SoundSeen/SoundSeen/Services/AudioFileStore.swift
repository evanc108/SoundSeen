//
//  AudioFileStore.swift
//  SoundSeen
//

import Foundation

enum AudioFileStore {
    /// Best-effort MIME type guess based on file extension for multipart upload.
    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a", "mp4", "aac": return "audio/mp4"
        case "aiff", "aif": return "audio/aiff"
        default: return "audio/mpeg"
        }
    }
}

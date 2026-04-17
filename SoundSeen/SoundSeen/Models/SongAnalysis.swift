//
//  SongAnalysis.swift
//  SoundSeen
//
//  Codable mirror of the Pydantic models in soundseen-backend/main.py.
//  Decoded with JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase,
//  so Swift property names are camelCase while the wire format stays snake_case.
//

import Foundation

struct SongAnalysis: Codable, Hashable, Sendable {
    let songId: String
    let filename: String
    let storagePath: String
    let durationSeconds: Double
    let bpm: Double
    let bandNames: [String]
    let beatEvents: [BeatEvent]
    let onsetEvents: [OnsetEvent]
    let sections: [SongSection]
    let emotion: Emotion
    let frames: Frames
    let processingTimeSeconds: Double
}

struct BeatEvent: Codable, Hashable, Sendable {
    let time: Double
    let intensity: Double
    let sharpness: Double
    let bassIntensity: Double
    let isDownbeat: Bool
}

struct OnsetEvent: Codable, Hashable, Sendable {
    let time: Double
    let intensity: Double
    let sharpness: Double
    let attackStrength: Double
    let attackTimeMs: Double
    let decayTimeMs: Double
    let sustainLevel: Double
    let attackSlope: Double
}

struct Frames: Codable, Hashable, Sendable {
    /// Frame duration in milliseconds (~23ms from backend).
    let frameDurationMs: Double
    let count: Int
    let time: [Double]
    let energy: [Double]
    /// Outer: frame index. Inner: 8 frequency bands, ordered per `SongAnalysis.bandNames`.
    let bands: [[Double]]
    let centroid: [Double]
    let flux: [Double]
    let hue: [Double]
    let chromaStrength: [Double]
    let harmonicRatio: [Double]
}

struct Emotion: Codable, Hashable, Sendable {
    /// Seconds between samples (backend uses 0.5s).
    let interval: Double
    let valence: [Double]
    let arousal: [Double]
}

struct SongSection: Codable, Hashable, Sendable {
    let start: Double
    let end: Double
    let label: String
    let energyProfile: String
}

extension JSONDecoder {
    /// Shared decoder configured to match the backend's snake_case response.
    static let soundSeen: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

extension JSONEncoder {
    /// Shared encoder for persisting SongAnalysis back into SwiftData.
    static let soundSeen: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
}

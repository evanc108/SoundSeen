//
//  SongStructureScanner.swift
//  SoundSeen
//
//  Heuristic energy-based scan: finds Verse / Buildup / Drop regions from RMS envelope.
//

import AVFoundation
import Foundation

enum SongStructureKind: String, CaseIterable, Sendable {
    case verse = "Verse"
    case buildup = "Buildup"
    case drop = "Drop"
}

struct SongStructureMarker: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: SongStructureKind
    /// Position on timeline [0, 1]
    let progress: Double
    let timeSeconds: TimeInterval

    /// Explicit `nonisolated` so markers can be built from `SongStructureScanner.scan` (background) under Swift 6 default isolation.
    nonisolated init(kind: SongStructureKind, progress: Double, timeSeconds: TimeInterval) {
        self.id = UUID()
        self.kind = kind
        self.progress = progress
        self.timeSeconds = timeSeconds
    }
}

enum SongStructureScanner {
    /// Runs file I/O and RMS work; safe to call from a background task (not MainActor).
    nonisolated static func scan(url: URL) throws -> [SongStructureMarker] {
        let hopSeconds = 0.25 // RMS window hop (seconds)
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sr = format.sampleRate
        let totalFrames = file.length
        guard totalFrames > 0, sr > 0 else { return defaultMarkers(duration: 1) }

        let duration = Double(totalFrames) / sr
        let hopFrames = max(AVAudioFrameCount(256), AVAudioFrameCount(sr * hopSeconds))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: hopFrames) else {
            return defaultMarkers(duration: duration)
        }

        var energies: [Float] = []
        var position: AVAudioFramePosition = 0

        while position < totalFrames {
            let remaining = totalFrames - position
            let toRead = min(AVAudioFrameCount(remaining), hopFrames)
            buffer.frameLength = toRead
            do {
                try file.read(into: buffer, frameCount: toRead)
            } catch {
                break
            }
            energies.append(rms(buffer: buffer))
            position += AVAudioFramePosition(toRead)
        }

        guard energies.count >= 8 else {
            return defaultMarkers(duration: duration)
        }

        let smoothed = smooth(energies, window: 5)
        guard let dropIdx = smoothed.indices.max(by: { smoothed[$0] < smoothed[$1] }) else {
            return defaultMarkers(duration: duration)
        }

        let n = smoothed.count
        let verseIdx = min(max(1, n / 6), max(1, dropIdx - 3))
        var buildupIdx = verseIdx + max(1, (dropIdx - verseIdx) / 2)
        if buildupIdx >= dropIdx {
            buildupIdx = max(verseIdx + 1, dropIdx - 1)
        }

        let idxToTime: (Int) -> TimeInterval = { i in
            min(duration, max(0, Double(i) * hopSeconds))
        }

        let vProg = idxToTime(verseIdx) / duration
        let bProg = idxToTime(buildupIdx) / duration
        let dProg = idxToTime(dropIdx) / duration

        return [
            SongStructureMarker(kind: .verse, progress: vProg, timeSeconds: idxToTime(verseIdx)),
            SongStructureMarker(kind: .buildup, progress: bProg, timeSeconds: idxToTime(buildupIdx)),
            SongStructureMarker(kind: .drop, progress: dProg, timeSeconds: idxToTime(dropIdx)),
        ]
    }

    nonisolated private static func defaultMarkers(duration: TimeInterval) -> [SongStructureMarker] {
        guard duration > 0.5 else {
            return [
                SongStructureMarker(kind: .verse, progress: 0.15, timeSeconds: 0),
                SongStructureMarker(kind: .buildup, progress: 0.45, timeSeconds: 0),
                SongStructureMarker(kind: .drop, progress: 0.72, timeSeconds: 0),
            ]
        }
        return [
            SongStructureMarker(kind: .verse, progress: 0.18, timeSeconds: duration * 0.18),
            SongStructureMarker(kind: .buildup, progress: 0.48, timeSeconds: duration * 0.48),
            SongStructureMarker(kind: .drop, progress: 0.72, timeSeconds: duration * 0.72),
        ]
    }

    nonisolated private static func rms(buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        let ch = Int(buffer.format.channelCount)
        var sum: Float = 0
        let count = Float(n * max(ch, 1))
        for c in 0..<ch {
            let p = data[c]
            for i in 0..<n {
                let v = p[i]
                sum += v * v
            }
        }
        return sqrt(sum / max(count, 1))
    }

    nonisolated private static func smooth(_ x: [Float], window: Int) -> [Float] {
        guard window > 1, x.count >= window else { return x }
        let w = window / 2
        var out = [Float](repeating: 0, count: x.count)
        for i in x.indices {
            let a = max(0, i - w)
            let b = min(x.count - 1, i + w)
            var s: Float = 0
            var k: Float = 0
            for j in a...b {
                s += x[j]
                k += 1
            }
            out[i] = s / max(k, 1)
        }
        return out
    }

    /// Which section the playhead is in (for badge), given ordered verse → buildup → drop markers.
    nonisolated static func currentSection(
        timeSeconds: TimeInterval,
        duration: TimeInterval,
        markers: [SongStructureMarker]
    ) -> SongStructureKind {
        guard duration > 0.1 else { return .verse }
        let sorted = markers.sorted { $0.timeSeconds < $1.timeSeconds }
        guard sorted.count >= 3 else { return .verse }
        let v = sorted[0].timeSeconds
        let b = sorted[1].timeSeconds
        let d = sorted[2].timeSeconds
        let t = timeSeconds
        if t < v { return .verse }
        if t < b { return .verse }
        if t < d { return .buildup }
        return .drop
    }
}

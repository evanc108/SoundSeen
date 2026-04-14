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
        let dropCandidates = detectDropIndices(in: smoothed, hopSeconds: hopSeconds)
        guard !dropCandidates.isEmpty else {
            return defaultMarkers(duration: duration)
        }

        let idxToTime: (Int) -> TimeInterval = { i in
            min(duration, max(0, Double(i) * hopSeconds))
        }

        var out: [SongStructureMarker] = []
        var previousDropIdx = 0

        for (order, dropIdx) in dropCandidates.enumerated() {
            let buildupIdx = max(previousDropIdx + 1, detectBuildupStartIndex(in: smoothed, endingAt: dropIdx, hopSeconds: hopSeconds))

            let verseIdx: Int
            if order == 0 {
                verseIdx = max(1, min(buildupIdx - 1, max(1, Int(Double(dropIdx) * 0.35))))
            } else {
                verseIdx = max(previousDropIdx + 1, min(buildupIdx - 1, previousDropIdx + 2))
            }

            if verseIdx < buildupIdx {
                out.append(
                    SongStructureMarker(
                        kind: .verse,
                        progress: idxToTime(verseIdx) / duration,
                        timeSeconds: idxToTime(verseIdx)
                    )
                )
            }
            if buildupIdx < dropIdx {
                out.append(
                    SongStructureMarker(
                        kind: .buildup,
                        progress: idxToTime(buildupIdx) / duration,
                        timeSeconds: idxToTime(buildupIdx)
                    )
                )
            }
            out.append(
                SongStructureMarker(
                    kind: .drop,
                    progress: idxToTime(dropIdx) / duration,
                    timeSeconds: idxToTime(dropIdx)
                )
            )
            previousDropIdx = dropIdx
        }

        return out.sorted { $0.timeSeconds < $1.timeSeconds }
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
        guard !sorted.isEmpty else { return .verse }

        let t = max(0, timeSeconds)
        let dropHoldSeconds: TimeInterval = 7.5
        var activeKind: SongStructureKind = .verse
        var activeTime: TimeInterval = 0

        for marker in sorted {
            if marker.timeSeconds <= t {
                activeKind = marker.kind
                activeTime = marker.timeSeconds
            } else {
                break
            }
        }

        if activeKind == .drop, t - activeTime > dropHoldSeconds {
            return .verse
        }
        return activeKind
    }

    nonisolated private static func detectDropIndices(in smoothed: [Float], hopSeconds: Double) -> [Int] {
        guard smoothed.count >= 8 else { return [] }
        let n = smoothed.count

        // Use energy *increase* (onset) rather than peak energy.
        var diff = [Float](repeating: 0, count: n)
        for i in 1..<n {
            diff[i] = smoothed[i] - smoothed[i - 1]
        }

        let sortedE = smoothed.sorted()
        let medianE = sortedE[n / 2]
        let energyGate = max(medianE * 1.05, 0.008)

        let sortedD = diff.sorted()
        let medianD = sortedD[n / 2]
        let jumpGate = max(medianD * 4.0, 0.002)

        var candidates: [Int] = []
        for i in 2..<(n - 2) {
            // local maximum in diff = impact onset; require energy not too low.
            if diff[i] > jumpGate,
               diff[i] >= diff[i - 1],
               diff[i] >= diff[i + 1],
               smoothed[i] > energyGate {
                candidates.append(i)
            }
        }

        if candidates.isEmpty, let strongest = smoothed.indices.max(by: { smoothed[$0] < smoothed[$1] }) {
            return [strongest]
        }

        let minGap = max(4, Int(10.0 / hopSeconds))
        let ranked = candidates.sorted { diff[$0] > diff[$1] }
        var selected: [Int] = []
        for idx in ranked {
            if selected.allSatisfy({ abs($0 - idx) >= minGap }) {
                selected.append(idx)
            }
            if selected.count >= 5 { break }
        }
        return selected.sorted()
    }

    nonisolated private static func detectBuildupStartIndex(in smoothed: [Float], endingAt dropIdx: Int, hopSeconds: Double) -> Int {
        guard dropIdx > 3 else { return max(1, dropIdx - 1) }
        // Walk backward until the slope stops rising for a bit.
        let lookbackMax = max(6, Int(26.0 / hopSeconds))
        let startBound = max(1, dropIdx - lookbackMax)
        let flatGate: Float = 0.0015

        var i = dropIdx - 1
        var flatCount = 0
        while i > startBound {
            let d = smoothed[i] - smoothed[i - 1]
            if d < flatGate {
                flatCount += 1
            } else {
                flatCount = 0
            }
            // If we’ve been “not rising” for ~1 second, consider that the start of the buildup.
            if flatCount >= max(3, Int(1.0 / hopSeconds)) {
                return min(dropIdx - 1, i)
            }
            i -= 1
        }
        return startBound
    }
}

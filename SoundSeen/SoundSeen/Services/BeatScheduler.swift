//
//  BeatScheduler.swift
//  SoundSeen
//
//  Single-cursor broadcaster over analysis.beatEvents. Multiple beat-driven
//  visualization layers (rings, orb, flash, bass floor) subscribe with a
//  callback and receive the same BeatEvent whenever the cursor advances.
//
//  Clock discipline matches VisualizerState / HapticEngine / OnsetParticleController:
//  backward jump OR forward jump > 2.0s rebinds the cursor via binary search;
//  small scrubs advance naturally through the while-loops.
//

import Foundation
import Observation

@Observable
@MainActor
final class BeatScheduler {
    @ObservationIgnored private let beats: [BeatEvent]
    @ObservationIgnored private var cursor: Int = 0
    @ObservationIgnored private var subscribers: [(BeatEvent) -> Void] = []

    /// Bumped on every fire so @Observable consumers can re-read if they want
    /// to wedge a dependency into a Canvas draw closure, mirroring the
    /// OnsetParticleController pattern.
    private(set) var generation: Int = 0

    init(beats: [BeatEvent]) {
        self.beats = beats
    }

    /// Append a subscriber. Closures are retained — capture `[weak self]` on
    /// any reference-type subscriber to avoid a retain cycle.
    func subscribe(_ cb: @escaping (BeatEvent) -> Void) {
        subscribers.append(cb)
    }

    /// Drive the beat cursor forward one tick. Wire into
    /// `AudioPlayer.addTickHandler` alongside visualizer + haptics + onsets.
    func tick(prevTime: Double, currentTime: Double) {
        // Seek discontinuity — identical pattern to VisualizerState.swift:128.
        if currentTime < prevTime || (currentTime - prevTime) > 2.0 {
            cursor = firstBeatIndex(atOrAfter: currentTime)
            return
        }

        // Skip any beats already in the past at the start of this tick.
        while cursor < beats.count && beats[cursor].time <= prevTime {
            cursor += 1
        }

        // Fire every beat that occurred in (prevTime, currentTime].
        while cursor < beats.count && beats[cursor].time <= currentTime {
            let b = beats[cursor]
            for cb in subscribers {
                cb(b)
            }
            cursor += 1
            generation &+= 1
        }
    }

    // MARK: - Private

    private func firstBeatIndex(atOrAfter time: Double) -> Int {
        var lo = 0
        var hi = beats.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if beats[mid].time < time {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}

//
//  HapticEngine.swift
//  SoundSeen
//
//  Tick-driven Core Haptics player. On every AudioPlayer display-link tick,
//  HapticEngine advances a cursor across a sorted beat array and fires a
//  transient event for each beat that falls in (prevTime, currentTime].
//  This approach survives seek/pause/scrub because we do not pre-schedule a
//  CHHapticPattern bound to the engine's timeline.
//
//  CHHapticEngine silently dies on audio-session interruptions (backgrounding,
//  phone calls), so we reinstall stopped/reset handlers that restart it.
//

import CoreHaptics
import Foundation

@MainActor
final class HapticEngine {
    private var engine: CHHapticEngine?
    private var beats: [BeatEvent] = []
    private var cursor: Int = 0
    private(set) var isEnabled: Bool = true

    /// True if the device reports hardware haptic support. The simulator always
    /// returns false, so haptics become no-ops there (the rest of the app still
    /// works normally).
    let isSupported: Bool = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    // MARK: - Lifecycle

    func start() {
        guard isSupported else { return }
        if engine != nil { return }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = true
            engine.stoppedHandler = { [weak self] _ in
                // Drop the engine reference so the next beat tries to rebuild.
                Task { @MainActor in self?.engine = nil }
            }
            engine.resetHandler = { [weak self] in
                Task { @MainActor in
                    try? self?.engine?.start()
                }
            }
            try engine.start()
            self.engine = engine
        } catch {
            print("HapticEngine: failed to start: \(error)")
            engine = nil
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
    }

    /// Install a new beat schedule. Call this after decoding a SavedSong.
    func prepare(beats: [BeatEvent]) {
        self.beats = beats.sorted { $0.time < $1.time }
        cursor = 0
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    // MARK: - Tick

    /// Drive beats forward on the AudioPlayer clock. Called from the display
    /// link via `AudioPlayer.addTickHandler`.
    func tick(prevTime: Double, currentTime: Double) {
        guard isEnabled, isSupported else { return }

        // Discontinuity detection: if time moved backwards or jumped by more
        // than a couple seconds, treat it as a seek and rebind the cursor
        // via binary search.
        if currentTime < prevTime || (currentTime - prevTime) > 2.0 {
            cursor = firstBeatIndex(atOrAfter: currentTime)
            return
        }

        // Ensure the cursor is at the first unplayed beat for the current time.
        while cursor < beats.count && beats[cursor].time <= prevTime {
            cursor += 1
        }

        while cursor < beats.count && beats[cursor].time <= currentTime {
            fire(beat: beats[cursor])
            cursor += 1
        }
    }

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

    // MARK: - Transient playback

    /// Reads the user's haptic intensity mode from UserDefaults (same key the
    /// existing VisualizerView menu writes to) and maps it to a multiplier that
    /// mirrors `HapticIntensityMode` in HapticConductor.swift.
    private func currentMultiplier() -> Double {
        let raw = UserDefaults.standard.string(forKey: "soundseen.hapticIntensityMode")
        switch raw {
        case "subtle": return 0.65
        case "intense": return 1.28
        default: return 1.0
        }
    }

    private func fire(beat: BeatEvent) {
        guard let engine else {
            // Engine died — attempt to restart for the next beat.
            start()
            return
        }

        let mode = currentMultiplier()
        let intensityValue: Double
        let sharpnessValue: Double
        if beat.isDownbeat {
            intensityValue = min(1.0, max(0.30, beat.intensity * mode * 1.25))
            sharpnessValue = min(1.0, max(0.0, beat.sharpness + 0.20))
        } else {
            intensityValue = min(1.0, max(0.15, beat.intensity * mode * 0.70))
            sharpnessValue = min(1.0, max(0.0, beat.sharpness * 0.85))
        }

        let intensity = CHHapticEventParameter(
            parameterID: .hapticIntensity,
            value: Float(intensityValue)
        )
        let sharpness = CHHapticEventParameter(
            parameterID: .hapticSharpness,
            value: Float(sharpnessValue)
        )
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [intensity, sharpness],
            relativeTime: 0
        )
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            print("HapticEngine: fire failed: \(error)")
        }
    }
}

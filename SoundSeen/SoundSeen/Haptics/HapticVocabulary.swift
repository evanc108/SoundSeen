//
//  HapticVocabulary.swift
//  SoundSeen
//
//  Coordinated haptic layer that rides the AudioPlayer clock in parallel
//  with the visualizer. Four voices:
//
//    1. Beats    — tick-driven transients, downbeats 2x intensity (same
//                  algorithm as the legacy HapticEngine, rolled in here so
//                  the old engine can be retired).
//    2. Onsets   — additional transients for backend OnsetEvents that
//                  aren't beats (snare hits, stabs, sibilance). Sharpness
//                  scaled by the onset's attack envelope.
//    3. Patterns — .ahap files played on demand (drop, buildup, break).
//    4. Hum      — continuous low-intensity rumble whose intensity tracks
//                  summed sub_bass + bass band energy. Drives
//                  low-frequency "feel" even when no transient is firing.
//                  Uses CHHapticAdvancedPatternPlayer so we can push
//                  dynamic intensity parameters per frame without
//                  re-creating the player.
//
//  This class supersedes HapticEngine for analyzed playback. Thread all
//  AudioPlayer.addTickHandler registrations through tick(prevTime:currentTime:).
//

import CoreHaptics
import Foundation

@MainActor
final class HapticVocabulary {
    // MARK: - Lifecycle

    private var engine: CHHapticEngine?
    private(set) var isEnabled: Bool = true
    /// Gates onset-firing entirely. Beats always fire when enabled; onsets
    /// can be very dense (hi-hats, sibilance) so we expose a separate gate
    /// for HUD control.
    var onsetVoiceEnabled: Bool = true
    var humVoiceEnabled: Bool = true

    let isSupported: Bool = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    // MARK: - Event schedules (immutable after prepare)

    private var beats: [BeatEvent] = []
    private var onsets: [OnsetEvent] = []

    // MARK: - Cursors

    private var beatCursor: Int = 0
    private var onsetCursor: Int = 0

    // MARK: - Continuous hum

    private var humPlayer: CHHapticAdvancedPatternPlayer?
    /// Smoothed intensity of the summed low-band energy. Pushed to the
    /// continuous event as a dynamic parameter every tick.
    private var smoothedHum: Float = 0

    // MARK: - Public API

    func start() {
        guard isSupported else { return }
        if engine != nil { return }
        do {
            let eng = try CHHapticEngine()
            eng.isAutoShutdownEnabled = true
            eng.stoppedHandler = { [weak self] _ in
                Task { @MainActor in
                    self?.engine = nil
                    self?.humPlayer = nil
                }
            }
            eng.resetHandler = { [weak self] in
                Task { @MainActor in
                    try? self?.engine?.start()
                    self?.humPlayer = nil  // force rebuild
                }
            }
            try eng.start()
            self.engine = eng
        } catch {
            print("HapticVocabulary: start failed: \(error)")
            engine = nil
        }
    }

    func stop() {
        humPlayer = nil
        engine?.stop()
        engine = nil
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { humPlayer = nil }
    }

    /// Install new schedules. Call after analysis is decoded.
    func prepare(analysis: SongAnalysis) {
        self.beats = analysis.beatEvents.sorted { $0.time < $1.time }
        self.onsets = analysis.onsetEvents.sorted { $0.time < $1.time }
        self.beatCursor = 0
        self.onsetCursor = 0
    }

    // MARK: - Tick

    /// Drive forward on the AudioPlayer clock. `lowBandIntensity` is the
    /// sum of sub_bass + bass (clamped), used to modulate the continuous
    /// hum so the hum "breathes" with the music.
    func tick(prevTime: Double, currentTime: Double, lowBandIntensity: Double) {
        guard isEnabled, isSupported else { return }

        // Seek / scrub.
        if currentTime < prevTime || (currentTime - prevTime) > 2.0 {
            beatCursor = firstIndex(in: beats.map(\.time), atOrAfter: currentTime)
            onsetCursor = firstIndex(in: onsets.map(\.time), atOrAfter: currentTime)
            smoothedHum = 0
            return
        }

        fireBeats(prev: prevTime, current: currentTime)
        if onsetVoiceEnabled { fireOnsets(prev: prevTime, current: currentTime) }
        if humVoiceEnabled { updateHum(intensity: lowBandIntensity) }
    }

    // MARK: - Pattern playback (.ahap files)

    /// Play a named pattern from the app bundle. Pass the bare name without
    /// the ".ahap" extension. Used for section gestures (drop, buildup).
    func playPattern(named name: String) {
        guard isEnabled, isSupported, let engine = engine else { return }
        guard let url = Bundle.main.url(forResource: name, withExtension: "ahap") else {
            print("HapticVocabulary: pattern '\(name).ahap' not found in bundle")
            return
        }
        do {
            try engine.playPattern(from: url)
        } catch {
            print("HapticVocabulary: playPattern('\(name)') failed: \(error)")
        }
    }

    // MARK: - Beats

    private func fireBeats(prev: Double, current: Double) {
        while beatCursor < beats.count && beats[beatCursor].time <= prev {
            beatCursor += 1
        }
        while beatCursor < beats.count && beats[beatCursor].time <= current {
            fireBeat(beats[beatCursor])
            beatCursor += 1
        }
    }

    private func fireBeat(_ beat: BeatEvent) {
        guard let engine = engine else { start(); return }
        let mul = intensityMultiplier()
        let intensityValue: Double
        let sharpnessValue: Double
        if beat.isDownbeat {
            intensityValue = min(1, max(0.30, beat.intensity * mul * 1.25))
            sharpnessValue = min(1, max(0, beat.sharpness + 0.20))
        } else {
            intensityValue = min(1, max(0.15, beat.intensity * mul * 0.70))
            sharpnessValue = min(1, max(0, beat.sharpness * 0.85))
        }
        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(intensityValue))
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(sharpnessValue))
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [intensity, sharpness], relativeTime: 0)
        playOnce(event: event, on: engine)
    }

    // MARK: - Onsets

    private func fireOnsets(prev: Double, current: Double) {
        while onsetCursor < onsets.count && onsets[onsetCursor].time <= prev {
            onsetCursor += 1
        }
        while onsetCursor < onsets.count && onsets[onsetCursor].time <= current {
            fireOnset(onsets[onsetCursor])
            onsetCursor += 1
        }
    }

    private func fireOnset(_ onset: OnsetEvent) {
        guard let engine = engine else { start(); return }
        let mul = intensityMultiplier()
        // Onsets are usually lighter than beats (they overlap beats, and
        // firing both at full strength saturates the taptic). Scale down.
        let intensityValue = min(1.0, max(0.08, onset.intensity * mul * 0.45))
        // Attack slope (steeper = sharper taptic feel). Fall back to the
        // backend's sharpness value if slope is flat.
        let slopeSharpness = min(1.0, onset.attackSlope)
        let sharpnessValue = min(1.0, max(0, max(onset.sharpness * 0.7, slopeSharpness)))
        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(intensityValue))
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(sharpnessValue))
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [intensity, sharpness], relativeTime: 0)
        playOnce(event: event, on: engine)
    }

    // MARK: - Continuous hum

    /// Update the continuous hum's intensity to track summed low-band
    /// energy. Creates the player lazily on first non-trivial energy.
    private func updateHum(intensity: Double) {
        let target = Float(max(0, min(1, intensity)) * 0.55)  // cap so hum never drowns transients
        smoothedHum = 0.12 * target + 0.88 * smoothedHum
        guard let engine = engine else { return }
        if humPlayer == nil {
            // Create an effectively infinite continuous event. 3600s is
            // longer than any song; we rebuild on stop/seek anyway.
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2)
                ],
                relativeTime: 0,
                duration: 3600
            )
            do {
                let pattern = try CHHapticPattern(events: [event], parameters: [])
                let player = try engine.makeAdvancedPlayer(with: pattern)
                try player.start(atTime: CHHapticTimeImmediate)
                humPlayer = player
            } catch {
                print("HapticVocabulary: hum player failed: \(error)")
                return
            }
        }
        guard let player = humPlayer else { return }
        do {
            try player.sendParameters(
                [CHHapticDynamicParameter(
                    parameterID: .hapticIntensityControl,
                    value: smoothedHum,
                    relativeTime: 0
                )],
                atTime: CHHapticTimeImmediate
            )
        } catch {
            // If sendParameters fails (engine reset), invalidate so we
            // recreate next tick.
            humPlayer = nil
        }
    }

    // MARK: - Internals

    private func playOnce(event: CHHapticEvent, on engine: CHHapticEngine) {
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            print("HapticVocabulary: transient fire failed: \(error)")
        }
    }

    private func intensityMultiplier() -> Double {
        let raw = UserDefaults.standard.string(forKey: "soundseen.hapticIntensityMode")
        switch raw {
        case "subtle": return 0.65
        case "intense": return 1.28
        default: return 1.0
        }
    }

    private func firstIndex(in times: [Double], atOrAfter time: Double) -> Int {
        var lo = 0
        var hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < time { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

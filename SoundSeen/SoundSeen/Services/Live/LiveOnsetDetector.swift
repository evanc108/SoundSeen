//
//  LiveOnsetDetector.swift
//  SoundSeen
//
//  Adaptive-threshold spectral-flux onset detector. Runs on the log-mel
//  output of LiveFeatureExtractor: half-wave rectified frame-to-frame
//  difference summed across mel bands → onset strength envelope; peaks
//  above `local_median + K × MAD` (with refractory) become OnsetEvents.
//
//  Matches librosa.onset.onset_detect closely enough for haptic sync; the
//  attack envelope fields (attackTimeMs, decaySlope etc.) are rough
//  heuristics derived from recent envelope slope since we don't have the
//  ms-scale waveform handy here.
//

import Foundation

/// Nonisolated — runs on LiveAudioEngine's serial DSP queue.
nonisolated final class LiveOnsetDetector {
    /// Size of the rolling onset-strength window used for adaptive threshold.
    /// 22 frames ≈ 0.5s @ 43fps — long enough for a stable local baseline,
    /// short enough to react to section changes.
    private let windowSize = 22
    /// Peaks must exceed `median + K × MAD` to fire.
    private let thresholdK: Float = 1.5
    /// Minimum spacing between onsets. 80ms prevents double-firing on
    /// attack decays; shorter than the 100–150ms typical inter-onset
    /// interval of fast percussion.
    private let refractorySec: Double = 0.08

    private var prevMelLog: [Float] = []
    private var strengthWindow: [Float] = []
    private var lastOnsetTime: Double = -.infinity
    private var recentStrength: [Float] = []  // for attack envelope

    /// Process one frame. Returns an OnsetEvent if an onset fires; nil
    /// otherwise.
    func process(melLog: [Double], time: Double) -> OnsetEvent? {
        // Convert to Float once; mel energies are small so the precision
        // difference doesn't matter for detection.
        let mel = melLog.map(Float.init)

        // First call: seed the baseline and bail.
        guard !prevMelLog.isEmpty, prevMelLog.count == mel.count else {
            prevMelLog = mel
            return nil
        }

        // Half-wave rectified log-mel difference, summed across bands.
        // This is what librosa.onset.onset_strength computes by default.
        var strength: Float = 0
        for i in 0..<mel.count {
            let d = mel[i] - prevMelLog[i]
            if d > 0 { strength += d }
        }
        prevMelLog = mel

        strengthWindow.append(strength)
        if strengthWindow.count > windowSize {
            strengthWindow.removeFirst(strengthWindow.count - windowSize)
        }
        recentStrength.append(strength)
        if recentStrength.count > 12 { recentStrength.removeFirst() }

        // Need enough baseline samples before firing.
        guard strengthWindow.count >= 10 else { return nil }

        // Local median + MAD. Full sort of 22 elements is fine — cheaper
        // than a running-order data structure.
        let sorted = strengthWindow.sorted()
        let median = sorted[sorted.count / 2]
        var absDevs = [Float](repeating: 0, count: sorted.count)
        for i in 0..<sorted.count { absDevs[i] = abs(sorted[i] - median) }
        absDevs.sort()
        let mad = absDevs[absDevs.count / 2]
        let threshold = median + thresholdK * max(mad, 0.05)

        // Refractory.
        if time - lastOnsetTime < refractorySec { return nil }

        // Peak: current strength above threshold AND greater than the
        // previous frame's strength (rising edge). Without the rising-edge
        // gate we'd also fire on decays that slowly drift above threshold.
        let prev = strengthWindow.count >= 2
            ? strengthWindow[strengthWindow.count - 2]
            : 0
        guard strength > threshold, strength > prev else { return nil }

        lastOnsetTime = time

        // Normalize intensity against the local window peak.
        var windowMax: Float = 0
        for v in strengthWindow where v > windowMax { windowMax = v }
        let intensity = Double(min(1, strength / max(windowMax, 1e-6)))

        // Attack envelope heuristics:
        //   attackTimeMs  — frames from local minimum to current peak × 23ms
        //   decayTimeMs   — estimated as 3× attackTime (a standard rule of
        //                   thumb; we don't have the actual decay yet).
        //   attackSlope   — (strength - baseline) / attackTimeMs
        //   sustainLevel  — ratio of baseline to peak, clipped [0, 0.8]
        var attackFrames = 1
        var localMin = strength
        for i in stride(from: recentStrength.count - 2, through: 0, by: -1) {
            if recentStrength[i] < localMin {
                localMin = recentStrength[i]
                attackFrames = recentStrength.count - i
            } else {
                break
            }
        }
        let attackTimeMs = Double(attackFrames) * 23.2
        let decayTimeMs = attackTimeMs * 3
        let attackSlope = Double(strength - localMin) / max(attackTimeMs, 1)
        let sustainLevel = Double(max(0, min(0.8, localMin / max(strength, 1e-6))))

        // Sharpness = normalized attack slope. Fast transients (high slope)
        // feel "sharp"; slow swells feel "soft."
        let sharpness = min(1, max(0, attackSlope * 20))

        return OnsetEvent(
            time: time,
            intensity: intensity,
            sharpness: sharpness,
            attackStrength: intensity,
            attackTimeMs: attackTimeMs,
            decayTimeMs: decayTimeMs,
            sustainLevel: sustainLevel,
            attackSlope: attackSlope
        )
    }

    /// Reset rolling state — call on audio-engine restart or large gap.
    func reset() {
        prevMelLog.removeAll(keepingCapacity: true)
        strengthWindow.removeAll(keepingCapacity: true)
        recentStrength.removeAll(keepingCapacity: true)
        lastOnsetTime = -.infinity
    }
}

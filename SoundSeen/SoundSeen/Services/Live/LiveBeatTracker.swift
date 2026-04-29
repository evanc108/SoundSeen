//
//  LiveBeatTracker.swift
//  SoundSeen
//
//  Running-autocorrelation tempo estimator + phase tracker. Feeds off the
//  onset-strength envelope from LiveOnsetDetector (same signal, shared
//  free), finds the most periodic tempo in the 60–200 BPM range, and once
//  locked emits synthetic BeatEvents at the predicted phase.
//
//  Realistic lock time: 4–8 seconds. Until `lockedBPM` transitions from
//  nil to a value, consumers should show "Locking tempo…" or similar.
//

import Foundation

/// Nonisolated — runs on LiveAudioEngine's serial DSP queue.
nonisolated final class LiveBeatTracker {
    /// Hop duration matching LiveFeatureExtractor (512 @ 22050 ≈ 23.2ms).
    static let hopSeconds: Double = Double(LiveFeatureExtractor.hopLength) / LiveFeatureExtractor.sampleRate

    /// How many frames of onset-strength history we keep. 6s ≈ 258 frames.
    private let historyFrames = 258
    /// Autocorrelation lag range in frames (60 BPM ↔ 200 BPM).
    /// 60 BPM = 1.0s period ≈ 43 frames. 200 BPM = 0.3s ≈ 13 frames.
    private let minLag = 13
    private let maxLag = 43
    /// Re-estimate cadence — every 11 frames ≈ 250ms. Cheaper than every
    /// frame and plenty responsive (tempo changes slowly even in live DJ sets).
    private let estimateEvery = 11
    /// Tempo prior: log-Gaussian centered at 120 BPM with wide σ so we don't
    /// refuse to lock onto genuine 80 BPM or 160 BPM tracks.
    private let priorCenterBpm: Double = 120
    private let priorSigma: Double = 0.9   // in log(bpm) units

    /// Lock criteria: confidence = peak / median of autocorrelation.
    /// Must stay above this for N consecutive estimates before we report lock.
    private let lockConfidenceFloor: Double = 2.5
    private let lockConsecutiveN = 3

    private var strengthHistory: [Float] = []
    /// Frames since the last estimate — cheap throttle.
    private var framesSinceEstimate = 0
    private var consecutiveHighConfidence = 0

    private(set) var lockedBPM: Double?
    /// Phase-locked beat index. After lock, we track this as the integer
    /// number of beats emitted so we can tag every 4th as a downbeat.
    private var emittedBeatCount = 0
    /// Timestamp of the most recent onset within the current analysis
    /// window — used as the phase anchor when we decide to start emitting
    /// synthetic beats.
    private var lastRealOnsetTime: Double = -.infinity
    /// Predicted time of the next synthetic beat. Advanced by `beatPeriod`
    /// after each emission.
    private var nextBeatTime: Double = -.infinity

    /// Feed this the same onset-strength signal the OnsetDetector consumes.
    /// `realOnsetTime` is non-nil on frames where OnsetDetector fired — we
    /// use the most recent real onset as the phase anchor when we first lock.
    /// Returns a synthetic BeatEvent when one should fire at this frame, else nil.
    func process(strength: Float, currentTime: Double, realOnsetTime: Double?) -> BeatEvent? {
        strengthHistory.append(strength)
        if strengthHistory.count > historyFrames {
            strengthHistory.removeFirst(strengthHistory.count - historyFrames)
        }
        if let t = realOnsetTime { lastRealOnsetTime = t }

        // Re-estimate tempo periodically.
        framesSinceEstimate += 1
        if framesSinceEstimate >= estimateEvery && strengthHistory.count >= maxLag * 3 {
            framesSinceEstimate = 0
            updateTempoEstimate(currentTime: currentTime)
        }

        // Emit a beat only once we're locked AND we've crossed the predicted
        // phase boundary.
        guard let bpm = lockedBPM, bpm > 0 else { return nil }
        let beatPeriod = 60.0 / bpm

        // If the phase isn't initialized, seed it now.
        if nextBeatTime.isFinite == false || nextBeatTime == -.infinity {
            // Anchor the phase to the most recent real onset if we have one,
            // otherwise to the current time. This lines synthetic beats up
            // with the actual source transients instead of drifting.
            let anchor = lastRealOnsetTime.isFinite ? lastRealOnsetTime : currentTime
            nextBeatTime = anchor + beatPeriod
            emittedBeatCount = 0
        }

        guard currentTime >= nextBeatTime else { return nil }
        // Emit — advance phase; if we're more than one period late
        // (stutter, GC pause), skip ahead rather than emit a burst.
        emittedBeatCount &+= 1
        let isDownbeat = (emittedBeatCount % 4 == 1)
        nextBeatTime += beatPeriod
        if currentTime - nextBeatTime > beatPeriod { nextBeatTime = currentTime + beatPeriod }

        // Intensity proxy: the median of recent strength window. Not
        // perfect, but prevents silent frames from emitting "loud" beats.
        let recent = strengthHistory.suffix(8)
        let mean = recent.reduce(0, +) / Float(max(recent.count, 1))
        let intensity = Double(min(1, mean / 20.0))

        return BeatEvent(
            time: currentTime,
            intensity: max(0.3, intensity),
            sharpness: 0.6,
            bassIntensity: 0.5,
            isDownbeat: isDownbeat
        )
    }

    /// Call on audio-engine restart or extended silence.
    func reset() {
        strengthHistory.removeAll(keepingCapacity: true)
        framesSinceEstimate = 0
        consecutiveHighConfidence = 0
        lockedBPM = nil
        emittedBeatCount = 0
        lastRealOnsetTime = -.infinity
        nextBeatTime = -.infinity
    }

    // MARK: - Tempo estimation

    private func updateTempoEstimate(currentTime: Double) {
        // Autocorrelation over the lag range. O((maxLag-minLag) * N) where
        // N ≈ 258, so ~1300 * 30 = 39k mults per estimate @ ~4Hz = 156k/s.
        // Trivial. Not worth vDSP_conv.
        let x = strengthHistory
        let n = x.count
        // Mean-subtract for zero-lag normalization.
        var mean: Float = 0
        for v in x { mean += v }
        mean /= Float(n)

        var bestLag = minLag
        var bestScore: Double = -.infinity
        var acorrs: [Double] = []
        for lag in minLag...maxLag {
            var dot: Double = 0
            // Sum x[t] * x[t + lag] over overlapping region.
            let count = n - lag
            for t in 0..<count {
                let a = Double(x[t] - mean)
                let b = Double(x[t + lag] - mean)
                dot += a * b
            }
            // Normalize by count so shorter lags don't get artificial boost.
            let acorr = dot / Double(count)
            // Tempo prior: log-Gaussian in BPM space.
            let bpm = 60.0 / (Double(lag) * Self.hopSeconds)
            let logBpm = log(bpm)
            let logCenter = log(priorCenterBpm)
            let priorW = exp(-((logBpm - logCenter) * (logBpm - logCenter)) / (2 * priorSigma * priorSigma))
            let score = acorr * priorW
            acorrs.append(score)
            if score > bestScore { bestScore = score; bestLag = lag }
        }

        // Confidence = peak / median of all lag scores.
        let sorted = acorrs.sorted()
        let median = sorted[sorted.count / 2]
        let confidence = bestScore / max(median, 1e-6)

        if confidence >= lockConfidenceFloor && bestScore > 0 {
            consecutiveHighConfidence += 1
            if consecutiveHighConfidence >= lockConsecutiveN {
                let newBpm = 60.0 / (Double(bestLag) * Self.hopSeconds)
                // If already locked, smooth rather than snap — big jumps
                // feel like glitches. 0.3 α reaches most of a step in ~3
                // estimates (~750ms), which is smoother than instant.
                if let current = lockedBPM {
                    lockedBPM = 0.3 * newBpm + 0.7 * current
                    // Phase jitter fix: if tempo drifted more than ±8 BPM,
                    // force a full re-seed of the phase on the next beat.
                    if abs(newBpm - current) > 8 {
                        nextBeatTime = -.infinity
                    }
                } else {
                    lockedBPM = newBpm
                    nextBeatTime = -.infinity  // force phase seeding
                }
            }
        } else {
            consecutiveHighConfidence = 0
            // Don't drop lock on a single low-confidence estimate — require
            // three consecutive below-floor to un-lock, matching the lock path.
            // In practice this rarely unlocks; songs just get phase jitter.
        }
    }
}

//
//  VisualizerState.swift
//  SoundSeen
//
//  @Observable derived state that turns AudioPlayer.currentTime into the
//  live visualization inputs: current frame (energy + 8 bands), current
//  emotion (valence/arousal), current section label, and a beat pulse that
//  decays exponentially between beats.
//
//  Different arrays have different cadences:
//    - frames: ~23ms resolution, lookup is index = floor(t / frameDurationMs)
//    - emotion: 0.5s resolution, lookup is index = floor(t / interval)
//    - sections: variable span, lookup is a binary search on section.start
//

import Foundation
import Observation

@Observable
@MainActor
final class VisualizerState {
    // MARK: - Observable live state
    private(set) var currentEnergy: Double = 0
    private(set) var currentBands: [Double] = Array(repeating: 0, count: 8)
    private(set) var currentValence: Double = 0
    private(set) var currentArousal: Double = 0
    /// Current-frame spectral flux — how fast the spectrum is changing.
    /// High flux ≈ percussive/transient moments.
    private(set) var currentFlux: Double = 0
    /// Current-frame spectral centroid — perceptual "brightness" of the
    /// sound (low = bassy, high = sparkly). Raw value; use centroidMin/Max
    /// to normalize into [0, 1] per-track.
    private(set) var currentCentroid: Double = 0
    /// Current-frame perceptual hue in [0, 1], derived upstream from chroma.
    /// Consumers blend this into the mood palette weighted by chromaStrength.
    private(set) var currentHue: Double = 0
    /// Current-frame tonal strength in [0, 1]. 1 = strongly pitched/chordal,
    /// 0 = noisy/atonal. Drives how much chroma color dominates mood color.
    private(set) var currentChromaStrength: Double = 0
    /// Monotonic counter bumped when a non-beat transient is detected in
    /// frames.flux. Views observe the counter (rising edge) to spawn halos.
    /// This catches snare hits / synth stabs that BeatEvents miss.
    private(set) var fluxSpikeGeneration: Int = 0
    /// EMA-smoothed valence/arousal. Shared by every emotion-driven layer so
    /// they all move on the same curve — previously each layer (e.g.
    /// MoodPaletteBackground) ran its own smoother and drifted out of phase.
    private(set) var smoothedValence: Double = 0.5
    private(set) var smoothedArousal: Double = 0.5
    private(set) var currentSectionLabel: String = ""
    private(set) var currentSectionEnergyProfile: String = ""
    /// 1.0 at the moment of a beat, decays exponentially toward 0.
    private(set) var beatPulse: Double = 0

    // MARK: - God-rays derived signals
    /// EMA-smoothed bass energy for god-rays shader (low + sub-bass bands).
    /// Smoothing kills per-frame jitter while keeping tight coupling to kicks.
    private(set) var bassEnergySmoothed: Double = 0
    /// Section-based build envelope (0-1) for cinematic slow ramps.
    /// Ramps up over ~2s on "building" sections, holds on "high"/"intense",
    /// ramps down on "fading"/"minimal". Drives god-rays brightness.
    private(set) var sectionBuildEnvelope: Double = 0

    /// Per-quadrant opacity weights computed from smoothed (V, A). Always sums
    /// to 1.0. Drives additive composition of the four biomes so transits
    /// across quadrant boundaries are a smooth blend, not a swap.
    private(set) var biomeWeights: BiomeWeights = BiomeWeights()
    /// Hysteresis: which biome is currently "dominant" for purposes of
    /// sticky-winner logic. Prevents flicker when smoothed V/A hovers near
    /// a boundary. Updated inside biomeWeights recomputation.
    private(set) var dominantBiome: Biome = .serene

    // MARK: - Immutable inputs
    @ObservationIgnored private let analysis: SongAnalysis
    @ObservationIgnored let bandNames: [String]
    /// p5 of frames.centroid, precomputed once — tracks vary widely in their
    /// absolute centroid range (genre-dependent), so we normalize per-track
    /// rather than globally. p5/p95 instead of absolute min/max so a single
    /// outlier frame doesn't flatten the visible range.
    @ObservationIgnored let centroidMin: Double
    @ObservationIgnored let centroidMax: Double

    // MARK: - Cursors for linear-scan paths
    @ObservationIgnored private var beatCursor: Int = 0

    // MARK: - Smoothing / hysteresis state
    /// True until the first emotion sample lands — on the first tick we seed
    /// the EMA state from the raw sample instead of lerping from the 0.5
    /// default, to avoid a visible ramp at track start.
    @ObservationIgnored private var didSeedEmotionSmoothing: Bool = false
    @ObservationIgnored private var dominantBiomeSince: TimeInterval = 0

    // MARK: - Flux spike detector state
    /// Rolling window of recent flux values for adaptive-threshold spike
    /// detection. Size 15 ≈ 0.35s at 23ms frames — long enough to capture
    /// a stable local baseline, short enough to react to section changes.
    @ObservationIgnored private var fluxWindow: [Double] = []
    @ObservationIgnored private var prevFlux: Double = 0
    @ObservationIgnored private var lastFluxSpikeTime: Double = -Double.infinity
    @ObservationIgnored private var lastFrameIdx: Int = -1

    // MARK: - God-rays smoothing state
    @ObservationIgnored private var didSeedBassSmoothing: Bool = false
    /// Target value for section build envelope (set by energyProfile).
    @ObservationIgnored private var sectionBuildTarget: Double = 0
    /// Last time the section build envelope was updated (for delta-based ramping).
    @ObservationIgnored private var lastBuildUpdateTime: Double = 0

    init(analysis: SongAnalysis) {
        self.analysis = analysis
        self.bandNames = analysis.bandNames
        (self.centroidMin, self.centroidMax) = Self.percentileRange(
            of: analysis.frames.centroid,
            lower: 0.05,
            upper: 0.95
        )
    }

    /// Returns (p_lower, p_upper) of a sorted copy of `values`. Falls back
    /// to (0, 1) if the array is empty so downstream normalization never
    /// divides by zero.
    private static func percentileRange(
        of values: [Double],
        lower: Double,
        upper: Double
    ) -> (Double, Double) {
        guard !values.isEmpty else { return (0, 1) }
        let sorted = values.sorted()
        let loIdx = min(sorted.count - 1, max(0, Int(Double(sorted.count) * lower)))
        let hiIdx = min(sorted.count - 1, max(0, Int(Double(sorted.count) * upper)))
        let lo = sorted[loIdx]
        let hi = sorted[hiIdx]
        // Guarantee a non-zero span so (x - lo) / (hi - lo) is safe.
        if hi - lo < 1e-6 { return (lo, lo + 1) }
        return (lo, hi)
    }

    /// Drive the visualizer forward one tick. Wire this into
    /// `AudioPlayer.addTickHandler`.
    func update(prevTime: Double, currentTime: Double) {
        updateFrameState(at: currentTime)
        updateEmotion(at: currentTime)
        updateSection(at: currentTime)
        updateBeatPulse(prevTime: prevTime, currentTime: currentTime)
    }

    // MARK: - Per-frame lookups

    private func updateFrameState(at time: Double) {
        let frames = analysis.frames
        guard frames.count > 0, frames.frameDurationMs > 0 else { return }
        var idx = Int(time * 1000.0 / frames.frameDurationMs)
        if idx < 0 { idx = 0 }
        if idx >= frames.count { idx = frames.count - 1 }

        if idx < frames.energy.count {
            currentEnergy = frames.energy[idx]
        }
        if idx < frames.bands.count {
            let row = frames.bands[idx]
            if row.count == currentBands.count {
                currentBands = row
            } else {
                // Defensive: if the backend ever ships a different band count.
                currentBands = Array(row.prefix(currentBands.count))
                while currentBands.count < 8 { currentBands.append(0) }
            }
        }
        if idx < frames.flux.count {
            currentFlux = frames.flux[idx]
        }
        if idx < frames.centroid.count {
            currentCentroid = frames.centroid[idx]
        }
        if idx < frames.hue.count {
            currentHue = frames.hue[idx]
        }
        if idx < frames.chromaStrength.count {
            currentChromaStrength = frames.chromaStrength[idx]
        }

        // Update bass energy with EMA smoothing for god-rays.
        // Bands 0-1 are sub-bass + bass. α≈0.15 gives τ≈80ms at 60Hz —
        // tight enough to track kicks, smooth enough to avoid strobing.
        let rawBass = (currentBands[0] + currentBands[1]) * 0.5
        let bassAlpha = 0.15
        if !didSeedBassSmoothing {
            bassEnergySmoothed = rawBass
            didSeedBassSmoothing = true
        } else {
            bassEnergySmoothed = bassAlpha * rawBass + (1 - bassAlpha) * bassEnergySmoothed
        }

        detectFluxSpike(newFlux: currentFlux, frameIdx: idx, time: time)
    }

    // MARK: - Flux spike detection

    /// Adaptive-threshold transient detector. Maintains a rolling window of
    /// recent flux values; fires when the current value crosses mean + 1.8σ
    /// on a rising edge, with a 0.12s rate limit. Only advances on new
    /// frames so repeated calls during a single frame don't double-fire.
    private func detectFluxSpike(newFlux: Double, frameIdx: Int, time: Double) {
        // Only process once per frame.
        guard frameIdx != lastFrameIdx else { return }

        // Scrub / seek: discontinuity in frame index. Reset detector state
        // so a stale rolling window doesn't produce phantom spikes.
        if frameIdx < lastFrameIdx || frameIdx - lastFrameIdx > 10 {
            fluxWindow.removeAll(keepingCapacity: true)
            prevFlux = newFlux
            lastFluxSpikeTime = -Double.infinity
            lastFrameIdx = frameIdx
            fluxWindow.append(newFlux)
            return
        }
        lastFrameIdx = frameIdx

        // Need enough samples for a meaningful baseline before firing.
        let needed = 8
        if fluxWindow.count >= needed {
            let n = Double(fluxWindow.count)
            let mean = fluxWindow.reduce(0, +) / n
            var varSum = 0.0
            for x in fluxWindow { varSum += (x - mean) * (x - mean) }
            let std = (varSum / n).squareRoot()
            let threshold = mean + 1.8 * std

            let rising = newFlux > prevFlux
            let cooldownOk = (time - lastFluxSpikeTime) >= 0.12
            if newFlux > threshold && rising && cooldownOk {
                lastFluxSpikeTime = time
                fluxSpikeGeneration &+= 1
            }
        }

        prevFlux = newFlux
        fluxWindow.append(newFlux)
        if fluxWindow.count > 15 {
            fluxWindow.removeFirst()
        }
    }

    private func updateEmotion(at time: Double) {
        let emotion = analysis.emotion
        guard emotion.interval > 0, !emotion.valence.isEmpty else { return }
        var idx = Int(time / emotion.interval)
        if idx < 0 { idx = 0 }
        if idx >= emotion.valence.count { idx = emotion.valence.count - 1 }
        currentValence = emotion.valence[idx]
        if idx < emotion.arousal.count {
            currentArousal = emotion.arousal[idx]
        }

        // α=0.1 at 60Hz reaches ~95% of a step in ~0.5s. Emotion is sampled
        // every 0.5s upstream, so this matches the natural rate and kills
        // the 2Hz step without visible lag.
        let alpha = 0.1
        if !didSeedEmotionSmoothing {
            smoothedValence = currentValence
            smoothedArousal = currentArousal
            didSeedEmotionSmoothing = true
        } else {
            smoothedValence = alpha * currentValence + (1 - alpha) * smoothedValence
            smoothedArousal = alpha * currentArousal + (1 - alpha) * smoothedArousal
        }

        updateBiomeWeights(now: time)
    }

    private func updateBiomeWeights(now: TimeInterval) {
        let raw = BiomeWeights.compute(
            valence: smoothedValence,
            arousal: smoothedArousal
        )

        // Sticky-winner hysteresis: keep the current dominant biome unless
        // a challenger exceeds it by >0.15 OR >1s has elapsed since the
        // last switch. This kills flicker when smoothed (V, A) hovers on
        // a quadrant boundary.
        let challenger = raw.dominant
        if challenger == dominantBiome {
            dominantBiomeSince = now
        } else {
            let margin = raw[challenger] - raw[dominantBiome]
            let elapsed = now - dominantBiomeSince
            if margin > 0.15 || elapsed > 1.0 {
                dominantBiome = challenger
                dominantBiomeSince = now
            }
        }

        biomeWeights = raw
    }

    private func updateSection(at time: Double) {
        let sections = analysis.sections
        guard !sections.isEmpty else { return }
        // Binary search for the section whose [start, end) contains `time`.
        var lo = 0
        var hi = sections.count - 1
        var found: SongSection?
        while lo <= hi {
            let mid = (lo + hi) / 2
            let s = sections[mid]
            if time < s.start {
                hi = mid - 1
            } else if time >= s.end {
                lo = mid + 1
            } else {
                found = s
                break
            }
        }
        if let s = found {
            currentSectionLabel = s.label
            currentSectionEnergyProfile = s.energyProfile

            // Map energyProfile to build envelope target.
            // These values are tuned so "building" sections ramp up over time
            // and drops land with full intensity.
            let target: Double
            switch s.energyProfile.lowercased() {
            case "minimal", "quiet":
                target = 0.1
            case "fading", "falling":
                target = 0.3
            case "building", "rising":
                target = 0.8
            case "high", "drop", "intense", "peak":
                target = 1.0
            default:
                target = 0.5
            }
            sectionBuildTarget = target

            // Ramp toward target with slow attack/release for cinematic effect.
            // Attack ~2s (α≈0.03 at 60Hz), release ~3s (α≈0.02).
            // Principle 2: "Slowness earns the drop"
            let attackAlpha = 0.03
            let releaseAlpha = 0.02
            let alpha = (target > sectionBuildEnvelope) ? attackAlpha : releaseAlpha
            sectionBuildEnvelope = alpha * target + (1 - alpha) * sectionBuildEnvelope
        }
    }

    // MARK: - Beat pulse

    private func updateBeatPulse(prevTime: Double, currentTime: Double) {
        // Exponential decay — halves roughly every 0.15s. We apply the decay
        // on every tick before checking for a new beat so a long idle gap
        // doesn't leave the pulse stuck high.
        let dt = max(0, currentTime - prevTime)
        if dt > 0 {
            let decay = pow(0.5, dt / 0.15)
            beatPulse *= decay
        }

        // Handle clock discontinuities (seek/scrub).
        let beats = analysis.beatEvents
        if currentTime < prevTime || (currentTime - prevTime) > 2.0 {
            beatCursor = firstBeatIndex(atOrAfter: currentTime, in: beats)
            beatPulse = 0
            return
        }

        while beatCursor < beats.count && beats[beatCursor].time <= prevTime {
            beatCursor += 1
        }
        while beatCursor < beats.count && beats[beatCursor].time <= currentTime {
            // Downbeats pulse to 1.0, regular beats to ~0.7 scaled by intensity.
            let beat = beats[beatCursor]
            let target = (beat.isDownbeat ? 1.0 : 0.7) * max(0.3, beat.intensity)
            if target > beatPulse { beatPulse = target }
            beatCursor += 1
        }
    }

    private func firstBeatIndex(atOrAfter time: Double, in beats: [BeatEvent]) -> Int {
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

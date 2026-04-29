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
    /// Current-frame harmonic vs. percussive balance (0 = percussive, 1 =
    /// harmonic). Drives whether HarmonicFormVoice renders smooth ribbons
    /// (harmonic) or crystalline shards (percussive).
    private(set) var currentHarmonicRatio: Double = 0.5
    /// Current-frame spectral rolloff (normalized). High-frequency cutoff;
    /// low rolloff = muffled/dark, high = bright/sparkly. Drives the
    /// sky-ceiling height for sparkle textures.
    private(set) var currentRolloff: Double = 0.5
    /// Current-frame zero-crossing rate (normalized). High in noise/sibilance,
    /// low in tonal/bassy content. Drives film grain density.
    private(set) var currentZCR: Double = 0.3
    /// Current-frame spectral contrast (normalized). High = peaky/clean
    /// spectrum, low = smeared/noisy. Drives ink-bleed edge raggedness.
    private(set) var currentSpectralContrast: Double = 0.5
    /// Current-frame first-4 MFCC coefficients (normalized). Coef 0 tracks
    /// energy; 1..3 encode timbre (brightness, warmth, nasality). Archetype
    /// stroke weight rides MFCC[1].
    private(set) var currentMFCC: [Double] = Array(repeating: 0.5, count: 4)
    /// Current-frame 12-pitch-class chroma vector (roughly [0, 1]). Drives
    /// per-pitch-class color mapping in ChromaSlickTexture.
    private(set) var currentChromaVector: [Double] = Array(repeating: 0, count: 12)
    /// Per-track normalized centroid in [0, 1] (p5..p95 mapped). Different
    /// tracks have wildly different absolute centroid ranges, so voices that
    /// read "brightness" want the normalized view, not the raw Hz-like value.
    private(set) var currentCentroidNormalized: Double = 0.5
    /// First derivative of normalized centroid, smoothed. Positive = rising
    /// pitch / brightness, negative = falling. Used by PitchGestureVoice to
    /// bias particles up/down since backend doesn't ship pitch_direction.
    private(set) var currentPitchDirection: Double = 0
    /// Monotonic counter bumped when a non-beat transient is detected in
    /// frames.flux. Views observe the counter (rising edge) to spawn halos.
    /// This catches snare hits / synth stabs that BeatEvents miss.
    private(set) var fluxSpikeGeneration: Int = 0
    /// Monotonic counter bumped when a backend OnsetEvent fires at the
    /// current playback time. Voices that want onset-synced bursts (shard
    /// shatters, attack blooms) observe this and read `lastOnset` on the
    /// rising edge.
    private(set) var onsetGeneration: Int = 0
    /// The OnsetEvent that caused the most recent onsetGeneration bump.
    /// nil until the first onset lands. Voices read this with attack
    /// envelope fields to shape their per-onset animation.
    private(set) var lastOnset: OnsetEvent? = nil
    /// EMA-smoothed valence/arousal. Shared by every emotion-driven layer so
    /// they all move on the same curve — previously each layer (e.g.
    /// MoodPaletteBackground) ran its own smoother and drifted out of phase.
    private(set) var smoothedValence: Double = 0.5
    private(set) var smoothedArousal: Double = 0.5
    private(set) var currentSectionLabel: String = ""
    private(set) var currentSectionEnergyProfile: String = ""
    /// Start time (seconds) of the currently-playing section, or 0 if none.
    private(set) var currentSectionStart: Double = 0
    /// End time (seconds) of the currently-playing section, or 0 if none.
    private(set) var currentSectionEnd: Double = 0
    /// 0..1 position within the current section. 0 at section entry, ~1 at
    /// section exit. Used by SectionDirector / DropChoreography to scale
    /// tension over the length of a buildup.
    var currentSectionProgress: Double {
        let span = currentSectionEnd - currentSectionStart
        guard span > 1e-6 else { return 0 }
        let t = (lastFrameTime - currentSectionStart) / span
        return max(0, min(1, t))
    }
    /// 1.0 at the moment of a beat, decays exponentially toward 0.
    private(set) var beatPulse: Double = 0

    /// Per-quadrant opacity weights computed from smoothed (V, A). Always sums
    /// to 1.0. Drives additive composition of the four biomes so transits
    /// across quadrant boundaries are a smooth blend, not a swap.
    private(set) var biomeWeights: BiomeWeights = BiomeWeights()
    /// Hysteresis: which biome is currently "dominant" for purposes of
    /// sticky-winner logic. Prevents flicker when smoothed V/A hovers near
    /// a boundary. Updated inside biomeWeights recomputation.
    private(set) var dominantBiome: Biome = .serene

    // MARK: - Immutable inputs
    /// nil in live mode — the state is driven by `ingest*` methods from
    /// LiveAudioEngine instead of polled off a precomputed SongAnalysis.
    @ObservationIgnored private let analysis: SongAnalysis?
    @ObservationIgnored let bandNames: [String]
    /// p5/p95 of centroid. In offline mode these are precomputed once from
    /// the full track; in live mode they're updated by a rolling estimator
    /// so per-track normalization still works without whole-song context.
    @ObservationIgnored private(set) var centroidMin: Double
    @ObservationIgnored private(set) var centroidMax: Double
    /// True if this state is being driven by a live microphone feed rather
    /// than precomputed frames. Gates the analysis-based update paths.
    @ObservationIgnored let isLive: Bool

    // MARK: - Cursors for linear-scan paths
    @ObservationIgnored private var beatCursor: Int = 0
    @ObservationIgnored private var onsetCursor: Int = 0
    @ObservationIgnored private var sortedOnsets: [OnsetEvent] = []
    @ObservationIgnored private var lastFrameTime: Double = 0
    /// Rolling average of raw centroid for per-frame rate-of-change. Smooth
    /// because raw centroid jitters frame-to-frame and we want the gesture,
    /// not the noise.
    @ObservationIgnored private var smoothedCentroidNormalized: Double = 0.5
    @ObservationIgnored private var didSeedCentroidSmoothing: Bool = false
    @ObservationIgnored private var prevSmoothedCentroidNormalized: Double = 0.5

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

    init(analysis: SongAnalysis) {
        self.analysis = analysis
        self.bandNames = analysis.bandNames
        self.isLive = false
        (self.centroidMin, self.centroidMax) = Self.percentileRange(
            of: analysis.frames.centroid,
            lower: 0.05,
            upper: 0.95
        )
        // Pre-sort onsets so the cursor walk is monotonic and binary search
        // on seek is correct. The backend usually ships them sorted, but we
        // defend against that changing.
        self.sortedOnsets = analysis.onsetEvents.sorted { $0.time < $1.time }
    }

    /// Live-microphone initializer. No SongAnalysis — LiveAudioEngine drives
    /// state directly via `ingest*` methods at ~43Hz. All downstream consumers
    /// (textures, archetypes, narratives) read the same @Observable properties
    /// and don't need to know whether they're in live or offline mode.
    init(liveBandNames: [String] = [
        "sub_bass", "bass", "low_mid", "mid",
        "upper_mid", "presence", "brilliance", "ultra_high",
    ]) {
        self.analysis = nil
        self.bandNames = liveBandNames
        self.isLive = true
        // Start with a reasonable default range; the rolling centroid
        // estimator widens/narrows these as samples accumulate.
        self.centroidMin = 500
        self.centroidMax = 4000
        self.sortedOnsets = []
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
    /// `AudioPlayer.addTickHandler`. No-op in live mode — state is driven
    /// by `ingest*` methods from LiveAudioEngine instead.
    func update(prevTime: Double, currentTime: Double) {
        guard analysis != nil else { return }
        lastFrameTime = currentTime
        updateFrameState(at: currentTime)
        updateEmotion(at: currentTime)
        updateSection(at: currentTime)
        updateBeatPulse(prevTime: prevTime, currentTime: currentTime)
        updateOnsetCursor(prevTime: prevTime, currentTime: currentTime)
    }

    // MARK: - Per-frame lookups

    private func updateFrameState(at time: Double) {
        guard let analysis else { return }
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
        if idx < frames.harmonicRatio.count {
            currentHarmonicRatio = frames.harmonicRatio[idx]
        }
        // Round-3 timbre fields — optional in Frames so old cached analyses
        // still decode; when present, they override the default.
        if let rolloff = frames.rolloff, idx < rolloff.count {
            currentRolloff = rolloff[idx]
        }
        if let zcr = frames.zcr, idx < zcr.count {
            currentZCR = zcr[idx]
        }
        if let contrast = frames.spectralContrast, idx < contrast.count {
            currentSpectralContrast = contrast[idx]
        }
        if let mfcc = frames.mfcc, idx < mfcc.count {
            let row = mfcc[idx]
            if row.count == currentMFCC.count {
                currentMFCC = row
            } else {
                currentMFCC = Array(row.prefix(currentMFCC.count))
                while currentMFCC.count < 4 { currentMFCC.append(0.5) }
            }
        }
        if let chroma = frames.chroma, idx < chroma.count {
            let row = chroma[idx]
            if row.count == currentChromaVector.count {
                currentChromaVector = row
            } else {
                currentChromaVector = Array(row.prefix(currentChromaVector.count))
                while currentChromaVector.count < 12 { currentChromaVector.append(0) }
            }
        }

        // Per-track normalized centroid (p5/p95 mapped to 0..1) — use this
        // in voices that want "brightness" as a normalized quantity, since
        // raw centroid values vary wildly between tracks.
        let spanCentroid = centroidMax - centroidMin
        let normalized: Double
        if spanCentroid > 1e-6 {
            normalized = max(0, min(1, (currentCentroid - centroidMin) / spanCentroid))
        } else {
            normalized = 0.5
        }
        // α=0.12 at 60Hz → visible responsiveness (~400ms to settle) while
        // killing the sub-frame jitter that makes naive centroid deltas
        // dominated by noise rather than real melodic motion.
        let alpha = 0.12
        prevSmoothedCentroidNormalized = smoothedCentroidNormalized
        if !didSeedCentroidSmoothing {
            smoothedCentroidNormalized = normalized
            prevSmoothedCentroidNormalized = normalized
            didSeedCentroidSmoothing = true
        } else {
            smoothedCentroidNormalized = alpha * normalized + (1 - alpha) * smoothedCentroidNormalized
        }
        currentCentroidNormalized = smoothedCentroidNormalized
        // Δ per frame is tiny; scale by ~50 so a typical half-octave sweep
        // over a beat registers as ~±1 on the output. Then soft-clip.
        let rawDir = (smoothedCentroidNormalized - prevSmoothedCentroidNormalized) * 50
        currentPitchDirection = max(-1, min(1, rawDir))

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
        guard let analysis else { return }
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
        guard let analysis else { return }
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
            currentSectionStart = s.start
            currentSectionEnd = s.end
        }
    }

    // MARK: - Onset cursor

    /// Advance the onset cursor in lock-step with the playback clock so
    /// `onsetGeneration` bumps exactly when a backend OnsetEvent's `.time`
    /// falls in (prevTime, currentTime]. Mirrors the HapticEngine cursor
    /// pattern so visual onset-bursts stay in sync with whatever haptic
    /// layer consumes the same events.
    private func updateOnsetCursor(prevTime: Double, currentTime: Double) {
        guard !sortedOnsets.isEmpty else { return }

        // Seek / discontinuity: rebind cursor via binary search.
        if currentTime < prevTime || (currentTime - prevTime) > 2.0 {
            onsetCursor = firstOnsetIndex(atOrAfter: currentTime)
            return
        }

        while onsetCursor < sortedOnsets.count && sortedOnsets[onsetCursor].time <= prevTime {
            onsetCursor += 1
        }
        while onsetCursor < sortedOnsets.count && sortedOnsets[onsetCursor].time <= currentTime {
            lastOnset = sortedOnsets[onsetCursor]
            onsetGeneration &+= 1
            onsetCursor += 1
        }
    }

    private func firstOnsetIndex(atOrAfter time: Double) -> Int {
        var lo = 0
        var hi = sortedOnsets.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedOnsets[mid].time < time {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
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
        guard let analysis else { return }
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

    // MARK: - Live ingest (microphone mode)

    /// Rolling centroid samples used to recompute p5/p95 in live mode, so
    /// per-track brightness normalization still works without whole-song
    /// context. Sized for ~30s of ~43Hz frames.
    @ObservationIgnored private var liveCentroidSamples: [Double] = []
    @ObservationIgnored private var liveCentroidResortDue: Int = 0

    /// Push one DSP frame from LiveAudioEngine. Mirrors everything
    /// `updateFrameState(at:)` sets for offline mode, so every downstream
    /// texture/archetype reads the same @Observable properties.
    func ingestLiveFrame(
        time: Double,
        energy: Double,
        bands: [Double],
        centroid: Double,
        flux: Double,
        hue: Double,
        chromaStrength: Double,
        harmonicRatio: Double,
        rolloff: Double,
        zcr: Double,
        spectralContrast: Double,
        mfcc: [Double],
        chroma: [Double]
    ) {
        guard isLive else { return }
        lastFrameTime = time

        currentEnergy = max(0, min(1, energy))
        if bands.count == currentBands.count {
            currentBands = bands
        } else {
            var padded = Array(bands.prefix(8))
            while padded.count < 8 { padded.append(0) }
            currentBands = padded
        }
        currentFlux = max(0, min(1, flux))
        currentCentroid = centroid
        currentHue = hue
        currentChromaStrength = max(0, min(1, chromaStrength))
        currentHarmonicRatio = max(0, min(1, harmonicRatio))
        currentRolloff = max(0, min(1, rolloff))
        currentZCR = max(0, min(1, zcr))
        currentSpectralContrast = max(0, min(1, spectralContrast))
        if mfcc.count == currentMFCC.count {
            currentMFCC = mfcc
        } else {
            var padded = Array(mfcc.prefix(4))
            while padded.count < 4 { padded.append(0.5) }
            currentMFCC = padded
        }
        if chroma.count == currentChromaVector.count {
            currentChromaVector = chroma
        } else {
            var padded = Array(chroma.prefix(12))
            while padded.count < 12 { padded.append(0) }
            currentChromaVector = padded
        }

        // Rolling centroid p5/p95 — recompute every 32 frames (~0.75s) so
        // we don't sort on every frame. Cap samples at ~30s of history.
        liveCentroidSamples.append(centroid)
        if liveCentroidSamples.count > 1300 {
            liveCentroidSamples.removeFirst(liveCentroidSamples.count - 1300)
        }
        liveCentroidResortDue += 1
        if liveCentroidResortDue >= 32 && liveCentroidSamples.count >= 16 {
            liveCentroidResortDue = 0
            (centroidMin, centroidMax) = Self.percentileRange(
                of: liveCentroidSamples, lower: 0.05, upper: 0.95
            )
        }

        let spanCentroid = centroidMax - centroidMin
        let normalized: Double
        if spanCentroid > 1e-6 {
            normalized = max(0, min(1, (currentCentroid - centroidMin) / spanCentroid))
        } else {
            normalized = 0.5
        }
        let alpha = 0.12
        prevSmoothedCentroidNormalized = smoothedCentroidNormalized
        if !didSeedCentroidSmoothing {
            smoothedCentroidNormalized = normalized
            prevSmoothedCentroidNormalized = normalized
            didSeedCentroidSmoothing = true
        } else {
            smoothedCentroidNormalized = alpha * normalized + (1 - alpha) * smoothedCentroidNormalized
        }
        currentCentroidNormalized = smoothedCentroidNormalized
        let rawDir = (smoothedCentroidNormalized - prevSmoothedCentroidNormalized) * 50
        currentPitchDirection = max(-1, min(1, rawDir))

        // Reuse the same flux-spike detector; frameIdx can be a monotonic
        // tick count since we don't need time-alignment to precomputed frames.
        let frameIdx = lastFrameIdx &+ 1
        detectFluxSpike(newFlux: flux, frameIdx: frameIdx, time: time)

        // Beat pulse decay tick — offline mode decays inside updateBeatPulse,
        // but live mode never calls that path, so decay here each frame.
        // Each ~23ms frame: pulse *= 0.5^(0.023/0.15) ≈ 0.9.
        beatPulse *= pow(0.5, 0.023 / 0.15)
    }

    /// Record a live onset. Bumps `onsetGeneration` and caches the event so
    /// voices observing the rising edge can read attack envelope.
    func ingestLiveOnset(_ onset: OnsetEvent) {
        guard isLive else { return }
        lastOnset = onset
        onsetGeneration &+= 1
    }

    /// Record a live beat (synthetic, from LiveBeatTracker). Drives the
    /// shared beat pulse so every visualizer layer reacts the same way it
    /// does for offline beats.
    func ingestLiveBeat(_ beat: BeatEvent) {
        guard isLive else { return }
        let target = (beat.isDownbeat ? 1.0 : 0.7) * max(0.3, beat.intensity)
        if target > beatPulse { beatPulse = target }
    }

    /// Update the emotion state from a backend chunk response (~every 2s).
    /// Feeds the same EMA smoother offline mode uses, so downstream biome
    /// weights and mood palettes cross-fade smoothly instead of stepping.
    func ingestLiveEmotion(valence: Double, arousal: Double) {
        guard isLive else { return }
        currentValence = max(0, min(1, valence))
        currentArousal = max(0, min(1, arousal))
        // Larger α here than offline (0.25 vs 0.1) because cadence is ~2s,
        // not 0.5s — we need to reach most of the step between samples.
        let alpha = 0.25
        if !didSeedEmotionSmoothing {
            smoothedValence = currentValence
            smoothedArousal = currentArousal
            didSeedEmotionSmoothing = true
        } else {
            smoothedValence = alpha * currentValence + (1 - alpha) * smoothedValence
            smoothedArousal = alpha * currentArousal + (1 - alpha) * smoothedArousal
        }
        updateBiomeWeights(now: lastFrameTime)
    }

    /// Update the energy profile label from the rolling classifier. The
    /// existing biome/dialect resolver already reads `currentSectionEnergyProfile`,
    /// so no downstream code needs to change.
    func ingestLiveEnergyProfile(_ label: String) {
        guard isLive else { return }
        currentSectionEnergyProfile = label
    }
}

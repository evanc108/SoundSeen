//
//  LiveFeatureExtractor.swift
//  SoundSeen
//
//  Per-frame DSP for live microphone input. Mirrors the shape of
//  `pipeline/spectral.py` on the backend so `VisualizerState.ingestLiveFrame`
//  receives the same feature vector the offline path supplies.
//
//  Parameters match the backend exactly (sr=22050, hop=512, n_fft=2048)
//  so magnitude ranges stay calibrated across upload ↔ live switches.
//
//  Threading: not actor-isolated. Meant to be driven from the LiveAudioEngine
//  serial DSP queue — never call from SwiftUI / main directly.
//
//  Allocation profile: one-shot in init (FFT setup, precomputed matrices).
//  `process(hop:)` allocates nothing; all buffers are member-owned.
//

import Accelerate
import Foundation

/// One analyzed frame — matches the shape `VisualizerState.ingestLiveFrame`
/// consumes. Plain struct so the audio thread can hand it to the main actor
/// without additional conversion.
struct LiveFrame: Sendable {
    var energy: Double             // RMS, abs-scaled to [0,1]
    var bands: [Double]            // 8, each in [0,1] (rolling p5/p95 norm)
    var centroid: Double           // raw Hz-like value (normalized downstream)
    var flux: Double               // [0,1]
    var rolloff: Double            // [0,1]
    var zcr: Double                // [0,1]
    var spectralContrast: Double   // [0,1]
    var hue: Double                // degrees 0..360
    var chromaStrength: Double     // [0,1]
    var chroma: [Double]           // 12, [0,1] per-frame
    var harmonicRatio: Double      // [0,1]
    var mfcc: [Double]             // 4, [0,1] via rolling min/max
    var melLog: [Double]           // 40, log-mel energies — used by onset detector
}

/// Nonisolated — project default is @MainActor, but this runs entirely on
/// LiveAudioEngine's serial DSP queue and never touches UI state directly.
nonisolated final class LiveFeatureExtractor {

    // MARK: - Constants

    static let sampleRate: Double = 22050
    static let hopLength: Int = 512
    static let frameLength: Int = 2048
    static let nFftBins: Int = 1025           // frameLength/2 + 1
    static let nMel: Int = 40
    static let nPitchClasses: Int = 12
    static let nBands: Int = 8
    static let nMfcc: Int = 4

    // 8 perceptual bands — mirror BAND_EDGES in pipeline/spectral.py:15-27.
    // Hz ranges translated to FFT bin ranges at init time.
    static let bandEdgesHz: [(String, Double, Double)] = [
        ("sub_bass", 20, 60),
        ("bass", 60, 250),
        ("low_mid", 250, 500),
        ("mid", 500, 1000),
        ("upper_mid", 1000, 2000),
        ("presence", 2000, 4000),
        ("brilliance", 4000, 8000),
        ("ultra_high", 8000, 11025),
    ]

    // MARK: - FFT resources

    private let fftSetup: vDSP.FFT<DSPSplitComplex>
    private var realBuffer: [Float]
    private var imagBuffer: [Float]
    private var window: [Float]
    private var windowed: [Float]

    // MARK: - Precomputed matrices

    /// Dense 8 × nFftBins band weights. Most rows are near-zero except in
    /// their Hz range — but at 1025 bins × 8 = 8200 floats it's cheaper to
    /// keep dense than sparse-encode.
    private let bandWeights: [[Float]]
    /// Hz-valued frequency of each FFT bin (useful for rolloff & centroid).
    private let binFrequencies: [Float]
    /// Mel filterbank 40 × nFftBins.
    private let melBasis: [[Float]]
    /// DCT-II basis 4 × 40 for MFCC.
    private let dctBasis: [[Float]]
    /// Chroma basis 12 × nFftBins — each bin's Gaussian-weighted pitch-class
    /// contribution.
    private let chromaBasis: [[Float]]

    // MARK: - Rolling state

    private var prevMagnitude: [Float]      // nFftBins — spectral flux baseline

    /// Rolling raw band-energy samples for p5/p95 normalization. Capped at
    /// ~30s of ~43fps history per band.
    private var bandHistory: [[Float]]      // 8 × history
    private let bandHistoryCap = 1300

    /// Rolling flux samples for [0,1] normalization.
    private var fluxHistory: [Float] = []
    private let fluxHistoryCap = 400

    /// Rolling rolloff normalization baseline.
    private var rolloffHistory: [Float] = []
    private let rolloffHistoryCap = 400

    /// Rolling ZCR normalization.
    private var zcrHistory: [Float] = []
    private let zcrHistoryCap = 400

    /// Rolling spectral-contrast normalization.
    private var contrastHistory: [Float] = []
    private let contrastHistoryCap = 400

    /// Per-coefficient MFCC rolling min/max.
    private var mfccHistory: [[Float]]

    /// Tick counter — useful for coarse scheduling (e.g., "update p5/p95
    /// every N frames"). Not a time measure.
    private var tickIndex: Int = 0

    // MARK: - Init

    init() {
        let log2n = vDSP_Length(log2(Double(Self.frameLength)))
        // vDSP.FFT throws on setup failure (invalid size). frameLength=2048
        // is a power of two, so the only way this fails is an OOM that would
        // doom the app anyway — force-unwrap is safer than leaving the FFT
        // as an Optional that every call site has to unwrap.
        self.fftSetup = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)!

        self.realBuffer = [Float](repeating: 0, count: Self.frameLength / 2)
        self.imagBuffer = [Float](repeating: 0, count: Self.frameLength / 2)
        self.windowed = [Float](repeating: 0, count: Self.frameLength)

        // Hann window — computed once, reused every frame.
        var win = [Float](repeating: 0, count: Self.frameLength)
        vDSP_hann_window(&win, vDSP_Length(Self.frameLength), Int32(vDSP_HANN_NORM))
        self.window = win

        // Precompute bin frequencies. Bin k → k * sr / n_fft.
        let sr = Float(Self.sampleRate)
        let nFft = Float(Self.frameLength)
        self.binFrequencies = (0..<Self.nFftBins).map { Float($0) * sr / nFft }

        // 8-band weight matrix: 1.0 on bins whose freq falls in [lo, hi),
        // 0 elsewhere. Simple but matches the backend (mean over masked bins).
        var bw = Array(repeating: [Float](repeating: 0, count: Self.nFftBins), count: Self.nBands)
        for (i, edge) in Self.bandEdgesHz.enumerated() {
            let lo = Float(edge.1), hi = Float(edge.2)
            var count: Float = 0
            for k in 0..<Self.nFftBins {
                let f = self.binFrequencies[k]
                if f >= lo && f < hi {
                    bw[i][k] = 1
                    count += 1
                }
            }
            if count > 0 {
                // Divide weights so a dot product yields the mean of masked
                // bins (matching np.mean in spectral.py:58).
                for k in 0..<Self.nFftBins { bw[i][k] /= count }
            }
        }
        self.bandWeights = bw

        // Mel filterbank (40 triangular filters, 0..sr/2). Approximates
        // librosa.filters.mel defaults.
        self.melBasis = Self.makeMelBasis(
            nMel: Self.nMel,
            nFftBins: Self.nFftBins,
            sampleRate: sr,
            fMin: 0,
            fMax: sr / 2
        )

        // DCT-II basis for 4-coef MFCC. Normalize by sqrt(2/N) * 1/√2 on k=0
        // (standard "ortho" normalization).
        self.dctBasis = Self.makeDCTBasis(nMfcc: Self.nMfcc, nMel: Self.nMel)

        // Chroma basis: for each FFT bin, distribute magnitude to the nearest
        // pitch class with a Gaussian weight on neighboring classes.
        self.chromaBasis = Self.makeChromaBasis(binFrequencies: self.binFrequencies)

        self.prevMagnitude = [Float](repeating: 0, count: Self.nFftBins)
        self.bandHistory = Array(repeating: [], count: Self.nBands)
        self.mfccHistory = Array(repeating: [], count: Self.nMfcc)
    }

    // MARK: - Public entry point

    /// Process one hop of audio (frameLength samples = prev + current hop,
    /// maintained by LiveAudioEngine). Returns the analyzed frame.
    ///
    /// - Parameter samples: exactly `frameLength` float32 samples @ 22050Hz.
    func process(frame samples: UnsafePointer<Float>) -> LiveFrame {
        precondition(Self.frameLength == windowed.count)
        tickIndex &+= 1

        // 1. Window: windowed = samples * hann
        vDSP.multiply(
            UnsafeBufferPointer(start: samples, count: Self.frameLength),
            window,
            result: &windowed
        )

        // 2. ZCR on the *raw* samples (windowed would attenuate edges).
        let zcrRaw = Self.zeroCrossingRate(
            samples: samples, count: Self.frameLength
        )

        // 3. FFT. vDSP's real-to-complex packs DC in real[0] and Nyquist in
        //    imag[0]; we compute magnitudes for bins 0..n/2 inclusive (1025)
        //    by unpacking this into a standard magnitude array.
        var magnitude = [Float](repeating: 0, count: Self.nFftBins)
        realBuffer.withUnsafeMutableBufferPointer { realPtr in
        imagBuffer.withUnsafeMutableBufferPointer { imagPtr in
            var split = DSPSplitComplex(
                realp: realPtr.baseAddress!,
                imagp: imagPtr.baseAddress!
            )
            windowed.withUnsafeBufferPointer { wp in
                wp.baseAddress!.withMemoryRebound(
                    to: DSPComplex.self, capacity: Self.frameLength / 2
                ) { interleaved in
                    vDSP_ctoz(interleaved, 2, &split, 1, vDSP_Length(Self.frameLength / 2))
                }
            }
            fftSetup.forward(input: split, output: &split)

            // Unpack: bin 0 → realp[0], bin N/2 → imagp[0], bins 1..N/2-1 →
            // (realp[k], imagp[k]). We compute sqrt(r^2+i^2)/N for all bins.
            let scale = Float(1) / Float(Self.frameLength)
            magnitude[0] = abs(realPtr[0]) * scale
            magnitude[Self.frameLength / 2] = abs(imagPtr[0]) * scale
            for k in 1..<(Self.frameLength / 2) {
                let r = realPtr[k], i = imagPtr[k]
                magnitude[k] = sqrt(r * r + i * i) * scale
            }
        }
        }

        // 4. RMS (time-domain over the unwindowed samples).
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(Self.frameLength))
        // Absolute-scale RMS into [0,1] with a perceptual curve — sqrt
        // stretches the quiet end so room tone still reads as "some" energy.
        let energyAbs = Double(min(1, sqrt(max(0, rms)) * 4))

        // 5. Bands: dot magnitude with each band's weight vector.
        var bandsRaw = [Float](repeating: 0, count: Self.nBands)
        for b in 0..<Self.nBands {
            var v: Float = 0
            vDSP_dotpr(
                magnitude, 1,
                bandWeights[b], 1,
                &v,
                vDSP_Length(Self.nFftBins)
            )
            bandsRaw[b] = v
        }
        // Update rolling history, compute p5/p95 per-band, normalize.
        var bandsNorm = [Double](repeating: 0, count: Self.nBands)
        for b in 0..<Self.nBands {
            bandHistory[b].append(bandsRaw[b])
            if bandHistory[b].count > bandHistoryCap {
                bandHistory[b].removeFirst(bandHistory[b].count - bandHistoryCap)
            }
            let (lo, hi) = Self.percentile(bandHistory[b], lower: 0.05, upper: 0.95)
            let span = max(hi - lo, 1e-6)
            bandsNorm[b] = Double(max(0, min(1, (bandsRaw[b] - lo) / span)))
        }

        // 6. Spectral centroid = Σ(f_k * mag_k) / Σ(mag_k)
        var num: Float = 0
        var den: Float = 0
        vDSP_dotpr(binFrequencies, 1, magnitude, 1, &num, vDSP_Length(Self.nFftBins))
        vDSP_sve(magnitude, 1, &den, vDSP_Length(Self.nFftBins))
        let centroid = den > 1e-10 ? Double(num / den) : 0

        // 7. Rolloff (85%): smallest bin k s.t. cumulative magnitude ≥ 0.85*total.
        let target = den * 0.85
        var cum: Float = 0
        var rolloffBin = Self.nFftBins - 1
        for k in 0..<Self.nFftBins {
            cum += magnitude[k]
            if cum >= target { rolloffBin = k; break }
        }
        let rolloffHz = Float(rolloffBin) * Float(Self.sampleRate) / Float(Self.frameLength)
        rolloffHistory.append(rolloffHz)
        if rolloffHistory.count > rolloffHistoryCap {
            rolloffHistory.removeFirst(rolloffHistory.count - rolloffHistoryCap)
        }
        let (rloLo, rloHi) = Self.percentile(rolloffHistory, lower: 0.05, upper: 0.95)
        let rolloffN = Double(max(0, min(1, (rolloffHz - rloLo) / max(rloHi - rloLo, 1e-6))))

        // 8. Spectral flux: sqrt(Σ(mag_k - prev_k)^2), rectified.
        var fluxRaw: Float = 0
        for k in 0..<Self.nFftBins {
            let d = magnitude[k] - prevMagnitude[k]
            if d > 0 { fluxRaw += d * d }
        }
        fluxRaw = sqrt(fluxRaw)
        fluxHistory.append(fluxRaw)
        if fluxHistory.count > fluxHistoryCap {
            fluxHistory.removeFirst(fluxHistory.count - fluxHistoryCap)
        }
        let (fLo, fHi) = Self.percentile(fluxHistory, lower: 0.05, upper: 0.95)
        let fluxN = Double(max(0, min(1, (fluxRaw - fLo) / max(fHi - fLo, 1e-6))))

        // 9. ZCR normalization.
        zcrHistory.append(zcrRaw)
        if zcrHistory.count > zcrHistoryCap {
            zcrHistory.removeFirst(zcrHistory.count - zcrHistoryCap)
        }
        let (zLo, zHi) = Self.percentile(zcrHistory, lower: 0.05, upper: 0.95)
        let zcrN = Double(max(0, min(1, (zcrRaw - zLo) / max(zHi - zLo, 1e-6))))

        // 10. Mel energies + log for MFCC, onset detector.
        var melEnergies = [Float](repeating: 0, count: Self.nMel)
        for m in 0..<Self.nMel {
            var v: Float = 0
            vDSP_dotpr(
                magnitude, 1,
                melBasis[m], 1,
                &v,
                vDSP_Length(Self.nFftBins)
            )
            melEnergies[m] = v
        }
        // log(max(eps, mel)) — avoid log(0).
        var melLogF = [Float](repeating: 0, count: Self.nMel)
        for m in 0..<Self.nMel {
            melLogF[m] = log(max(melEnergies[m], 1e-10))
        }

        // 11. MFCC[0..3] via DCT on log-mel.
        var mfccRaw = [Float](repeating: 0, count: Self.nMfcc)
        for c in 0..<Self.nMfcc {
            var v: Float = 0
            vDSP_dotpr(melLogF, 1, dctBasis[c], 1, &v, vDSP_Length(Self.nMel))
            mfccRaw[c] = v
        }
        var mfccNorm = [Double](repeating: 0.5, count: Self.nMfcc)
        for c in 0..<Self.nMfcc {
            mfccHistory[c].append(mfccRaw[c])
            if mfccHistory[c].count > 1000 {
                mfccHistory[c].removeFirst(mfccHistory[c].count - 1000)
            }
            let (lo, hi) = Self.percentile(mfccHistory[c], lower: 0.05, upper: 0.95)
            mfccNorm[c] = Double(max(0, min(1, (mfccRaw[c] - lo) / max(hi - lo, 1e-6))))
        }

        // 12. Chroma (12 bins) + hue + chromaStrength.
        var chromaRaw = [Float](repeating: 0, count: Self.nPitchClasses)
        for p in 0..<Self.nPitchClasses {
            var v: Float = 0
            vDSP_dotpr(
                magnitude, 1,
                chromaBasis[p], 1,
                &v,
                vDSP_Length(Self.nFftBins)
            )
            chromaRaw[p] = v
        }
        // Normalize so the max chroma = 1 per frame (like librosa chroma_stft).
        var chromaMax: Float = 0
        vDSP_maxv(chromaRaw, 1, &chromaMax, vDSP_Length(Self.nPitchClasses))
        var chromaOut = [Double](repeating: 0, count: Self.nPitchClasses)
        if chromaMax > 1e-10 {
            for p in 0..<Self.nPitchClasses {
                chromaOut[p] = Double(chromaRaw[p] / chromaMax)
            }
        }
        var dominantPC: Int = 0
        var dominantValue: Float = 0
        for p in 0..<Self.nPitchClasses where chromaRaw[p] > dominantValue {
            dominantValue = chromaRaw[p]
            dominantPC = p
        }
        let hue = Double(dominantPC) * 30.0
        // Chroma "strength" = max value relative to the sum — how peaked the
        // distribution is. 1 = single pitch class dominates; ~0.08 = flat.
        var chromaSum: Float = 0
        vDSP_sve(chromaRaw, 1, &chromaSum, vDSP_Length(Self.nPitchClasses))
        let chromaStrength = chromaSum > 1e-10
            ? Double(min(1, (chromaMax / chromaSum) * Float(Self.nPitchClasses) / 6))
            : 0

        // 13. Spectral contrast (crude): mean of max-min in 6 log-spaced
        // sub-bands, normalized to [0,1].
        let contrastRaw = Self.spectralContrast(magnitude: magnitude)
        contrastHistory.append(contrastRaw)
        if contrastHistory.count > contrastHistoryCap {
            contrastHistory.removeFirst(contrastHistory.count - contrastHistoryCap)
        }
        let (cLo, cHi) = Self.percentile(contrastHistory, lower: 0.05, upper: 0.95)
        let contrastN = Double(max(0, min(1, (contrastRaw - cLo) / max(cHi - cLo, 1e-6))))

        // 14. Harmonic ratio approximation via inverted spectral flatness.
        //     Flat spectrum → noisy → low harmonic ratio; peaky → harmonic.
        let flatness = Self.spectralFlatness(magnitude: magnitude)
        let harmonicRatio = Double(max(0, min(1, 1 - flatness)))

        // Persist prevMagnitude for next frame's flux.
        prevMagnitude = magnitude

        return LiveFrame(
            energy: energyAbs,
            bands: bandsNorm,
            centroid: centroid,
            flux: fluxN,
            rolloff: rolloffN,
            zcr: zcrN,
            spectralContrast: contrastN,
            hue: hue,
            chromaStrength: chromaStrength,
            chroma: chromaOut,
            harmonicRatio: harmonicRatio,
            mfcc: mfccNorm,
            melLog: melLogF.map(Double.init)
        )
    }

    // MARK: - Helpers

    /// Raw ZCR = fraction of adjacent sample pairs that change sign.
    private static func zeroCrossingRate(samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 1 else { return 0 }
        var crossings: Int = 0
        var prev = samples[0]
        for i in 1..<count {
            let cur = samples[i]
            if (prev < 0 && cur >= 0) || (prev >= 0 && cur < 0) { crossings += 1 }
            prev = cur
        }
        return Float(crossings) / Float(count - 1)
    }

    /// Returns (p_lo, p_hi) of `values`. Returns (0, 1) if empty.
    private static func percentile(_ values: [Float], lower: Double, upper: Double) -> (Float, Float) {
        guard values.count >= 8 else { return (0, 1) }
        // sort is O(n log n) but n is capped at ~1300; acceptable at 43fps
        // when most bands only resort their own history slice.
        let sorted = values.sorted()
        let loIdx = min(sorted.count - 1, max(0, Int(Double(sorted.count) * lower)))
        let hiIdx = min(sorted.count - 1, max(0, Int(Double(sorted.count) * upper)))
        let lo = sorted[loIdx]
        let hi = sorted[hiIdx]
        if hi - lo < 1e-10 { return (lo, lo + 1) }
        return (lo, hi)
    }

    private static func spectralContrast(magnitude: [Float]) -> Float {
        // 6 log-spaced sub-bands across the spectrum. For each, mean of top
        // 20% minus mean of bottom 20% → "peakiness" → averaged → contrast.
        let edges: [Int] = [2, 8, 24, 64, 160, 400, 1024]
        var acc: Float = 0
        var count: Int = 0
        for b in 0..<(edges.count - 1) {
            let lo = edges[b], hi = min(edges[b + 1], magnitude.count)
            guard hi > lo + 2 else { continue }
            let slice = Array(magnitude[lo..<hi]).sorted()
            let n = slice.count
            let top = Array(slice[(n * 4 / 5)..<n])
            let bot = Array(slice[0..<(n / 5)])
            if top.isEmpty || bot.isEmpty { continue }
            let topMean = top.reduce(0, +) / Float(top.count)
            let botMean = bot.reduce(0, +) / Float(bot.count)
            acc += log(max(topMean, 1e-10) / max(botMean, 1e-10))
            count += 1
        }
        return count > 0 ? acc / Float(count) : 0
    }

    /// Geometric mean / arithmetic mean of magnitude; 1 = totally flat
    /// (noise), 0 = purely tonal.
    private static func spectralFlatness(magnitude: [Float]) -> Float {
        // Log-sum trick for numerical stability.
        var logSum: Float = 0
        var arithSum: Float = 0
        var n: Int = 0
        // Skip DC; it biases the flatness ratio when there's any bias offset.
        for k in 1..<magnitude.count {
            let m = magnitude[k] + 1e-10
            logSum += log(m)
            arithSum += m
            n += 1
        }
        guard n > 0 && arithSum > 1e-10 else { return 0 }
        let geoMean = exp(logSum / Float(n))
        let arithMean = arithSum / Float(n)
        return geoMean / arithMean
    }

    // MARK: - Matrix construction

    /// Triangular mel filterbank (approximation of librosa.filters.mel
    /// defaults). 40 filters, slaney-style, 0..sr/2. Each row sums to 1.
    private static func makeMelBasis(
        nMel: Int,
        nFftBins: Int,
        sampleRate: Float,
        fMin: Float,
        fMax: Float
    ) -> [[Float]] {
        func hzToMel(_ f: Float) -> Float {
            // Slaney: linear below 1000Hz, log above.
            if f < 1000 { return 3 * f / 200 }
            return 15 + 27 * log(f / 1000) / log(6.4)
        }
        func melToHz(_ m: Float) -> Float {
            if m < 15 { return m * 200 / 3 }
            return 1000 * pow(6.4, (m - 15) / 27)
        }
        let mMin = hzToMel(fMin)
        let mMax = hzToMel(fMax)
        // nMel + 2 mel-spaced points define nMel triangular filters.
        let melPoints = (0...(nMel + 1)).map { i -> Float in
            mMin + (mMax - mMin) * Float(i) / Float(nMel + 1)
        }
        let hzPoints = melPoints.map(melToHz)
        // Precompute bin frequencies once more for convenience.
        let binHz: [Float] = (0..<nFftBins).map { Float($0) * sampleRate / (Float(nFftBins - 1) * 2) }

        var basis = Array(repeating: [Float](repeating: 0, count: nFftBins), count: nMel)
        for m in 0..<nMel {
            let lo = hzPoints[m]
            let mid = hzPoints[m + 1]
            let hi = hzPoints[m + 2]
            var rowSum: Float = 0
            for k in 0..<nFftBins {
                let f = binHz[k]
                var w: Float = 0
                if f >= lo && f <= mid { w = (f - lo) / max(mid - lo, 1e-6) }
                else if f > mid && f <= hi { w = (hi - f) / max(hi - mid, 1e-6) }
                if w > 0 { basis[m][k] = w; rowSum += w }
            }
            if rowSum > 0 {
                for k in 0..<nFftBins { basis[m][k] /= rowSum }
            }
        }
        return basis
    }

    /// DCT-II ortho-normalized basis for the first `nMfcc` coefficients.
    private static func makeDCTBasis(nMfcc: Int, nMel: Int) -> [[Float]] {
        let nF = Float(nMel)
        var basis = Array(repeating: [Float](repeating: 0, count: nMel), count: nMfcc)
        for c in 0..<nMfcc {
            let norm: Float = (c == 0) ? sqrt(1.0 / nF) : sqrt(2.0 / nF)
            for k in 0..<nMel {
                let arg = Float.pi * Float(c) * (Float(k) + 0.5) / nF
                basis[c][k] = norm * cos(arg)
            }
        }
        return basis
    }

    /// Chroma basis with a Gaussian weight that spreads each FFT bin over
    /// its nearest pitch class (half-tone resolution). Bins under 40Hz are
    /// ignored to avoid garbage below the lowest fundamental.
    private static func makeChromaBasis(binFrequencies: [Float]) -> [[Float]] {
        // Gaussian sigma in semitones — wider = more smoothing, softer peaks.
        let sigma: Float = 0.8
        // Reference pitch for class 0 (C) — use 261.63Hz (C4) as anchor.
        // Pitch class of frequency f: 12 * log2(f / 261.63) mod 12.
        let refC: Float = 261.6255653006  // C4

        var basis = Array(repeating: [Float](repeating: 0, count: binFrequencies.count), count: 12)
        for k in 0..<binFrequencies.count {
            let f = binFrequencies[k]
            guard f >= 40 else { continue }
            let semitones = 12 * log(f / refC) / log(2)
            // Distance in semitones to each pitch class, using the nearest
            // octave wrap so a bin at 11.4 semitones is distance 0.6 from
            // class 0, not -11.4.
            for pc in 0..<12 {
                var d = semitones - Float(pc)
                // Wrap into (-6, 6]
                d = d.truncatingRemainder(dividingBy: 12)
                if d > 6 { d -= 12 }
                if d <= -6 { d += 12 }
                let w = exp(-(d * d) / (2 * sigma * sigma))
                basis[pc][k] = w
            }
        }
        // Normalize each column (bin) so a single pure tone sums to 1 across
        // pitch classes.
        for k in 0..<binFrequencies.count {
            var col: Float = 0
            for pc in 0..<12 { col += basis[pc][k] }
            if col > 1e-10 {
                for pc in 0..<12 { basis[pc][k] /= col }
            }
        }
        return basis
    }
}

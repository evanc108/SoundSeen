//
//  LiveAudioEngine.swift
//  SoundSeen
//
//  The live-mic orchestrator. Owns AVAudioEngine + input tap, downsamples
//  to 22050Hz mono, runs the DSP stack (LiveFeatureExtractor →
//  LiveOnsetDetector + LiveBeatTracker → LiveEnergyProfiler), and pushes
//  results into VisualizerState + HapticVocabulary on the main actor.
//
//  Also keeps a rolling 2s PCM buffer which it uploads to
//  /analyze_chunk every ~2s for emotion (V/A) updates. Network failures
//  are swallowed — the visualizer never stalls waiting on the backend.
//
//  Threading:
//    - AVAudioEngine installs its tap on an AU-owned thread.
//    - We immediately hand samples off to `dspQueue` (serial) to avoid
//      doing any work inside the audio-thread callback.
//    - UI-facing state updates hop back to `@MainActor`.
//

import AVFoundation
import Foundation
import Observation

@Observable
@MainActor
final class LiveAudioEngine {

    // MARK: - Observable state

    enum PermissionState: Equatable {
        case unknown
        case denied
        case granted
    }

    enum EngineState: Equatable {
        case idle
        case starting
        case running
        case stopping
        case failed(String)
    }

    private(set) var permissionState: PermissionState = .unknown
    private(set) var engineState: EngineState = .idle
    private(set) var lockedBPM: Double?
    private(set) var currentEnergyProfile: LiveEnergyProfiler.Profile = .moderate

    // MARK: - Collaborators

    @ObservationIgnored private let apiClient: APIClient
    @ObservationIgnored private let clientId: String = UUID().uuidString
    /// Set via start(visualizer:haptics:). Weak to avoid retaining the view.
    @ObservationIgnored private weak var visualizer: VisualizerState?
    @ObservationIgnored private weak var haptics: HapticVocabulary?

    // MARK: - Audio graph

    @ObservationIgnored nonisolated(unsafe) private var engine: AVAudioEngine?
    @ObservationIgnored nonisolated(unsafe) private var converter: AVAudioConverter?
    @ObservationIgnored nonisolated private let targetFormat: AVAudioFormat = {
        // 22050 Hz mono float32 non-interleaved — matches backend.
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: LiveFeatureExtractor.sampleRate,
            channels: 1,
            interleaved: false
        )!
    }()

    /// Reset all DSP state — called from stop(). Dispatches synchronously
    /// to dspQueue to avoid racing with an in-flight hop.
    nonisolated private func resetDSPState() {
        dspQueue.sync {
            self.fftInput = [Float](
                repeating: 0,
                count: LiveFeatureExtractor.frameLength
            )
            self.pendingSamples.removeAll(keepingCapacity: true)
            self.chunkRing.removeAll(keepingCapacity: true)
            self.lastChunkUploadAt = 0
            self.chunkInFlight = false
            self.onsetDetector.reset()
            self.beatTracker.reset()
            self.energyProfiler.reset()
            self.prevMelForStrength.removeAll(keepingCapacity: true)
        }
    }

    // MARK: - DSP
    // These run on dspQueue (serial). Marked nonisolated(unsafe) because the
    // project default is @MainActor but the queue guarantees serial access.

    @ObservationIgnored private let dspQueue = DispatchQueue(
        label: "com.soundseen.live.dsp",
        qos: .userInteractive
    )
    @ObservationIgnored nonisolated(unsafe) private let extractor = LiveFeatureExtractor()
    @ObservationIgnored nonisolated(unsafe) private let onsetDetector = LiveOnsetDetector()
    @ObservationIgnored nonisolated(unsafe) private let beatTracker = LiveBeatTracker()
    @ObservationIgnored nonisolated(unsafe) private let energyProfiler = LiveEnergyProfiler()

    /// Rolling FFT input window (2048 samples). We slide by `hopLength`
    /// each frame, keeping the prior `frameLength - hopLength` samples.
    @ObservationIgnored nonisolated(unsafe) private var fftInput: [Float]
    /// Simple sample accumulator for when the downsampled buffer delivers
    /// chunks smaller than hopLength (common — iOS often hands us 256 or
    /// 470 samples at a time after conversion).
    @ObservationIgnored nonisolated(unsafe) private var pendingSamples: [Float] = []

    /// 2-second rolling PCM buffer for /analyze_chunk uploads. Plain array
    /// used as a growing FIFO; resets to capacity every N samples.
    @ObservationIgnored nonisolated(unsafe) private var chunkRing: [Float] = []
    /// Target rolling size (2s @ 22050).
    @ObservationIgnored private let chunkRingSize: Int = 44_100
    @ObservationIgnored nonisolated(unsafe) private var lastChunkUploadAt: TimeInterval = 0
    @ObservationIgnored nonisolated(unsafe) private var chunkInFlight: Bool = false

    /// Previous mel-log for the beat-tracker strength estimate.
    @ObservationIgnored nonisolated(unsafe) private var prevMelForStrength: [Double] = []

    /// Monotonic clock in seconds since `start()`. Used to tag frames and
    /// onsets so the tracker's phase predictions line up.
    @ObservationIgnored nonisolated(unsafe) private var startedHostTime: TimeInterval = 0

    // MARK: - Init

    init(apiClient: APIClient = .shared) {
        self.apiClient = apiClient
        self.fftInput = [Float](
            repeating: 0,
            count: LiveFeatureExtractor.frameLength
        )
    }

    // MARK: - Permission

    func requestPermission() async -> PermissionState {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let granted: Bool
        if #available(iOS 17, *) {
            granted = await AVAudioApplication.requestRecordPermission()
        } else {
            granted = await withCheckedContinuation { cont in
                session.requestRecordPermission { cont.resume(returning: $0) }
            }
        }
        let state: PermissionState = granted ? .granted : .denied
        self.permissionState = state
        return state
        #else
        self.permissionState = .granted
        return .granted
        #endif
    }

    func refreshPermissionState() {
        #if os(iOS)
        if #available(iOS 17, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: permissionState = .granted
            case .denied: permissionState = .denied
            case .undetermined: permissionState = .unknown
            @unknown default: permissionState = .unknown
            }
        } else {
            let session = AVAudioSession.sharedInstance()
            switch session.recordPermission {
            case .granted: permissionState = .granted
            case .denied: permissionState = .denied
            case .undetermined: permissionState = .unknown
            @unknown default: permissionState = .unknown
            }
        }
        #else
        permissionState = .granted
        #endif
    }

    // MARK: - Lifecycle

    func start(visualizer: VisualizerState, haptics: HapticVocabulary?) async {
        guard engineState == .idle || {
            if case .failed = engineState { return true } else { return false }
        }() else { return }

        self.visualizer = visualizer
        self.haptics = haptics
        self.engineState = .starting

        if permissionState != .granted {
            let s = await requestPermission()
            if s != .granted {
                engineState = .failed("microphone permission denied")
                return
            }
        }

        do {
            try await AudioSessionCoordinator.shared.configureForLive()
        } catch {
            engineState = .failed("audio session: \(error.localizedDescription)")
            return
        }

        #if os(iOS)
        do {
            try bootstrapEngine()
            haptics?.startStreaming()
            startedHostTime = ProcessInfo.processInfo.systemUptime
            engineState = .running
        } catch {
            engineState = .failed("engine: \(error.localizedDescription)")
        }
        #else
        engineState = .failed("live mic not supported on this platform")
        #endif
    }

    func stop() async {
        guard engineState == .running || engineState == .starting else { return }
        engineState = .stopping

        #if os(iOS)
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        #endif

        haptics?.stopStreaming()
        await AudioSessionCoordinator.shared.configureForPlayback()

        resetDSPState()

        engineState = .idle
    }

    // MARK: - Engine bootstrap

    #if os(iOS)
    private func bootstrapEngine() throws {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let hardwareFormat = input.inputFormat(forBus: 0)

        // Create a converter from hardware → 22050 mono float32.
        guard let conv = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw NSError(
                domain: "LiveAudioEngine",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "no converter for \(hardwareFormat)"]
            )
        }
        self.converter = conv

        // Tap buffer size — 1024 at hardware rate is a reasonable compromise
        // between latency and the CoreHaptics-stall risk the plan flagged.
        input.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: hardwareFormat
        ) { [weak self] buffer, _ in
            self?.handleInputBuffer(buffer)
        }
        try engine.start()
    }

    nonisolated private func handleInputBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        // Estimate output capacity. 48k → 22.05k ratio ≈ 0.46; round up.
        let outCap = AVAudioFrameCount(
            Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate
        ) + 32
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else {
            return
        }
        var consumed = false
        var err: NSError?
        converter.convert(to: outBuf, error: &err) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if err != nil { return }

        let frames = Int(outBuf.frameLength)
        guard frames > 0, let ch = outBuf.floatChannelData?.pointee else { return }
        let samples = Array(UnsafeBufferPointer(start: ch, count: frames))

        dspQueue.async { [weak self] in
            self?.feedSamples(samples)
        }
    }
    #endif

    // MARK: - DSP

    nonisolated private func feedSamples(_ samples: [Float]) {
        // Accumulate into `pendingSamples`, slice out hop-sized chunks, and
        // process each. The backlog pattern keeps us robust against any
        // non-aligned buffer sizes from the converter.
        pendingSamples.append(contentsOf: samples)

        // Also push into the 2s chunk ring for emotion uploads.
        chunkRing.append(contentsOf: samples)
        if chunkRing.count > chunkRingSize {
            chunkRing.removeFirst(chunkRing.count - chunkRingSize)
        }

        let hop = LiveFeatureExtractor.hopLength
        let frameLen = LiveFeatureExtractor.frameLength

        while pendingSamples.count >= hop {
            // Slide the FFT window: shift left by `hop`, append new hop.
            // fftInput is length frameLen; we need frameLen - hop carried over.
            let keep = frameLen - hop
            for i in 0..<keep {
                fftInput[i] = fftInput[i + hop]
            }
            for i in 0..<hop {
                fftInput[keep + i] = pendingSamples[i]
            }
            pendingSamples.removeFirst(hop)

            processOneHop()
        }

        // Consider uploading an emotion chunk.
        let now = ProcessInfo.processInfo.systemUptime
        if !chunkInFlight
            && chunkRing.count >= chunkRingSize
            && (now - lastChunkUploadAt) >= 2.0
        {
            chunkInFlight = true
            lastChunkUploadAt = now
            let snapshot = chunkRing  // copy
            uploadChunk(snapshot: snapshot)
        }
    }

    nonisolated private func processOneHop() {
        let time = ProcessInfo.processInfo.systemUptime - startedHostTime

        let frame = fftInput.withUnsafeBufferPointer { bp in
            extractor.process(frame: bp.baseAddress!)
        }

        // Onset detector uses the mel-log slice we computed inside the
        // extractor — shared work rather than re-running a mel filter here.
        let onset = onsetDetector.process(melLog: frame.melLog, time: time)

        // Beat tracker needs the onset-strength value every frame.
        // Approximate with mean positive-delta of melLog (same math the
        // detector uses, exposed via strengthForBeatTracker).
        let strength = onsetStrengthEstimate(currentMel: frame.melLog)
        let beat = beatTracker.process(
            strength: strength,
            currentTime: time,
            realOnsetTime: onset?.time
        )

        // Energy profile classifier.
        let profile = energyProfiler.process(
            energy: frame.energy,
            flux: frame.flux,
            now: time
        )

        // Hand everything to the main actor for @Observable updates.
        let lockedBpmSnapshot = beatTracker.lockedBPM
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.visualizer?.ingestLiveFrame(
                time: time,
                energy: frame.energy,
                bands: frame.bands,
                centroid: frame.centroid,
                flux: frame.flux,
                hue: frame.hue,
                chromaStrength: frame.chromaStrength,
                harmonicRatio: frame.harmonicRatio,
                rolloff: frame.rolloff,
                zcr: frame.zcr,
                spectralContrast: frame.spectralContrast,
                mfcc: frame.mfcc,
                chroma: frame.chroma
            )
            if let onset {
                self.visualizer?.ingestLiveOnset(onset)
                self.haptics?.fireLiveOnset(onset)
            }
            if let beat {
                self.visualizer?.ingestLiveBeat(beat)
                self.haptics?.fireLiveBeat(beat)
            }
            if self.currentEnergyProfile != profile {
                self.currentEnergyProfile = profile
                self.visualizer?.ingestLiveEnergyProfile(profile.backendLabel)
            }
            self.lockedBPM = lockedBpmSnapshot
        }
    }

    /// Rough onset-strength estimate for the beat tracker. We don't retain
    /// the previous mel-log here (the detector does), so this re-derives
    /// from the current frame's values — good enough as a pulse signal
    /// since the tracker cares about periodicity, not absolute amplitude.
    nonisolated private func onsetStrengthEstimate(currentMel: [Double]) -> Float {
        defer { prevMelForStrength = currentMel }
        guard !prevMelForStrength.isEmpty,
              prevMelForStrength.count == currentMel.count else {
            return 0
        }
        var s: Double = 0
        for i in 0..<currentMel.count {
            let d = currentMel[i] - prevMelForStrength[i]
            if d > 0 { s += d }
        }
        return Float(s)
    }

    // MARK: - Chunk uploads

    nonisolated private func uploadChunk(snapshot: [Float]) {
        let wav = Self.encodeWav(
            samples: snapshot,
            sampleRate: Int(LiveFeatureExtractor.sampleRate)
        )
        let clientId = self.clientId
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.chunkInFlight = false }
            do {
                let (v, a) = try await self.apiClient.analyzeChunk(
                    wav: wav,
                    clientId: clientId
                )
                self.visualizer?.ingestLiveEmotion(valence: v, arousal: a)
            } catch {
                // Silent — emotion stays stale. Log for debugging only.
                #if DEBUG
                print("LiveAudioEngine: chunk upload failed: \(error)")
                #endif
            }
        }
    }

    // MARK: - WAV encoding

    /// Minimal 16-bit PCM WAV encoder. float32 samples → Int16, clipped.
    static func encodeWav(samples: [Float], sampleRate: Int) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * bitsPerSample / 8
        let dataSize = UInt32(samples.count) * UInt32(blockAlign)
        let chunkSize = 36 + dataSize

        var data = Data(capacity: Int(chunkSize) + 8)
        func writeU32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func writeU16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        writeU32(chunkSize)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        writeU32(16)                       // fmt chunk size
        writeU16(1)                        // PCM format
        writeU16(numChannels)
        writeU32(UInt32(sampleRate))
        writeU32(byteRate)
        writeU16(blockAlign)
        writeU16(bitsPerSample)
        data.append(contentsOf: "data".utf8)
        writeU32(dataSize)

        for f in samples {
            let clipped = max(-1, min(1, f))
            let v = Int16(clipped * 32767)
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }
}

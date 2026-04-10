//
//  AudioReactivePlayer.swift
//  SoundSeen
//

import Accelerate
import AVFoundation
import Combine
import Foundation

/// Plays tracks from URLs (bundled or imported) and publishes spectrum / beat data for visuals.
final class AudioReactivePlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var trackTitle = ""
    @Published private(set) var artistName = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var barLevels: [CGFloat]
    @Published private(set) var beatPulse: CGFloat = 0
    @Published private(set) var bassEnergy: CGFloat = 0
    @Published private(set) var loadError: String?
    /// Set when loading from a library row; used to avoid auto-loading another track when switching tabs.
    @Published private(set) var activeTrackId: UUID?

    private let barCount: Int
    private let analysisSamples = 1024

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    private var audioFile: AVAudioFile?
    private var durationSeconds: Double = 1
    private var sampleRate: Float = 44100

    private var targetFrequencies: [Float] = []

    private var smoothedLevels: [Float]
    private var smoothedBass: Float = 0
    private var beatDecay: Float = 0

    private var progressTimer: Timer?
    private var tapInstalled = false
    private var sessionConfigured = false

    private let processingQueue = DispatchQueue(label: "soundseen.audio.analysis", qos: .userInteractive)

    init(barCount: Int = 44) {
        self.barCount = barCount
        self.barLevels = Array(repeating: 0.12, count: barCount)
        self.smoothedLevels = Array(repeating: 0.12, count: barCount)
    }

    deinit {
        progressTimer?.invalidate()
        if tapInstalled {
            engine.mainMixerNode.removeTap(onBus: 0)
        }
        playerNode.stop()
        engine.stop()
    }

    /// Load and play a library track (bundled or imported).
    func load(track: LibraryTrack) {
        guard let url = track.playbackURL else {
            loadError = "Missing file for this track."
            return
        }
        load(url: url, title: track.title, artist: track.artist, trackId: track.id)
    }

    func load(url: URL, title: String, artist: String, trackId: UUID? = nil) {
        loadError = nil
        trackTitle = title
        artistName = artist

        do {
            try configureSessionIfNeeded()
            try rebuildEngineAndPlay(url: url)
            activeTrackId = trackId
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func configureSessionIfNeeded() throws {
        guard !sessionConfigured else { return }
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try AVAudioSession.sharedInstance().setActive(true)
        sessionConfigured = true
    }

    private func rebuildEngineAndPlay(url: URL) throws {
        progressTimer?.invalidate()

        if tapInstalled {
            engine.mainMixerNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        playerNode.stop()
        if engine.isRunning {
            engine.stop()
        }
        engine.reset()

        let file = try AVAudioFile(forReading: url)
        audioFile = file
        sampleRate = Float(file.processingFormat.sampleRate)
        durationSeconds = Double(file.length) / file.processingFormat.sampleRate

        targetFrequencies = Self.logSpacedFrequencies(
            count: barCount,
            lowHz: 40,
            highHz: min(16_000, sampleRate / 2 - 500)
        )

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: file.processingFormat)

        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.processingQueue.async {
                self?.process(buffer: buffer)
            }
        }
        tapInstalled = true

        try engine.start()
        scheduleFileAndPlay(file: file)
    }

    func togglePlayPause() {
        guard audioFile != nil, loadError == nil else { return }

        if progress >= 0.995, !isPlaying {
            if let file = audioFile {
                scheduleFileAndPlay(file: file)
            }
            return
        }

        if isPlaying {
            playerNode.pause()
            isPlaying = false
        } else {
            playerNode.play()
            isPlaying = true
        }
    }

    func restartFromBeginning() {
        guard let file = audioFile, loadError == nil else { return }
        progress = 0
        scheduleFileAndPlay(file: file)
    }

    private func scheduleFileAndPlay(file: AVAudioFile) {
        playerNode.stop()
        playerNode.scheduleFile(file, at: nil) { [weak self] in
            DispatchQueue.main.async {
                self?.isPlaying = false
                self?.progress = 1
            }
        }
        playerNode.play()
        isPlaying = true
        startProgressTimerIfNeeded()
    }

    private func startProgressTimerIfNeeded() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard let nodeTime = self.playerNode.lastRenderTime,
                  let playerTime = self.playerNode.playerTime(forNodeTime: nodeTime)
            else { return }
            let elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate
            DispatchQueue.main.async {
                self.progress = min(1, max(0, elapsed / max(0.001, self.durationSeconds)))
            }
        }
        RunLoop.main.add(progressTimer!, forMode: .common)
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount >= analysisSamples else { return }

        let chCount = Int(buffer.format.channelCount)
        let start = frameCount - analysisSamples

        var mono = [Float](repeating: 0, count: analysisSamples)
        if chCount >= 2 {
            let ch0 = channelData[0]
            let ch1 = channelData[1]
            for i in 0..<analysisSamples {
                mono[i] = (ch0[start + i] + ch1[start + i]) * 0.5
            }
        } else {
            let ch0 = channelData[0]
            for i in 0..<analysisSamples {
                mono[i] = ch0[start + i]
            }
        }

        var window = [Float](repeating: 0, count: analysisSamples)
        vDSP_hann_window(&window, vDSP_Length(analysisSamples), Int32(vDSP_HANN_NORM))

        var windowed = mono
        vDSP_vmul(windowed, 1, window, 1, &windowed, 1, vDSP_Length(analysisSamples))

        var mags = [Float](repeating: 0, count: barCount)
        for (i, freq) in targetFrequencies.enumerated() {
            mags[i] = goertzelMagnitude(samples: windowed, frequency: freq, sampleRate: sampleRate)
        }

        let bassBins = min(12, barCount)
        var bass: Float = 0
        for i in 0..<bassBins {
            bass += mags[i]
        }
        let bassNorm = min(1, bass / Float(bassBins) * 0.55)

        var display = [Float](repeating: 0, count: barCount)
        for i in 0..<barCount {
            let x = log10(1 + mags[i] * 220)
            display[i] = min(1, max(0.04, x / 2.85))
        }

        let smooth: Float = 0.32
        for i in 0..<barCount {
            smoothedLevels[i] = smoothedLevels[i] * (1 - smooth) + display[i] * smooth
        }

        let flux = max(0, bassNorm - smoothedBass)
        smoothedBass = smoothedBass * 0.9 + bassNorm * 0.1
        var pulse: Float = 0
        if flux > 0.035, bassNorm > 0.1 {
            pulse = min(1, flux * 7 + bassNorm * 0.35)
        }
        beatDecay = min(1, beatDecay * 0.86 + pulse * 0.55)

        let levelsOut = smoothedLevels.map { CGFloat($0) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.bassEnergy = CGFloat(bassNorm)
            self.beatPulse = CGFloat(self.beatDecay)
            self.barLevels = levelsOut
        }
    }

    private func goertzelMagnitude(samples: [Float], frequency: Float, sampleRate: Float) -> Float {
        let N = samples.count
        let k = max(1, Int(0.5 + Float(N) * frequency / sampleRate))
        guard k < N else { return 0 }
        let omega = 2 * Float.pi * Float(k) / Float(N)
        let coeff = 2 * cos(omega)
        var s0: Float = 0, s1: Float = 0, s2: Float = 0
        for x in samples {
            s0 = x + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let real = s1 - s2 * cos(omega)
        let imag = s2 * sin(omega)
        return hypot(real, imag) / Float(N)
    }

    private static func logSpacedFrequencies(count: Int, lowHz: Float, highHz: Float) -> [Float] {
        guard count > 1 else { return [lowHz] }
        return (0..<count).map { i in
            let t = Float(i) / Float(count - 1)
            return lowHz * pow(highHz / lowHz, t)
        }
    }
}

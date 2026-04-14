//
//  AudioReactivePlayer.swift
//  SoundSeen
//

import Accelerate
import AVFoundation
import Combine
import Foundation
import QuartzCore

/// Plays tracks from URLs (bundled or imported) and publishes spectrum / beat data for visuals.
final class AudioReactivePlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var trackTitle = ""
    @Published private(set) var artistName = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var totalDurationSeconds: Double = 1
    @Published private(set) var barLevels: [CGFloat]
    @Published private(set) var beatPulse: CGFloat = 0
    @Published private(set) var bassEnergy: CGFloat = 0
    /// Spectral centroid → “brightness” of timbre (0…1).
    @Published private(set) var timbreBrightness: CGFloat = 0.5
    /// High-frequency energy share — air / hiss vs body (0…1).
    @Published private(set) var timbreAir: CGFloat = 0.5
    /// Zero-crossing density — grain / edge (0…1).
    @Published private(set) var timbreGrain: CGFloat = 0.2
    /// Very slow moving average of brightness — “memory” for delayed visuals (0…1).
    @Published private(set) var timbreMemory: CGFloat = 0.5
    /// How fast the spectrum centroid moves — shimmer / instability (0…1).
    @Published private(set) var timbreSheen: CGFloat = 0
    @Published private(set) var loadError: String?
    @Published private(set) var structureMarkers: [SongStructureMarker] = []
    /// Set when loading from a library row; used to avoid auto-loading another track when switching tabs.
    @Published private(set) var activeTrackId: UUID?
    /// Whether there is another track after the current one in the playback queue.
    @Published private(set) var hasNextTrack: Bool = false
    /// Whether there is a track before the current one in the playback queue.
    @Published private(set) var hasPreviousTrack: Bool = false
    /// Shuffle is enabled for queue order (toggle in the UI).
    @Published private(set) var isShuffleEnabled: Bool = false
    /// Time × frequency grid for wireframe spectrum (row 0 = newest). Updated from the analyzer thread.
    @Published private(set) var spectrumHistoryGrid: [[Float]] = []
    /// Smoothed perceptual loudness estimate normalized to 0...1.
    @Published private(set) var perceptualLoudness: CGFloat = 0
    /// Positive when loudness is rising above its slow baseline (0...1-ish).
    @Published private(set) var loudnessRise: CGFloat = 0
    /// Positive when loudness is falling below its slow baseline (0...1-ish).
    @Published private(set) var loudnessFall: CGFloat = 0
    /// Realtime drop-impact confidence from transient + low-end energy (0...1).
    @Published private(set) var dropLikelihood: CGFloat = 0
    /// Decays after impact moments so visuals/haptics can render emotional recovery.
    @Published private(set) var afterglowAmount: CGFloat = 0
    @Published private(set) var hapticIntensityMode: HapticIntensityMode = .balanced

    private let barCount: Int
    private let analysisSamples = 1024

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    private var audioFile: AVAudioFile?
    private var sampleRate: Float = 44100
    /// Frame index in the file where the current playback segment began (updated on each schedule).
    private var playbackAnchorFrame: AVAudioFramePosition = 0
    /// Media timeline origin for `playbackAnchorFrame` while audio is running (nil when paused).
    private var playbackAnchorMediaTime: CFTimeInterval?
    /// True after the scheduled segment finishes or a seek lands past the last frame — center button replays from the start.
    private var stoppedAtEnd = false
    /// Monotonic token for scheduled segments; ignores stale completion callbacks after stop/reschedule.
    private var scheduleGeneration: UInt64 = 0

    private var targetFrequencies: [Float] = []

    private var smoothedLevels: [Float]
    private var smoothedBass: Float = 0
    private var beatDecay: Float = 0
    private var timbreCentroidSmooth: Float = 0.5
    private var timbreMemoryState: Float = 0.5
    private var timbreSheenState: Float = 0
    private var loudnessNormState: Float = 0
    private var loudnessSlowState: Float = 0
    private var dropLikelihoodState: Float = 0
    private var loudnessFloorDb: Float = -48
    private var loudnessCeilDb: Float = -8
    private var afterglowState: Float = 0

    private var spectrumHistoryRows: [[Float]] = []
    private let spectrumHistoryMaxRows = 48
    private var lastSpectrumHistoryTime: CFTimeInterval = 0
    private let spectrumHistoryInterval: CFTimeInterval = 1.0 / 32.0

    private var progressTimer: Timer?
    private var tapInstalled = false
    private var sessionConfigured = false
    /// Skips timer-driven progress updates while the user scrubs the slider.
    private var isScrubbing = false

    private let processingQueue = DispatchQueue(label: "soundseen.audio.analysis", qos: .userInteractive)

    private var libraryQueue: [LibraryTrack] = []
    private var queueIndex: Int = 0
    /// Latest `allTracks` from `loadFromLibrary` / shuffle — used to resolve fresh `LibraryTrack` + URLs when skipping in the queue.
    private var lastKnownLibraryTracks: [LibraryTrack] = []
    /// Resolves bundled file URLs by track id (set from `ContentView.onAppear`).
    private weak var libraryStore: LibraryStore?
    private var hapticConductor: HapticConductor = NullHapticConductor()
    private var lastBeatHapticTime: CFTimeInterval = 0
    private var lastSectionHapticKind: SongStructureKind?

    func attachLibrary(_ store: LibraryStore) {
        libraryStore = store
    }

    func attachHapticConductor(_ conductor: HapticConductor) {
        hapticConductor = conductor
        hapticConductor.setIntensityMode(hapticIntensityMode)
    }

    func setHapticIntensityMode(_ mode: HapticIntensityMode) {
        hapticIntensityMode = mode
        hapticConductor.setIntensityMode(mode)
    }

    private func urlForPlayback(_ track: LibraryTrack) -> URL? {
        if let store = libraryStore {
            return store.playbackURL(for: track)
        }
        return track.importedPlaybackURL
    }

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

    var currentTimeSeconds: Double {
        progress * max(0.001, totalDurationSeconds)
    }

    static func formatClock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        let m = s / 60
        let r = s % 60
        return String(format: "%d:%02d", m, r)
    }

    var formattedCurrentTime: String { Self.formatClock(currentTimeSeconds) }
    var formattedDuration: String { Self.formatClock(totalDurationSeconds) }

    func setScrubbing(_ active: Bool) {
        isScrubbing = active
    }

    /// Load and play a library track (bundled or imported).
    func load(track: LibraryTrack) {
        guard let url = urlForPlayback(track) else {
            loadError = "Missing audio file for “\(track.title)”."
            return
        }
        load(url: url, title: track.title, artist: track.artist, trackId: track.id)
    }

    /// Sets up in-order or shuffled queue from the library, then loads the track.
    func loadFromLibrary(_ track: LibraryTrack, allTracks: [LibraryTrack], shuffled: Bool = false) {
        let ordered: [LibraryTrack]
        if shuffled {
            ordered = allTracks.shuffled()
        } else if isShuffleEnabled {
            let others = allTracks.filter { $0.id != track.id }.shuffled()
            ordered = [track] + others
        } else {
            ordered = allTracks
        }
        // `?? 0` was wrong: if the index lookup failed, index 0 pointed at a different song than `track`, breaking skip and queue.
        if let idx = ordered.firstIndex(where: { $0.id == track.id }) {
            libraryQueue = ordered
            queueIndex = idx
        } else {
            libraryQueue = [track] + ordered.filter { $0.id != track.id }
            queueIndex = 0
        }
        lastKnownLibraryTracks = allTracks
        updateQueueNavigationState()
        load(track: track)
    }

    /// Full ordered playback queue (for the queue sheet).
    var orderedQueueTracks: [LibraryTrack] { libraryQueue }

    /// Index of the currently playing track within `orderedQueueTracks`.
    var currentQueueIndex: Int { queueIndex }

    /// Tracks after the current item in the playback queue (for “Up Next”).
    var upcomingTracks: [LibraryTrack] {
        guard queueIndex + 1 < libraryQueue.count else { return [] }
        return Array(libraryQueue[(queueIndex + 1)...])
    }

    /// Jump to any position in the current queue (uses the latest library snapshot when available).
    func jumpToQueueIndex(_ index: Int, libraryTracks: [LibraryTrack]? = nil) {
        guard libraryQueue.indices.contains(index) else { return }
        queueIndex = index
        updateQueueNavigationState()
        let track = resolvedTrackAtQueueIndex(libraryTracks: libraryTracks)
        load(track: track)
    }

    private func resolvedTrackAtQueueIndex(libraryTracks: [LibraryTrack]?) -> LibraryTrack {
        let id = libraryQueue[queueIndex].id
        let pool = libraryTracks ?? libraryStore?.tracks ?? lastKnownLibraryTracks
        return pool.first(where: { $0.id == id }) ?? libraryQueue[queueIndex]
    }

    private func libraryPool() -> [LibraryTrack] {
        libraryStore?.tracks ?? lastKnownLibraryTracks
    }

    /// Play the next track in the current queue only (stays in sync with `libraryQueue` / `queueIndex`).
    func playNextFromLibrary() {
        guard queueIndex + 1 < libraryQueue.count else { return }
        queueIndex += 1
        lastKnownLibraryTracks = libraryPool()
        updateQueueNavigationState()
        load(track: resolvedTrackAtQueueIndex(libraryTracks: libraryStore?.tracks))
    }

    /// Play the previous track in the current queue only.
    func playPreviousFromLibrary() {
        guard queueIndex > 0 else { return }
        queueIndex -= 1
        lastKnownLibraryTracks = libraryPool()
        updateQueueNavigationState()
        load(track: resolvedTrackAtQueueIndex(libraryTracks: libraryStore?.tracks))
    }

    /// Jump to an upcoming track: `offset` 0 is the next track, 1 is the one after that, etc.
    func skipToUpcoming(offset: Int) {
        let target = queueIndex + 1 + offset
        guard offset >= 0, target < libraryQueue.count else { return }
        jumpToQueueIndex(target, libraryTracks: nil)
    }

    /// Shuffle all library tracks and start playback from the first shuffled item (enables shuffle mode).
    func shuffleLibraryAndPlay(allTracks: [LibraryTrack]) {
        guard !allTracks.isEmpty else { return }
        isShuffleEnabled = true
        let s = allTracks.shuffled()
        libraryQueue = s
        queueIndex = 0
        lastKnownLibraryTracks = allTracks
        updateQueueNavigationState()
        load(track: resolvedTrackAtQueueIndex(libraryTracks: allTracks))
    }

    /// Toggles shuffle; when enabling, reorders the queue (current track first when already playing).
    func toggleShuffle(allTracks: [LibraryTrack]) {
        guard !allTracks.isEmpty else { return }
        lastKnownLibraryTracks = allTracks
        if isShuffleEnabled {
            isShuffleEnabled = false
            guard !libraryQueue.isEmpty else { return }
            let currentId = libraryQueue[queueIndex].id
            libraryQueue = allTracks
            queueIndex = libraryQueue.firstIndex { $0.id == currentId } ?? 0
            updateQueueNavigationState()
        } else {
            isShuffleEnabled = true
            if libraryQueue.isEmpty {
                libraryQueue = allTracks.shuffled()
                queueIndex = 0
                updateQueueNavigationState()
                load(track: resolvedTrackAtQueueIndex(libraryTracks: allTracks))
            } else {
                let current = libraryQueue[queueIndex]
                let others = allTracks.filter { $0.id != current.id }.shuffled()
                libraryQueue = [current] + others
                queueIndex = 0
                updateQueueNavigationState()
            }
        }
    }

    private func updateQueueNavigationState() {
        let n = libraryQueue.count
        guard n > 0 else {
            hasNextTrack = false
            hasPreviousTrack = false
            return
        }
        hasNextTrack = queueIndex + 1 < n
        hasPreviousTrack = queueIndex > 0
    }

    /// Call after the user finishes scrubbing so play/pause state cannot get stuck in “ended / restart only” mode.
    func endScrubSession() {
        stoppedAtEnd = false
    }

    func load(url: URL, title: String, artist: String, trackId: UUID? = nil) {
        loadError = nil
        structureMarkers = []
        trackTitle = title
        artistName = artist

        do {
            try configureSessionIfNeeded()
            try rebuildEngineAndPlay(url: url)
            activeTrackId = trackId
            scheduleStructureScan(url: url)
        } catch {
            loadError = error.localizedDescription
            activeTrackId = nil
        }
    }

    private func scheduleStructureScan(url: URL) {
        Task.detached(priority: .utility) { [weak self, url] in
            do {
                let markers = try SongStructureScanner.scan(url: url)
                await MainActor.run { [weak self] in
                    self?.structureMarkers = markers
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.structureMarkers = []
                }
            }
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
        progress = 0
        playbackAnchorMediaTime = nil
        stoppedAtEnd = false
        timbreCentroidSmooth = 0.5
        timbreMemoryState = 0.5
        timbreSheenState = 0
        loudnessNormState = 0
        loudnessSlowState = 0
        dropLikelihoodState = 0
        afterglowState = 0
        loudnessFloorDb = -48
        loudnessCeilDb = -8
        lastBeatHapticTime = 0
        lastSectionHapticKind = nil
        spectrumHistoryRows.removeAll()

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
        totalDurationSeconds = Double(file.length) / file.processingFormat.sampleRate

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
        scheduleFileAndPlay(file: file, startingFrame: 0, shouldPlay: true)

        DispatchQueue.main.async { [weak self] in
            self?.spectrumHistoryGrid = []
            self?.updateQueueNavigationState()
        }
    }

    func seek(toProgress: Double) {
        guard let file = audioFile, loadError == nil else { return }
        let p = min(1, max(0, toProgress))
        let frame = AVAudioFramePosition(p * Double(file.length))
        let wasPlaying = isPlaying
        progress = p
        // Any seek into playable audio is not “stopped at end”.
        stoppedAtEnd = false
        scheduleFileAndPlay(file: file, startingFrame: frame, shouldPlay: wasPlaying)
    }

    func togglePlayPause() {
        guard let file = audioFile, loadError == nil else { return }

        if isPlaying {
            syncPlaybackProgressIfNeeded()
            playerNode.pause()
            isPlaying = false
            playbackAnchorMediaTime = nil
            // Never leave a stale “ended” flag after a manual pause mid-track.
            if progress < 0.97 {
                stoppedAtEnd = false
            }
            return
        }

        // Only replay from the top when the segment actually finished (or seek landed past EOF).
        if stoppedAtEnd {
            stoppedAtEnd = false
            progress = 0
            scheduleFileAndPlay(file: file, startingFrame: 0, shouldPlay: true)
            return
        }

        playbackAnchorFrame = AVAudioFramePosition(progress * Double(file.length))
        playbackAnchorMediaTime = CACurrentMediaTime()
        playerNode.play()
        isPlaying = true
    }

    func restartFromBeginning() {
        guard let file = audioFile, loadError == nil else { return }
        progress = 0
        stoppedAtEnd = false
        scheduleFileAndPlay(file: file, startingFrame: 0, shouldPlay: true)
    }

    private func handleSegmentFinished() {
        isPlaying = false
        progress = 1
        playbackAnchorMediaTime = nil

        guard !libraryQueue.isEmpty else {
            stoppedAtEnd = true
            return
        }
        if queueIndex + 1 < libraryQueue.count {
            playNextFromLibrary()
        } else {
            stoppedAtEnd = true
        }
    }

    private func scheduleFileAndPlay(file: AVAudioFile, startingFrame: AVAudioFramePosition, shouldPlay: Bool) {
        playerNode.stop()
        scheduleGeneration &+= 1
        let generationAtSchedule = scheduleGeneration
        let remaining = file.length - startingFrame
        guard remaining > 0 else {
            progress = 1
            isPlaying = false
            playbackAnchorMediaTime = nil
            stoppedAtEnd = true
            return
        }
        stoppedAtEnd = false
        playbackAnchorFrame = startingFrame
        playerNode.scheduleSegment(
            file,
            startingFrame: startingFrame,
            frameCount: AVAudioFrameCount(remaining),
            at: nil
        ) { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.scheduleGeneration == generationAtSchedule else { return }
                self.handleSegmentFinished()
            }
        }
        playerNode.play()
        if shouldPlay {
            isPlaying = true
            playbackAnchorMediaTime = CACurrentMediaTime()
        } else {
            playerNode.pause()
            isPlaying = false
            playbackAnchorMediaTime = nil
        }
        startProgressTimerIfNeeded()
    }

    /// Uses the node's playhead when available (`sampleTime` is the file position); falls back to wall-clock anchor.
    private func syncPlaybackProgressIfNeeded() {
        guard let file = audioFile else { return }
        guard isPlaying else { return }

        if let nodeTime = playerNode.lastRenderTime,
           let pt = playerNode.playerTime(forNodeTime: nodeTime),
           pt.isSampleTimeValid {
            // `sampleTime` is relative to the currently scheduled segment.
            // Add the segment's starting frame so progress stays aligned after seeks.
            let segmentFrame = playbackAnchorFrame + pt.sampleTime
            let absFrame = min(max(0, segmentFrame), file.length)
            progress = Double(absFrame) / Double(max(1, file.length))
            stoppedAtEnd = false
            return
        }

        guard let t0 = playbackAnchorMediaTime else { return }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return }

        let elapsed = CACurrentMediaTime() - t0
        let framesPlayed = AVAudioFramePosition(elapsed * rate)
        var absFrame = playbackAnchorFrame + framesPlayed
        absFrame = min(max(0, absFrame), file.length)
        progress = Double(absFrame) / Double(max(1, file.length))
        stoppedAtEnd = false
    }

    private func startProgressTimerIfNeeded() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard !self.isScrubbing else { return }
            guard self.isPlaying else { return }
            self.syncPlaybackProgressIfNeeded()
            self.emitSectionHapticIfNeeded()
        }
        RunLoop.main.add(progressTimer!, forMode: .common)
    }

    private func emitSectionHapticIfNeeded() {
        guard !structureMarkers.isEmpty else { return }
        let kind = SongStructureScanner.currentSection(
            timeSeconds: currentTimeSeconds,
            duration: totalDurationSeconds,
            markers: structureMarkers
        )
        guard kind != lastSectionHapticKind else { return }
        lastSectionHapticKind = kind
        hapticConductor.handle(event: .sectionChange(kind))
        if kind == .drop {
            afterglowState = 1
            hapticConductor.handle(event: .dropImpact)
        }
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

        // —— Timbre features (same Goertzel bins; no 1:1 bar mapping) ——
        var sumWeightedFreq: Float = 0
        var sumMag: Float = 1e-8
        for i in 0..<barCount {
            sumWeightedFreq += targetFrequencies[i] * mags[i]
            sumMag += mags[i]
        }
        let centroidHz = sumWeightedFreq / sumMag
        let logCentroid = log10(max(80, centroidHz))
        // ~80 Hz → 0, ~12 kHz → 1
        let brightnessRaw = (logCentroid - 1.9) / (4.08 - 1.9)
        let brightness = min(1, max(0, brightnessRaw))

        let third = max(1, barCount / 3)
        var lowE: Float = 0, midE: Float = 0, highE: Float = 0
        for i in 0..<barCount {
            if i < third {
                lowE += mags[i]
            } else if i < third * 2 {
                midE += mags[i]
            } else {
                highE += mags[i]
            }
        }
        let totalBand = lowE + midE + highE + 1e-8
        let air = highE / totalBand

        var crossings = 0
        for i in 1..<analysisSamples {
            if mono[i - 1] * mono[i] < 0 { crossings += 1 }
        }
        let zcrRaw = Float(crossings) / Float(analysisSamples)
        let grain = min(1, zcrRaw * 10)

        let rmsValue = sqrt(mono.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, analysisSamples)))
        let loudnessDb = 20 * log10(max(1e-6, rmsValue))
        loudnessFloorDb = min(loudnessFloorDb * 0.997 + loudnessDb * 0.003, loudnessDb)
        loudnessCeilDb = max(loudnessCeilDb * 0.996 + loudnessDb * 0.004, loudnessDb + 6)
        let loudnessRange = max(10, loudnessCeilDb - loudnessFloorDb)
        let loudnessNormRaw = (loudnessDb - loudnessFloorDb) / loudnessRange
        let loudnessNorm = min(1, max(0, loudnessNormRaw))
        loudnessNormState = loudnessNormState * 0.86 + loudnessNorm * 0.14
        loudnessSlowState = loudnessSlowState * 0.985 + loudnessNormState * 0.015
        let rise = max(0, loudnessNormState - loudnessSlowState)
        let dropRaw = max(0, flux * 10 + bassNorm * 1.05 + rise * 1.6 - 0.62)
        dropLikelihoodState = min(1, dropLikelihoodState * 0.78 + dropRaw * 0.36)
        if dropLikelihoodState > 0.72 {
            afterglowState = max(afterglowState, min(1, dropLikelihoodState))
        }
        afterglowState *= 0.982

        timbreMemoryState = timbreMemoryState * 0.992 + brightness * 0.008

        let prevSmooth = timbreCentroidSmooth
        timbreCentroidSmooth = timbreCentroidSmooth * 0.88 + brightness * 0.12
        let centroidJump = abs(timbreCentroidSmooth - prevSmooth)
        timbreSheenState = timbreSheenState * 0.82 + centroidJump * 2.8
        let sheen = min(1, timbreSheenState)

        let nowMono = CACurrentMediaTime()
        let shouldEmitBeat = pulse > 0.65
        var historySnapshot: [[Float]]?
        if nowMono - lastSpectrumHistoryTime >= spectrumHistoryInterval {
            lastSpectrumHistoryTime = nowMono
            spectrumHistoryRows.insert(Array(smoothedLevels), at: 0)
            if spectrumHistoryRows.count > spectrumHistoryMaxRows {
                spectrumHistoryRows.removeLast()
            }
            historySnapshot = spectrumHistoryRows
        }

        let levelsOut = smoothedLevels.map { CGFloat($0) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.bassEnergy = CGFloat(bassNorm)
            self.beatPulse = CGFloat(self.beatDecay)
            self.barLevels = levelsOut
            self.timbreBrightness = CGFloat(brightness)
            self.timbreAir = CGFloat(air)
            self.timbreGrain = CGFloat(grain)
            self.timbreMemory = CGFloat(self.timbreMemoryState)
            self.timbreSheen = CGFloat(sheen)
            self.perceptualLoudness = CGFloat(self.loudnessNormState)
            self.loudnessRise = CGFloat(min(1, rise * 3.2))
            self.loudnessFall = CGFloat(min(1, max(0, self.loudnessSlowState - self.loudnessNormState) * 3.2))
            self.dropLikelihood = CGFloat(self.dropLikelihoodState)
            self.afterglowAmount = CGFloat(min(1, max(0, self.afterglowState)))
            if let h = historySnapshot {
                self.spectrumHistoryGrid = h
            }
            if shouldEmitBeat, nowMono - self.lastBeatHapticTime > 0.18 {
                self.lastBeatHapticTime = nowMono
                self.hapticConductor.handle(event: .beat(strength: CGFloat(min(1, pulse))))
            }
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

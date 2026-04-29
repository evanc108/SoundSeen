//
//  AudioSessionCoordinator.swift
//  SoundSeen
//
//  Single owner of `AVAudioSession` state. Library playback and Live
//  microphone capture want different categories (.playback vs
//  .playAndRecord), and leaking the Live category across tab transitions
//  routes playback to the earpiece instead of the speaker. This actor
//  centralizes the transitions and handles interruption / mediaServices
//  notifications in one place.
//
//  Not reference-counted — Library → Live → Library works by explicit
//  calls to `configureForPlayback` / `configureForLive`. Mutating category
//  on every play/stop would over-solve.
//

import Foundation

#if os(iOS)
import AVFoundation

actor AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()

    enum Mode: Equatable {
        case idle
        case playback
        case live
    }

    private(set) var mode: Mode = .idle
    private var observersInstalled = false

    private init() {}

    func configureForPlayback() throws {
        try setCategory(.playback, mode: .default, options: [])
        self.mode = .playback
    }

    /// `.playAndRecord` + `.measurement` gives the flattest input path for
    /// DSP — less AGC curve baked into samples. `.defaultToSpeaker` keeps
    /// output on the loudspeaker when nothing else is routed; `.mixWithOthers`
    /// lets background audio (e.g. Music app) keep playing and be picked up
    /// by the mic, which is often exactly what the user wants.
    func configureForLive() throws {
        try setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.defaultToSpeaker, .mixWithOthers, .allowBluetoothA2DP]
        )
        self.mode = .live
    }

    /// Explicit deactivate — call on Live view `onDisappear` when no other
    /// player is about to take over. The `.notifyOthersOnDeactivation` flag
    /// lets the system know it's safe to resume other apps' audio.
    func deactivate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        self.mode = .idle
    }

    private func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        installObserversIfNeeded()
        let session = AVAudioSession.sharedInstance()
        // Setting the same category+options is cheap but still triggers a
        // route-change notification; skip the redundant call so we don't
        // stutter mid-session.
        if session.category == category
            && session.mode == mode
            && session.categoryOptions == options
        {
            try session.setActive(true)
            return
        }
        try session.setCategory(category, mode: mode, options: options)
        try session.setActive(true)
    }

    private func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default
        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            Task { await self.handleInterruption(note) }
        }
        center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleMediaServicesReset() }
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard
            let info = note.userInfo,
            let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            // System will have already paused our audio; nothing to do here.
            // LiveAudioEngine listens separately and pauses the engine.
            break
        case .ended:
            guard
                let rawOpts = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            else { return }
            let opts = AVAudioSession.InterruptionOptions(rawValue: rawOpts)
            guard opts.contains(.shouldResume) else { return }
            switch mode {
            case .playback:
                try? AVAudioSession.sharedInstance().setActive(true)
            case .live:
                try? AVAudioSession.sharedInstance().setActive(true)
            case .idle:
                break
            }
        @unknown default:
            break
        }
    }

    private func handleMediaServicesReset() {
        // All session / engine state is gone. Re-apply the last mode so the
        // next playback/live action works. The owning view (LiveView) also
        // observes this notification to rebuild AVAudioEngine.
        switch mode {
        case .playback: try? setCategory(.playback, mode: .default, options: [])
        case .live:
            try? setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .mixWithOthers, .allowBluetoothA2DP]
            )
        case .idle:
            break
        }
    }
}

#else

/// macOS stub — no AVAudioSession. The app still compiles for macOS
/// previews; live mic on macOS is out of scope for this release.
actor AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()
    enum Mode { case idle, playback, live }
    private(set) var mode: Mode = .idle
    private init() {}
    func configureForPlayback() throws { self.mode = .playback }
    func configureForLive() throws { self.mode = .live }
    func deactivate() { self.mode = .idle }
}

#endif

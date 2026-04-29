//
//  AudioPlayer.swift
//  SoundSeen
//
//  @Observable wrapper around AVAudioPlayer. A ~60Hz ticker writes
//  `currentTime` on every frame and fans out to registered tick handlers,
//  which is how VisualizerState and HapticEngine stay aligned on one clock.
//  On iOS we use CADisplayLink (vsync-aligned); on macOS we fall back to a
//  Timer since CADisplayLink's target/selector initializer is iOS-only and
//  we don't have an NSView reference here for the macOS 14+ API.
//
//  Why AVAudioPlayer and not AVAudioEngine/AVPlayer: for file-based playback
//  with an async analysis pipeline, AVAudioPlayer is the simplest API. It
//  has no KVO time observer, so we poll — polling is idiomatic here and
//  gives us a single clock source for visuals and haptics.
//

import AVFoundation
import Foundation
import Observation
#if os(iOS)
import QuartzCore
#endif

@Observable
@MainActor
final class AudioPlayer {
    // Observable state — SwiftUI views and the visualizer read these.
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying: Bool = false

    // Non-observable internals (hidden from the Observation macro).
    @ObservationIgnored private var player: AVAudioPlayer?
    #if os(iOS)
    @ObservationIgnored private var displayLink: CADisplayLink?
    #else
    @ObservationIgnored private var tickTimer: Timer?
    #endif
    @ObservationIgnored private var tickHandlers: [(Double, Double) -> Void] = []
    @ObservationIgnored private var lastTickTime: TimeInterval = 0

    init() {
        configureAudioSession()
    }

    deinit {
        #if os(iOS)
        displayLink?.invalidate()
        #else
        tickTimer?.invalidate()
        #endif
    }

    // MARK: - Public API

    /// Load an audio file. Resets current state.
    func load(url: URL) throws {
        stop()
        let newPlayer = try AVAudioPlayer(contentsOf: url)
        newPlayer.prepareToPlay()
        player = newPlayer
        duration = newPlayer.duration
        currentTime = 0
        lastTickTime = 0
    }

    func play() {
        guard let player else { return }
        if !player.isPlaying {
            player.play()
        }
        isPlaying = true
        startDisplayLinkIfNeeded()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopDisplayLink()
    }

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    /// Seek to a time (seconds). Does not start playback on its own.
    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = max(0, min(time, player.duration))
        // Fire with (previous, new) so cursor-based consumers see a discontinuity
        // on forward seeks. If we passed (clamped, clamped), Δ == 0 and the next
        // natural tick would fast-fire every beat between the old and new times.
        let previous = currentTime
        player.currentTime = clamped
        currentTime = clamped
        lastTickTime = clamped
        for handler in tickHandlers {
            handler(previous, clamped)
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        lastTickTime = 0
        stopDisplayLink()
    }

    /// Register a callback that runs on every display-link tick with the
    /// previous and current playback times (both in seconds). Used by
    /// VisualizerState and HapticEngine to stay aligned on one clock.
    func addTickHandler(_ handler: @escaping (_ prevTime: Double, _ currentTime: Double) -> Void) {
        tickHandlers.append(handler)
    }

    func removeAllTickHandlers() {
        tickHandlers.removeAll()
    }

    // MARK: - Tick loop

    private func startDisplayLinkIfNeeded() {
        #if os(iOS)
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy(owner: self),
                                 selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        #else
        guard tickTimer == nil else { return }
        // 60Hz polling. Not vsync-aligned like CADisplayLink, but sufficient
        // for audio-synchronized visuals on macOS.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        #endif
    }

    private func stopDisplayLink() {
        #if os(iOS)
        displayLink?.invalidate()
        displayLink = nil
        #else
        tickTimer?.invalidate()
        tickTimer = nil
        #endif
    }

    fileprivate func handleTick() {
        guard let player else { return }
        // If playback reached the end, AVAudioPlayer stops itself — reflect that.
        if !player.isPlaying && isPlaying {
            isPlaying = false
            stopDisplayLink()
        }
        let prev = lastTickTime
        let now = player.currentTime
        currentTime = now
        lastTickTime = now
        if now != prev {
            for handler in tickHandlers {
                handler(prev, now)
            }
        }
    }

    // MARK: - Audio session

    private func configureAudioSession() {
        // Route through the coordinator so Library→Live→Library transitions
        // reset the category cleanly instead of leaving the session in
        // .playAndRecord (which sends playback to the earpiece).
        Task {
            do {
                try await AudioSessionCoordinator.shared.configureForPlayback()
            } catch {
                print("AudioPlayer: audio session config failed: \(error)")
            }
        }
    }
}

#if os(iOS)
// CADisplayLink retains its target, so we route the callback through a
// weak-holding proxy to avoid a retain cycle with AudioPlayer.
private final class DisplayLinkProxy: NSObject {
    weak var owner: AudioPlayer?
    init(owner: AudioPlayer) { self.owner = owner }

    @MainActor @objc func tick() {
        owner?.handleTick()
    }
}
#endif

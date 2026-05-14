//
//  VideoPlayback.swift
//  SoundSeen
//
//  AVPlayer wrapper that exposes the same (prev, current) tick handler
//  shape that AudioPlayer did, so HapticVocabulary keeps its existing
//  interface. Clock source moves from AVAudioPlayer + CADisplayLink to
//  AVPlayer + addPeriodicTimeObserver.
//

import AVFoundation
import Combine
import Foundation

@MainActor
final class VideoPlayback: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying: Bool = false

    private var timeObserverToken: Any?
    private var tickHandlers: [(Double, Double) -> Void] = []
    private var lastTickTime: TimeInterval = 0
    private var rateObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    deinit {
        // Synchronous teardown — AVPlayer + observers tolerate being torn
        // down off-main during deinit.
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        rateObservation?.invalidate()
    }

    func load(url: URL) async {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        if let asset = item.asset as AVAsset? {
            let value = try? await asset.load(.duration)
            duration = value.map { CMTimeGetSeconds($0) } ?? 0
        }
        attachObservers(item: item)
    }

    func addTickHandler(_ handler: @escaping (Double, Double) -> Void) {
        tickHandlers.append(handler)
    }

    func removeAllTickHandlers() {
        tickHandlers.removeAll()
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func seek(to seconds: TimeInterval) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        // Reset prev so the haptic clock doesn't fire on a backward sweep.
        lastTickTime = seconds
        currentTime = seconds
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Observers

    private func attachObservers(item: AVPlayerItem) {
        // 1/60s @ timescale 600 — matches the prior CADisplayLink cadence so
        // HapticVocabulary.tick sweeps cleanly across beats/onsets.
        if timeObserverToken == nil {
            let interval = CMTimeMakeWithSeconds(1.0/60.0, preferredTimescale: 600)
            timeObserverToken = player.addPeriodicTimeObserver(
                forInterval: interval, queue: .main
            ) { [weak self] time in
                guard let self else { return }
                MainActor.assumeIsolated {
                    let now = CMTimeGetSeconds(time)
                    let prev = self.lastTickTime
                    self.currentTime = now
                    self.lastTickTime = now
                    for handler in self.tickHandlers {
                        handler(prev, now)
                    }
                }
            }
        }

        if rateObservation == nil {
            rateObservation = player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
                let playing = player.rate > 0
                let weakSelf = self
                Task { @MainActor in
                    weakSelf?.isPlaying = playing
                }
            }
        }

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pause() }
        }
    }
}

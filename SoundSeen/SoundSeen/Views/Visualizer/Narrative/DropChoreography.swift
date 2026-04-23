//
//  DropChoreography.swift
//  SoundSeen
//
//  Material three-phase state machine for the drop moment. Replaces the
//  old white-radial-wipe approach with something that reads as *heat,
//  fire, pressure wave*:
//
//    crest  (0.35s) — thermal shimmer ramps 0→100%, palette invert ramps
//                     0→0.8, ember accelerator fires; choreography does NOT
//                     emit visible rings or wipe rectangles.
//    release (0.25s) — thermal shimmer holds at 100%, palette invert at
//                     1.0, ember spray escape emitted once, drop.ahap fires.
//    settle (0.70s) — thermal + invert both decay. Normal scene recovers.
//
//  Thermal shimmer strength and palette invert amount are exposed so the
//  ThermalShimmerTexture + a palette-invert overlay in VisualizerRoot can
//  read them each frame.
//

import Foundation
import Observation

@Observable
@MainActor
final class DropChoreography {
    enum Phase: String, Sendable { case idle, crest, flash, settle }

    private(set) var phase: Phase = .idle
    /// 0..1 progress within the current phase; 0 in idle.
    private(set) var phaseProgress: Double = 0
    /// 0..1 palette inversion strength — rises through crest, peaks in
    /// flash, decays through settle. Consumed by the invert overlay.
    private(set) var invertAmount: Double = 0
    /// Monotonic counter bumped each time a release phase starts. Textures
    /// that want to spawn one-shot effects on the drop hit observe this.
    private(set) var releaseGeneration: Int = 0

    @ObservationIgnored private weak var state: VisualizerState?
    /// Fires once at the start of `release` (flash) — HapticVocabulary plays
    /// the drop .ahap pattern here. Intentionally fires at release rather
    /// than crest so the haptic hit lands with the visual climax.
    @ObservationIgnored var onDropReleased: (() -> Void)?

    @ObservationIgnored private var phaseStarted: Double = 0
    @ObservationIgnored private var lastTriggerTime: Double = -.infinity
    @ObservationIgnored private var lastSectionLabel: String = ""
    @ObservationIgnored private var releaseEmitted: Bool = false

    private let crestDuration: Double = 0.35
    private let releaseDuration: Double = 0.25
    private let settleDuration: Double = 0.70
    private let retriggerCooldown: Double = 4.0

    init(state: VisualizerState) {
        self.state = state
    }

    /// Drive from the AudioPlayer tick handler.
    func tick(prevTime: Double, currentTime: Double) {
        guard let state else { return }

        // Seek / discontinuity: reset state machine + cooldown.
        if currentTime < prevTime || (currentTime - prevTime) > 1.0 {
            resetToIdle()
            lastTriggerTime = -.infinity
            lastSectionLabel = state.currentSectionLabel
            return
        }

        switch phase {
        case .idle:
            if shouldTrigger(at: currentTime, in: state) {
                enterPhase(.crest, at: currentTime)
                lastTriggerTime = currentTime
            }
        case .crest:
            let p = progress(now: currentTime, duration: crestDuration)
            phaseProgress = p
            // Invert ramps to 0.8 through crest — anticipation building.
            invertAmount = p * 0.8
            if p >= 1 { enterPhase(.flash, at: currentTime) }
        case .flash:
            let p = progress(now: currentTime, duration: releaseDuration)
            phaseProgress = p
            invertAmount = 1.0
            // One-shot signals at release entry.
            if !releaseEmitted {
                releaseEmitted = true
                releaseGeneration &+= 1
                onDropReleased?()
            }
            if p >= 1 { enterPhase(.settle, at: currentTime) }
        case .settle:
            let p = progress(now: currentTime, duration: settleDuration)
            phaseProgress = p
            invertAmount = (1 - p)
            if p >= 1 { resetToIdle() }
        }

        lastSectionLabel = state.currentSectionLabel
    }

    // MARK: - Triggers

    private func shouldTrigger(at time: Double, in state: VisualizerState) -> Bool {
        // Cooldown protects against sustained-drop re-trigger and close
        // chorus-to-drop transitions.
        guard time - lastTriggerTime >= retriggerCooldown else { return false }

        // 1) Section-based: rising edge into "drop".
        let label = state.currentSectionLabel.lowercased()
        let enteredDropSection = label == "drop" && lastSectionLabel.lowercased() != "drop"
        if enteredDropSection { return true }

        // 2) Heuristic: emergent climax even outside a detected drop section.
        if state.smoothedArousal > 0.82
            && state.currentFlux > 0.75
            && state.currentEnergy > 0.70
        {
            return true
        }
        return false
    }

    // MARK: - Phase transitions

    private func enterPhase(_ p: Phase, at time: Double) {
        phase = p
        phaseStarted = time
        phaseProgress = 0
        if p == .flash { releaseEmitted = false }
    }

    private func resetToIdle() {
        phase = .idle
        phaseProgress = 0
        invertAmount = 0
        releaseEmitted = false
    }

    private func progress(now: Double, duration: Double) -> Double {
        guard duration > 1e-6 else { return 1 }
        return min(1, max(0, (now - phaseStarted) / duration))
    }
}

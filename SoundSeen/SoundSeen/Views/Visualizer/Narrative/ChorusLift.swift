//
//  ChorusLift.swift
//  SoundSeen
//
//  One-shot bloom on the rising edge into `chorus`. Peaks ~200ms after
//  chorus entry and decays to zero over 1.2s total, so the moment reads
//  as a gradient push + brightness lift without overstaying its welcome.
//
//  Mirrors DropChoreography's rising-edge detection pattern so chorus
//  entries that immediately follow a bridge or drop are still caught.
//  A 3s cooldown prevents re-firing if the section label flutters across
//  a boundary.
//

import Foundation
import Observation

@Observable
@MainActor
final class ChorusLift {
    /// 0 at rest, 1 at peak bloom. Consumers render a top-half radial
    /// bloom + brightness overlay scaled by this value.
    private(set) var strength: Double = 0

    @ObservationIgnored private weak var state: VisualizerState?
    @ObservationIgnored private var lastSectionLabel: String = ""
    @ObservationIgnored private var phaseStarted: Double = -.infinity
    @ObservationIgnored private var lastTriggerTime: Double = -.infinity

    private let liftDuration: Double = 1.2
    /// Normalized time at which the bloom peaks. Fast rise, slow fall.
    private let peakFraction: Double = 0.18
    private let retriggerCooldown: Double = 3.0

    init(state: VisualizerState) {
        self.state = state
    }

    func tick(prevTime: Double, currentTime: Double) {
        guard let state else { return }

        // Discontinuity reset.
        if currentTime < prevTime || (currentTime - prevTime) > 1.0 {
            strength = 0
            phaseStarted = -.infinity
            lastSectionLabel = state.currentSectionLabel
            return
        }

        let label = state.currentSectionLabel.lowercased()
        let rising = label == "chorus" && lastSectionLabel.lowercased() != "chorus"
        if rising && currentTime - lastTriggerTime >= retriggerCooldown {
            phaseStarted = currentTime
            lastTriggerTime = currentTime
        }

        // Envelope: fast rise to peakFraction, smooth decay to 1.0.
        let elapsed = currentTime - phaseStarted
        if elapsed >= 0 && elapsed < liftDuration {
            let norm = elapsed / liftDuration
            if norm < peakFraction {
                strength = norm / peakFraction
            } else {
                let fall = (norm - peakFraction) / (1 - peakFraction)
                // Smooth out the tail so the bloom doesn't cut.
                strength = (1 - fall) * (1 - fall)
            }
        } else {
            strength = 0
        }

        lastSectionLabel = state.currentSectionLabel
    }
}

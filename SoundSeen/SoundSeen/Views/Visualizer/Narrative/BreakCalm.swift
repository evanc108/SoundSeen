//
//  BreakCalm.swift
//  SoundSeen
//
//  Sustained vertical vignette during `break` and `outro` sections. Unlike
//  the other narrative layers, this one isn't a one-shot — it holds for
//  the entire section and decays when we exit. Reads as the scene
//  collapsing inward: calm, compressed, introspective.
//
//  Ramps in over ~0.8s so the transition into break doesn't cut, and
//  ramps out just as quickly on exit.
//

import Foundation
import Observation

@Observable
@MainActor
final class BreakCalm {
    /// 0 at rest, 1 at full vignette. Consumers darken top + bottom of
    /// the frame weighted by this value.
    private(set) var strength: Double = 0

    @ObservationIgnored private weak var state: VisualizerState?
    /// Per-tick ramp increment. Assuming ~60Hz ticks, 1/48 reaches full
    /// vignette in ~0.8s.
    private let rampPerTick: Double = 1.0 / 48.0

    init(state: VisualizerState) {
        self.state = state
    }

    func tick(prevTime: Double, currentTime: Double) {
        guard let state else { return }

        // Discontinuity: snap to whatever the new section demands.
        if currentTime < prevTime || (currentTime - prevTime) > 1.0 {
            strength = isCalmSection(state) ? 1 : 0
            return
        }

        let target: Double = isCalmSection(state) ? 1 : 0
        if strength < target {
            strength = min(target, strength + rampPerTick)
        } else if strength > target {
            strength = max(target, strength - rampPerTick)
        }
    }

    private func isCalmSection(_ state: VisualizerState) -> Bool {
        let label = state.currentSectionLabel.lowercased()
        return label == "break" || label == "outro"
    }
}

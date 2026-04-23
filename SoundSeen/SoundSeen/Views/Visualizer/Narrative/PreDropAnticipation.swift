//
//  PreDropAnticipation.swift
//  SoundSeen
//
//  Scripted anticipation rise during building passages. Ramps a letterbox
//  + palette desaturation as the section approaches its end, so the scene
//  collapses into cinematic tension before whatever comes next hits.
//
//  Trigger: `energyProfile == "building"` (usually bridges or the tail of
//  an intro) with `currentSectionProgress > 0.6`. The ramp peaks near the
//  end of the building section and decays quickly after the section flips.
//  DropChoreography handles the drop hit itself — this layer is the
//  *preamble*, not the release.
//

import Foundation
import Observation

@Observable
@MainActor
final class PreDropAnticipation {
    /// 0 at rest, 1 at peak anticipation. Drives letterbox bar height.
    private(set) var letterboxProgress: Double = 0
    /// 1.0 at rest, 0.85 at peak. Applied to the scene via `.saturation()`
    /// so the image desaturates as tension builds.
    private(set) var saturationScale: Double = 1.0

    @ObservationIgnored private weak var state: VisualizerState?
    /// Ramp start point within the building section. Before this, no effect.
    private let rampStart: Double = 0.60
    /// Ramp peak point within the building section. At/after this, full anticipation.
    private let rampPeak: Double = 0.95
    /// Deepest saturation drop at peak anticipation.
    private let maxSaturationDrop: Double = 0.15
    /// Per-frame decay applied when we're NOT anticipating — fast enough
    /// that the letterbox clears within ~1s of section change.
    private let decayPerTick: Double = 0.04

    init(state: VisualizerState) {
        self.state = state
    }

    func tick(prevTime: Double, currentTime: Double) {
        guard let state else { return }

        // Handle discontinuity / seek — snap to idle.
        if currentTime < prevTime || (currentTime - prevTime) > 1.0 {
            letterboxProgress = 0
            saturationScale = 1.0
            return
        }

        let isBuilding = state.currentSectionEnergyProfile.lowercased() == "building"
        let progress = state.currentSectionProgress

        if isBuilding && progress > rampStart {
            // Linear ramp rampStart..rampPeak → 0..1, smoothstepped.
            let raw = (progress - rampStart) / max(1e-6, rampPeak - rampStart)
            let t = max(0, min(1, raw))
            let eased = t * t * (3 - 2 * t)
            letterboxProgress = eased
            saturationScale = 1.0 - eased * maxSaturationDrop
        } else {
            // Decay back to neutral.
            letterboxProgress = max(0, letterboxProgress - decayPerTick)
            saturationScale = min(1, saturationScale + decayPerTick * 0.5)
        }
    }
}

//
//  GodRayVisualizer.swift
//  SoundSeen
//
//  Klsr-inspired cinematic god-rays layer. Volumetric light emanates from a
//  center point, driven by bass energy, snare/transient bloom, and slow
//  section-build envelopes. The emotional design principles from
//  docs/visualizer/god-rays-plan.md govern every parameter choice.
//
//  Key couplings:
//    - Low-end (bassEnergySmoothed) drives brightness — hi-hats don't pop.
//    - Snare/transient events drive brief bloom pulses (~300ms ringout).
//    - Section "building" profiles ramp intensity over 2-3s for cinematic effect.
//    - Valence shifts beam shape (tight/triumphant vs diffuse/melancholic).
//    - Arousal shifts dust mote density.
//    - Reduce Motion dims and slows, but doesn't flatten emotion (Principle 6).
//
//  CRITICAL: Shader argument order must match GodRays.metal exactly.
//  Order: lightCenter, time, bassEnergy, beatPulse, snareBloom, valence, arousal,
//         hueDrift, sectionBuild, intensityScale, paletteMix, paletteWarm, paletteCool
//

import SwiftUI
import QuartzCore

struct GodRayVisualizer: View {
    let visualizer: VisualizerState
    let scheduler: BeatScheduler
    let paletteColor: Color
    let paletteSecondary: Color
    let intensity: Double

    // MARK: - State

    /// Time of last snare bloom trigger. Bloom decays from this point.
    @State private var lastBloomTriggerTime: TimeInterval = -10
    /// Last flux spike generation we processed — prevents double-fire.
    @State private var lastFluxGen: Int = 0
    /// Whether we've subscribed to the beat scheduler yet.
    @State private var didSubscribe: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Light center: slightly above center (0.5, 0.38) for cinematic framing.
    private let lightCenter = CGPoint(x: 0.5, y: 0.38)

    // Snare bloom decay time constant (~300ms to reach near-zero).
    private let bloomDecayTime: Double = 0.3

    // Reduce Motion intensity cap (Principle 6: preserve emotion, just gentler).
    private let reduceMotionCap: Double = 0.3

    var body: some View {
        TimelineView(.animation) { _ in
            let now = CACurrentMediaTime()

            // Compute snare bloom envelope based on time since last trigger.
            // Exponential decay: bloom = exp(-timeSinceTrigger / decayTime)
            let timeSinceTrigger = now - lastBloomTriggerTime
            let snareBloom = timeSinceTrigger < 0 ? 0 : Float(exp(-timeSinceTrigger / bloomDecayTime))

            // Read visualizer state.
            let bass = Float(visualizer.bassEnergySmoothed)
            let beat = Float(visualizer.beatPulse)
            let valence = Float(visualizer.smoothedValence)
            let arousal = Float(visualizer.smoothedArousal)
            let hue = Float(visualizer.currentHue)
            let sectionBuild = Float(visualizer.sectionBuildEnvelope)

            // Collapse biome weights to warm-vs-cool scalar.
            // Warm: euphoric + intense (high arousal)
            // Cool: serene + melancholic (low arousal)
            let weights = visualizer.biomeWeights
            let warmWeight = weights.euphoric + weights.intense
            let coolWeight = weights.serene + weights.melancholic
            let paletteMix = Float((warmWeight - coolWeight + 1.0) / 2.0) // normalize to 0-1

            // Compute effective intensity with reduce-motion clamping.
            let effectiveIntensity: Float
            let effectiveTime: Float
            if reduceMotion {
                effectiveIntensity = Float(min(intensity, reduceMotionCap))
                effectiveTime = 0 // Freeze dust motes
            } else {
                effectiveIntensity = Float(intensity)
                // Wrap time to avoid precision loss in shader after long playback.
                effectiveTime = Float(now.truncatingRemainder(dividingBy: 3600.0))
            }

            // Build placeholder light source: a soft radial gradient on black.
            // The shader reads this as its input layer.
            placeholderLightSource
                .layerEffect(
                    ShaderLibrary.default.godRays(
                        .float2(Float(lightCenter.x), Float(lightCenter.y)),
                        .float(effectiveTime),
                        .float(bass),
                        .float(beat),
                        .float(snareBloom),
                        .float(valence),
                        .float(arousal),
                        .float(hue),
                        .float(sectionBuild),
                        .float(effectiveIntensity),
                        .float(paletteMix),
                        .color(paletteColor),
                        .color(paletteSecondary)
                    ),
                    maxSampleOffset: CGSize(width: 400, height: 400)
                )
        }
        .onChange(of: visualizer.fluxSpikeGeneration) { _, newValue in
            // Flux spike = snare/transient event. Trigger bloom.
            guard newValue != lastFluxGen else { return }
            lastFluxGen = newValue
            triggerBloom()
        }
        .onAppear {
            subscribeToBeats()
        }
        .allowsHitTesting(false)
    }

    // MARK: - Private

    /// The placeholder "light source" view the shader operates on.
    /// A soft radial gradient on black, centered slightly above middle.
    /// Cheap to rasterize, keeps shader texture-cache warm.
    @ViewBuilder
    private var placeholderLightSource: some View {
        Color.black
            .overlay(
                RadialGradient(
                    colors: [
                        Color.white.opacity(0.15),
                        Color.white.opacity(0.05),
                        Color.clear
                    ],
                    center: UnitPoint(x: lightCenter.x, y: lightCenter.y),
                    startRadius: 0,
                    endRadius: 300
                )
            )
            .ignoresSafeArea()
    }

    /// Subscribe to beat scheduler for high-sharpness beats (snare proxy).
    private func subscribeToBeats() {
        guard !didSubscribe else { return }
        didSubscribe = true

        scheduler.subscribe { beat in
            // High-sharpness beats are likely snares/percussive hits.
            // Threshold 0.6 tuned to catch snares without hi-hat noise.
            if beat.sharpness > 0.6 {
                triggerBloom()
            }
        }
    }

    /// Trigger snare bloom by recording current time.
    private func triggerBloom() {
        lastBloomTriggerTime = CACurrentMediaTime()
    }
}

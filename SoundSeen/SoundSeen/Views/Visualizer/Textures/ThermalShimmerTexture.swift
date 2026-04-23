//
//  ThermalShimmerTexture.swift
//  SoundSeen
//
//  UV-warp overlay using a Metal distortion shader (.distortionEffect
//  modifier). Applied to the entire scene behind it by placing this
//  texture on top in the ZStack with .distortionEffect on its parent
//  wrapping — but SwiftUI's .distortionEffect doesn't reach back over
//  siblings, so we instead render a transparent overlay that receives
//  no background to distort.
//
//  Practical approach: the distortion is applied to a captured snapshot
//  provided by the caller. In our compose pipeline, VisualizerRoot wraps
//  all-voices-below in a container, then applies this modifier to the
//  container when the shimmer strength is non-zero. See VisualizerRoot
//  for the wiring — this file exposes the strength computation + shader
//  uniform.
//

import SwiftUI

enum ThermalShimmer {
    /// Effective strength in pixels, combining dialect baseline + flux
    /// + drop-choreography ramp. Zero when the texture is disabled.
    static func strength(
        state: VisualizerState,
        dialect: SectionDialect,
        choreography: DropChoreography
    ) -> Double {
        guard dialect.enabledTextures.contains(.thermalShimmer) else { return 0 }

        // Section floor: bridge gets a subtle constant shimmer; chorus gets
        // a small flux-proportional component; drop ramps through phases.
        let isBridge = dialect.rotationDegrees > 5  // bridge tilts; uniqueness signal
        let base: Double
        if isBridge {
            base = 3.0
        } else {
            base = 0
        }

        let fluxComponent = state.currentFlux * 2.8

        // DropChoreography: crest ramps 0→12, release holds 12, settle decays.
        let dropComponent: Double
        switch choreography.phase {
        case .idle:   dropComponent = 0
        case .crest:  dropComponent = choreography.phaseProgress * 12.0
        case .flash:  dropComponent = 12.0
        case .settle: dropComponent = (1 - choreography.phaseProgress) * 12.0
        }

        return base + fluxComponent + dropComponent
    }

    /// Shader uniform factory — call after computing strength. Returns the
    /// Shader object ready to pass to `.distortionEffect`.
    static func shader(strength: Double, now: Date) -> Shader {
        let t = Float(now.timeIntervalSinceReferenceDate)
        return ShaderLibrary.thermalShimmer(
            .float(t),
            .float(Float(strength))
        )
    }
}

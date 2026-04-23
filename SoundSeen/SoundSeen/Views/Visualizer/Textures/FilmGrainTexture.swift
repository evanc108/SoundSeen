//
//  FilmGrainTexture.swift
//  SoundSeen
//
//  Full-screen noise overlay using a Metal color shader. Round 2:
//  - Flux coupling raised from ×0.10 to ×0.35 — flux was being under-
//    represented; now spectral disorder is visibly legible.
//  - Low-valence passages (V < 0.3) receive a cool-blue tint weighted by
//    (0.5 − V) · 2, clamped. Anxious / sad passages feel uncanny; neutral+
//    valence stays colorless, preserving noise-as-pure-signal.
//

import SwiftUI

struct FilmGrainTexture: View {
    @Bindable var state: VisualizerState
    let dialect: SectionDialect
    let now: Date

    var body: some View {
        if dialect.enabledTextures.contains(.filmGrain) {
            // Flux catches spectral-change events; ZCR catches sustained noise
            // (sibilance, snare, hat-heavy passages). Blending both gives the
            // grain a continuous "noisiness" read in addition to the spike read.
            let grain = max(
                dialect.grainOpacity,
                min(0.35, dialect.grainOpacity
                    + state.currentFlux * 0.25
                    + state.currentZCR * 0.20)
            )
            if grain > 0.005 {
                // Valence-driven tint strength. At V ≥ 0.5 the tint is zero
                // (colorless grain). Below 0.3 it fades in to reach 0.40
                // at V=0, so the lowest-valence moments feel cold.
                let val = state.smoothedValence
                let tintStrength = max(0.0, min(0.40, (0.5 - val) * 0.8))

                Rectangle()
                    .fill(Color.white.opacity(grain * 0.6))
                    .colorEffect(
                        ShaderLibrary.filmGrain(
                            .float(Float(now.timeIntervalSinceReferenceDate)),
                            .float(Float(grain * 2.6)),
                            .float(Float(tintStrength))
                        )
                    )
                    .blendMode(.overlay)
                    .allowsHitTesting(false)
            }
        }
    }
}

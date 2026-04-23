//
//  BiomeArchetype.swift
//  SoundSeen
//
//  Biome archetypes are the scene's protagonist forms — one per emotion
//  quadrant. Unlike the texture layers that shout the same shape in every
//  mood with a different tint, each archetype is a *distinct silhouette*
//  that only comes alive when its biome weight rises. Cross-fade between
//  archetypes is automatic via weight-scaled alpha; no state machine.
//
//  BiomeArchetypeLayer is the compositor. Individual archetypes early-out
//  when their biome weight is below `Archetype.minWeight` so low-weighted
//  archetypes don't eat frame time or draw unreadable ghosts.
//

import SwiftUI

enum Archetype {
    /// Below this biome weight, an archetype is functionally invisible and
    /// skips all work. Matches the early-out threshold already used by
    /// QuadrantBiomeLayer per the existing biome pattern.
    static let minWeight: Double = 0.04
}

/// Compositor that renders every archetype weighted by its biome share.
/// Lives inside the TextureBundle so it shares the scene transform and
/// thermal shimmer with the rest of the scene.
struct BiomeArchetypeLayer: View {
    @Bindable var state: VisualizerState
    let scheme: EmotionScheme
    let dialect: SectionDialect
    let now: Date

    var body: some View {
        ZStack {
            // EuphoricBloom removed — god rays are the scene protagonist.
            // The bloom's geometric petals competed with atmospheric light.
            SereneOrbArchetype(
                state: state,
                weight: state.biomeWeights.serene,
                scheme: scheme,
                dialect: dialect,
                now: now
            )
            IntenseLightningArchetype(
                state: state,
                weight: state.biomeWeights.intense,
                scheme: scheme,
                dialect: dialect,
                now: now
            )
            MelancholicDropletArchetype(
                state: state,
                weight: state.biomeWeights.melancholic,
                scheme: scheme,
                dialect: dialect,
                now: now
            )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Shared HSB blend helper

/// Shortest-path HSB blend used by archetypes to tint toward accent/key
/// colors. Lives here so individual archetype files don't each redefine
/// the same helper.
func archetypeBlend(_ a: HSB, _ b: HSB, _ t: Double) -> HSB {
    var dh = b.h - a.h
    if dh > 0.5 { dh -= 1 }
    if dh < -0.5 { dh += 1 }
    var h = a.h + dh * t
    h = h.truncatingRemainder(dividingBy: 1); if h < 0 { h += 1 }
    return HSB(
        h: h,
        s: a.s + (b.s - a.s) * t,
        b: a.b + (b.b - a.b) * t
    )
}

//
//  BiomeWeights.swift
//  SoundSeen
//
//  Four-quadrant emotion blend. The smoothed (valence, arousal) coordinate
//  is projected onto four quadrant centers and turned into a probability
//  vector via softmax, so every biome layer renders at its own weight and
//  the scene is always a blend — no hard swap when V/A crosses a boundary.
//

import Foundation

enum Biome: Int, CaseIterable, Sendable {
    case euphoric    // high V, high A
    case serene      // high V, low A
    case intense     // low V, high A
    case melancholic // low V, low A

    /// (valence, arousal) center on the unit square.
    var center: (v: Double, a: Double) {
        switch self {
        case .euphoric:    return (0.75, 0.75)
        case .serene:      return (0.75, 0.25)
        case .intense:     return (0.25, 0.75)
        case .melancholic: return (0.25, 0.25)
        }
    }
}

struct BiomeWeights: Sendable, Equatable {
    var euphoric: Double = 0
    var serene: Double = 1
    var intense: Double = 0
    var melancholic: Double = 0

    subscript(biome: Biome) -> Double {
        switch biome {
        case .euphoric:    return euphoric
        case .serene:      return serene
        case .intense:     return intense
        case .melancholic: return melancholic
        }
    }

    var dominant: Biome {
        var best = Biome.serene
        var bestWeight = self[best]
        for biome in Biome.allCases where self[biome] > bestWeight {
            best = biome
            bestWeight = self[biome]
        }
        return best
    }

    /// Softmax over negative squared distance from (v, a) to each quadrant
    /// center. τ=0.25 gives a smooth ~1s-perceived crossfade at typical
    /// EMA rates — small enough that one biome still clearly dominates near
    /// a quadrant center, large enough that boundaries don't flash.
    static func compute(valence v: Double, arousal a: Double, tau: Double = 0.25) -> BiomeWeights {
        var logits: [Double] = []
        logits.reserveCapacity(Biome.allCases.count)
        for biome in Biome.allCases {
            let c = biome.center
            let dv = v - c.v
            let da = a - c.a
            let d2 = dv * dv + da * da
            logits.append(-d2 / tau)
        }
        let maxLogit = logits.max() ?? 0
        var exps = logits.map { exp($0 - maxLogit) }
        let sum = exps.reduce(0, +)
        if sum > 0 {
            for i in exps.indices { exps[i] /= sum }
        }
        return BiomeWeights(
            euphoric: exps[Biome.euphoric.rawValue],
            serene: exps[Biome.serene.rawValue],
            intense: exps[Biome.intense.rawValue],
            melancholic: exps[Biome.melancholic.rawValue]
        )
    }
}

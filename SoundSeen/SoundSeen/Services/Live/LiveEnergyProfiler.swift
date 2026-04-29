//
//  LiveEnergyProfiler.swift
//  SoundSeen
//
//  Rolling-window classifier that maps recent RMS + flux into one of the
//  six energy-profile labels that the offline pipeline.structure.py
//  assigns to sections. In live mode there's no section analysis, so this
//  classifier fills the `currentSectionEnergyProfile` slot so the existing
//  dialect/biome resolver keeps working.
//
//  Update cadence: 2×/s (every ~22 frames @ 43fps). 1s hysteresis per
//  label change — without it the label flickers on every bar boundary.
//

import Foundation

/// Nonisolated — runs on LiveAudioEngine's serial DSP queue.
nonisolated final class LiveEnergyProfiler {
    enum Profile: String, CaseIterable {
        case building
        case intense
        case high
        case moderate
        case minimal
        case fading

        var backendLabel: String { rawValue }
    }

    /// 5s history @ 43fps ≈ 215 frames — enough to see a crescendo / drop.
    private let historyFrames = 215
    /// Recompute every 22 frames (~0.5s) to keep UI snappy without spamming.
    private let recomputeEvery = 22
    /// Minimum time a label must have been "winning" before we swap to it.
    private let hysteresisSeconds: Double = 1.0

    private var energyHistory: [Double] = []
    private var fluxHistory: [Double] = []
    private var framesSinceRecompute = 0

    private(set) var profile: Profile = .moderate
    private var profileSince: TimeInterval = 0
    private var candidateProfile: Profile = .moderate
    private var candidateSince: TimeInterval = 0

    /// Called per frame with the normalized energy + flux. Returns the
    /// current profile (may or may not have changed).
    @discardableResult
    func process(energy: Double, flux: Double, now: TimeInterval) -> Profile {
        energyHistory.append(energy)
        fluxHistory.append(flux)
        if energyHistory.count > historyFrames {
            energyHistory.removeFirst(energyHistory.count - historyFrames)
            fluxHistory.removeFirst(fluxHistory.count - historyFrames)
        }

        framesSinceRecompute += 1
        if framesSinceRecompute < recomputeEvery { return profile }
        framesSinceRecompute = 0

        guard energyHistory.count >= 40 else { return profile }

        let candidate = classify()
        if candidate == profile {
            candidateProfile = profile
            candidateSince = now
            return profile
        }
        if candidate != candidateProfile {
            candidateProfile = candidate
            candidateSince = now
            return profile
        }
        // Same candidate as before — has it persisted long enough to swap?
        if now - candidateSince >= hysteresisSeconds {
            profile = candidate
            profileSince = now
        }
        return profile
    }

    func reset() {
        energyHistory.removeAll(keepingCapacity: true)
        fluxHistory.removeAll(keepingCapacity: true)
        framesSinceRecompute = 0
        profile = .moderate
        candidateProfile = .moderate
    }

    // MARK: - Classification

    private func classify() -> Profile {
        let n = energyHistory.count
        // Energy slope: last 2s mean vs preceding 2s mean.
        let halfEnd = n
        let halfStart = n / 2
        let prevStart = 0
        let prevEnd = n / 2

        let recentMean = slice(energyHistory, from: halfStart, to: halfEnd).mean
        let priorMean = slice(energyHistory, from: prevStart, to: prevEnd).mean
        let energyDelta = recentMean - priorMean

        let fluxMean = fluxHistory.mean
        let energyMean = energyHistory.mean

        // Rule table mirrors pipeline/structure.py:37-48. Order matters —
        // "building"/"fading" beat the static levels when the slope is strong.
        if energyDelta > 0.25 { return .building }
        if energyDelta < -0.25 { return .fading }
        if energyMean > 0.75 && fluxMean > 0.6 { return .intense }
        if energyMean > 0.55 { return .high }
        if energyMean < 0.15 { return .minimal }
        return .moderate
    }

    private func slice(_ a: [Double], from: Int, to: Int) -> [Double] {
        guard from < to, to <= a.count else { return [] }
        return Array(a[from..<to])
    }
}

private extension Array where Element == Double {
    var mean: Double {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Double(count)
    }
}

//
//  InkBleedTexture.swift
//  SoundSeen
//
//  The melodic body of the scene. Round 2 makes the placement and shape
//  dynamic:
//
//  - Seed u is driven by currentHue: the key literally pans the bleed
//    horizontally. Listen-and-watch: the ink drifts left/right as the
//    song's key modulates.
//  - Seed v is driven by valence+arousal: positive valence rises, low
//    arousal settles low. Happiness lifts; exhaustion sinks.
//  - Blob aspect ratio is driven by harmonic_ratio: pitched mids form
//    round, stable bleeds; noisy mids smear sideways into wide streaks.
//  - Color pulls toward currentHue when the music is tonal.
//
//  Onsets with slow attack still spawn additional bleeds (sustained-note
//  character); sharp attacks become Ember strikes instead.
//

import SwiftUI

private let bleedLifetime: Double = 2.8
private let bleedPoolCap: Int = 20

struct InkBleedTexture: View {
    @Bindable var state: VisualizerState
    let scheme: EmotionScheme
    let dialect: SectionDialect
    let now: Date

    @State private var bleeds: [Bleed] = []
    @State private var lastAmbientEmit: Double = 0
    @State private var lastOnsetObserved: Int = -1

    var body: some View {
        if dialect.enabledTextures.contains(.inkBleed) {
            Canvas { ctx, size in
                let t = now.timeIntervalSinceReferenceDate
                maybeEmitAmbient(at: t, size: size)
                reap(at: t)

                for b in bleeds {
                    let age = t - b.birth
                    guard age >= 0, age < bleedLifetime else { continue }
                    draw(ctx: &ctx, bleed: b, age: age, size: size)
                }
            }
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
            .onChange(of: state.onsetGeneration) { _, newGen in
                if newGen != lastOnsetObserved {
                    lastOnsetObserved = newGen
                    if let onset = state.lastOnset,
                       onset.sharpness < 0.50,
                       state.currentHarmonicRatio > 0.35 {
                        emitOnsetSeeded(onset: onset)
                    }
                }
            }
        }
    }

    // MARK: - Emission

    private func maybeEmitAmbient(at t: Double, size: CGSize) {
        let bands = state.currentBands
        let masks = dialect.bandMask
        let band2: Double = bands.count > 2 ? bands[2] * masks[2] : 0
        let band3: Double = bands.count > 3 ? bands[3] * masks[3] : 0
        let band4: Double = bands.count > 4 ? bands[4] * masks[4] * 0.6 : 0
        let midEnergy: Double = (band2 + band3 + band4) / 3.0
        let harm: Double = state.currentHarmonicRatio
        let gate: Double = midEnergy * harm
        guard gate > 0.15 else { return }

        // Interval halves in Round 2 — pool is smaller, so match the
        // birth rate. 1.1s min, 0.30s peak.
        let interval = 1.1 - 0.80 * gate
        guard t - lastAmbientEmit >= interval else { return }
        lastAmbientEmit = t

        // u: the chromatic key literally pans the bleed left/right.
        // H ∈ [0, 1] → u offset in ±0.30 around center.
        let uCenter = 0.5 + (state.currentHue - 0.5) * 0.6
        let uLo = dialect.activeUBounds.lowerBound
        let uHi = dialect.activeUBounds.upperBound
        let u = max(uLo + 0.05, min(uHi - 0.05, uCenter))

        // v: valence lifts the bleed, low arousal settles it.
        let val = state.smoothedValence
        let ar = state.smoothedArousal
        let vCenter = 0.5 - val * 0.25 + (1 - ar) * 0.10
        let vLo = dialect.activeVBounds.lowerBound + 0.05
        let vHi = dialect.activeVBounds.upperBound - 0.05
        let v = max(vLo, min(vHi, vCenter))

        emit(at: CGPoint(x: u * size.width, y: v * size.height),
             size: size,
             intensity: midEnergy,
             isOnset: false)
    }

    private func emitOnsetSeeded(onset: OnsetEvent) {
        let seed = onset.time * 1.6180339887
        let u = dialect.activeUBounds.lowerBound + frac(seed * 3.1) * (dialect.activeUBounds.upperBound - dialect.activeUBounds.lowerBound)
        let vRange = dialect.activeVBounds
        let centerV = (vRange.lowerBound + vRange.upperBound) / 2
        let v = centerV + (frac(seed * 5.7) - 0.5) * 0.18 * (vRange.upperBound - vRange.lowerBound)
        bleeds.append(Bleed(
            unitU: u,
            unitV: v,
            birth: now.timeIntervalSinceReferenceDate,
            intensity: max(0.3, onset.intensity),
            hueSlot: .secondary,
            aspect: currentAspect()
        ))
        capPool()
    }

    private func emit(at pos: CGPoint, size: CGSize, intensity: Double, isOnset: Bool) {
        bleeds.append(Bleed(
            unitU: Double(pos.x / max(size.width, 1)),
            unitV: Double(pos.y / max(size.height, 1)),
            birth: now.timeIntervalSinceReferenceDate,
            intensity: intensity,
            hueSlot: .primary,
            aspect: currentAspect()
        ))
        capPool()
    }

    /// Aspect ratio driven by harmonic_ratio: round when harmonic (HR=1)
    /// → aspect ~1.0; wide and smeary when noisy (HR=0) → aspect ~2.2.
    private func currentAspect() -> Double {
        let hr = state.currentHarmonicRatio
        return 1.0 + 1.2 * (1.0 - hr)
    }

    private func capPool() {
        if bleeds.count > bleedPoolCap { bleeds.removeFirst(bleeds.count - bleedPoolCap) }
    }

    private func reap(at t: Double) {
        bleeds.removeAll { t - $0.birth >= bleedLifetime }
    }

    // MARK: - Draw

    private func draw(ctx: inout GraphicsContext, bleed: Bleed, age: Double, size: CGSize) {
        let norm = age / bleedLifetime
        let minDim = min(size.width, size.height)
        let r0 = minDim * 0.10
        let r1 = minDim * (0.45 + 0.25 * bleed.intensity)
        let radius = r0 + (r1 - r0) * CGFloat(easeOut(norm))

        let alpha = sin(norm * .pi) * 0.7 * bleed.intensity

        let cx = CGFloat(bleed.unitU) * size.width
        let cy = CGFloat(bleed.unitV) * size.height

        // Color: primary for ambient, secondary for onset-driven. Pull the
        // core hue toward the song's key when CS is strong — melodic body
        // takes the key's color.
        let cs = state.currentChromaStrength
        let keyHSB = HSB(h: state.currentHue, s: 0.7, b: 0.95)
        let baseCore = bleed.hueSlot == .secondary ? scheme.secondary : scheme.primary
        let core = blendHSB(baseCore, keyHSB, min(1.0, cs * 0.5))
        let edge = scheme.atmosphere

        // Elliptical bleed — round when harmonic, wide when noisy.
        let rx = radius * CGFloat(bleed.aspect)
        let ry = radius

        // Spectral contrast sharpens or softens the bleed edges. Smooth
        // spectrum (low contrast) → more blur → melted/clean boundary;
        // contrasty/peaky spectrum → less blur → torn/harder boundary.
        let contrastK = 1.25 - 0.45 * state.currentSpectralContrast
        var bleedCtx = ctx
        bleedCtx.addFilter(.blur(radius: (28 + CGFloat(bleed.intensity) * 14) * CGFloat(contrastK)))

        let rect = CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
        bleedCtx.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: [
                    core.color(opacity: alpha),
                    edge.color(opacity: alpha * 0.4),
                    core.color(opacity: 0)
                ]),
                center: CGPoint(x: cx, y: cy),
                startRadius: 0,
                endRadius: max(rx, ry)
            )
        )
    }

    // MARK: - Helpers

    private enum HueSlot { case primary, secondary }

    private struct Bleed {
        let unitU: Double
        let unitV: Double
        let birth: Double
        let intensity: Double
        let hueSlot: HueSlot
        let aspect: Double
    }

    private func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 2.4) }
    private func frac(_ x: Double) -> Double { x - floor(x) }

    private func blendHSB(_ a: HSB, _ b: HSB, _ t: Double) -> HSB {
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
}

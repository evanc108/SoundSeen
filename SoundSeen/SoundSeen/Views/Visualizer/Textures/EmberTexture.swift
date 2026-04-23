//
//  EmberTexture.swift
//  SoundSeen
//
//  Hot particulate for percussive attacks. Small bright sprites rise from
//  a seed point, fade over ~1s. In Round 2 the seed position is
//  centroid-aware — bassy onsets erupt near the floor, bright onsets
//  flash near the sky. Birth hue pulls toward the song's chromatic key
//  when the music is tonal (CS > 0.4), so a pitched attack ignites in
//  the key's color, and a noisy attack ignites in the emotional accent.
//
//  Also acts as the drop's escape-particle source: when allowOffscreen is
//  true, ember lifetimes extend and velocities push past the viewport
//  edge so they leave the scene rather than falling back.
//

import SwiftUI

private let emberLifetime: Double = 1.15
private let emberLifetimeDrop: Double = 1.80
private let emberPoolCap: Int = 120

struct EmberTexture: View {
    @Bindable var state: VisualizerState
    @Bindable var choreography: DropChoreography
    let scheme: EmotionScheme
    let dialect: SectionDialect
    let now: Date

    @State private var embers: [Ember] = []
    @State private var lastOnsetObserved: Int = -1
    @State private var lastReleaseObserved: Int = -1

    var body: some View {
        if dialect.enabledTextures.contains(.ember) {
            Canvas { ctx, size in
                let t = now.timeIntervalSinceReferenceDate
                reap(at: t)
                for e in embers {
                    drawEmber(ctx: &ctx, ember: e, t: t, size: size)
                }
            }
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
            .onChange(of: state.onsetGeneration) { _, newGen in
                if newGen != lastOnsetObserved {
                    lastOnsetObserved = newGen
                    if let onset = state.lastOnset, onset.sharpness >= 0.45 {
                        emitForOnset(onset: onset)
                    }
                }
            }
            // NOTE: Round 2 — downbeat emission removed. GlowPulse owns
            // the rhythmic layer; Ember is onsets-only.
            .onChange(of: choreography.releaseGeneration) { _, newGen in
                if newGen != lastReleaseObserved {
                    lastReleaseObserved = newGen
                    emitEscapeBurst()
                }
            }
        }
    }

    private func emitEscapeBurst() {
        let origin = dialect.compositionOrigin
        let t = now.timeIntervalSinceReferenceDate
        let count = 90
        for i in 0..<count {
            let angle = Double(i) / Double(count) * 2 * .pi + Double.random(in: -0.18...0.18)
            let speed = 280 + Double.random(in: 0...380)
            embers.append(Ember(
                unitU: origin.x,
                unitV: origin.y,
                vx: cos(angle) * speed,
                vy: sin(angle) * speed - 60,
                birth: t,
                life: emberLifetimeDrop,
                intensity: 0.95,
                birthHue: scheme.accent
            ))
        }
        capPool()
    }

    // MARK: - Emission

    private func emitForOnset(onset: OnsetEvent) {
        let seed = onset.time * 1.6180339887
        let uLo = dialect.activeUBounds.lowerBound
        let uHi = dialect.activeUBounds.upperBound
        let vLo = dialect.activeVBounds.lowerBound
        let vHi = dialect.activeVBounds.upperBound

        // u: primarily centroid-biased (bright = right, dark = left) with
        // jitter so repeated onsets at the same spectral brightness don't
        // stack at the same u. Clamped to active bounds.
        let cn = state.currentCentroidNormalized
        let uCentroid = uLo + cn * (uHi - uLo)
        let u = max(uLo, min(uHi, uCentroid + (frac(seed * 3.1) - 0.5) * 0.3))

        // v: spectral-brightness-driven. Low CN → near FLOOR, high CN → near
        // SKY. v = 0.85 − 0.7·CN gives a satisfying spread from ~0.85 (bass)
        // to ~0.15 (treble). Then clamp and add small jitter.
        let vSpectral = 0.85 - 0.7 * cn
        let vJitter = (frac(seed * 5.7) - 0.5) * 0.08
        let v = max(vLo, min(vHi, vSpectral + vJitter))

        // Birth hue: pitched attack ignites in the song's key; noisy attack
        // ignites in the emotional accent. The deaf user reading a melodic
        // line sees its key color; a percussive line sees the song's punch.
        let cs = state.currentChromaStrength
        let birthHue: HSB = cs > 0.4
            ? HSB(h: state.currentHue, s: 0.85, b: 1.0)
            : scheme.accent

        // Sharper attacks spawn more particles, with a slightly narrower
        // radial spread so the burst reads as a *strike* not a puff.
        let count = 6 + Int(onset.sharpness * 12)
        for i in 0..<count {
            let angle = Double(i) / Double(count) * 2 * .pi + frac(seed * 7.3) * .pi
            let speed = 120 + Double.random(in: 0...180) * onset.sharpness
            let vx = cos(angle) * speed
            let vy = sin(angle) * speed - 60
            embers.append(Ember(
                unitU: u,
                unitV: v,
                vx: vx,
                vy: vy,
                birth: now.timeIntervalSinceReferenceDate,
                life: dialect.allowOffscreen ? emberLifetimeDrop : emberLifetime,
                intensity: max(0.5, onset.intensity),
                birthHue: birthHue
            ))
        }
        capPool()
    }

    private func capPool() {
        if embers.count > emberPoolCap {
            embers.removeFirst(embers.count - emberPoolCap)
        }
    }

    private func reap(at t: Double) {
        embers.removeAll { t - $0.birth >= $0.life }
    }

    // MARK: - Draw

    private func drawEmber(
        ctx: inout GraphicsContext,
        ember: Ember,
        t: Double,
        size: CGSize
    ) {
        let age = t - ember.birth
        let norm = age / ember.life
        guard norm < 1 else { return }

        let gravity: CGFloat = 260
        let drag: Double = pow(0.88, age * 10)
        let vx = ember.vx * drag
        let vy = ember.vy * drag + Double(gravity) * age

        let x0 = ember.unitU * size.width
        let y0 = ember.unitV * size.height

        let x = x0 + vx * age
        let y = y0 + vy * age

        if !dialect.allowOffscreen {
            guard x >= -40, x <= size.width + 40,
                  y >= -40, y <= size.height + 40 else { return }
        }

        // Alpha envelope: quick rise to peak, decay to death. Round-2 cap
        // at 0.75 (was 1.0) to de-emphasize the sparkle layer.
        let peak = 0.6
        let alphaCurve: Double
        if norm < peak {
            alphaCurve = norm / peak
        } else {
            alphaCurve = 1 - (norm - peak) / (1 - peak)
        }
        let alpha = alphaCurve * ember.intensity * 0.75

        // Hue decays from birth hue → atmosphere. Reads as heat cooling.
        let color = blendHSB(ember.birthHue, scheme.atmosphere, norm)

        // Non-chorus sections get slightly smaller embers so they don't
        // steal visual weight from the softer volumetric textures.
        let sizeScale: CGFloat = dialect.mirrorX ? 1.0 : 0.7
        let radius: CGFloat = (2.2 + 3.2 * CGFloat(ember.intensity) * (1 - CGFloat(norm) * 0.6)) * sizeScale

        let rect = CGRect(x: x - Double(radius), y: y - Double(radius),
                          width: Double(radius * 2), height: Double(radius * 2))
        let haloRect = CGRect(x: x - Double(radius) * 3, y: y - Double(radius) * 3,
                              width: Double(radius * 6), height: Double(radius * 6))

        var bloomCtx = ctx
        bloomCtx.addFilter(.blur(radius: 8))
        bloomCtx.fill(Path(ellipseIn: haloRect),
                      with: .color(color.color(opacity: alpha * 0.25)))

        ctx.fill(Path(ellipseIn: rect),
                 with: .color(color.color(opacity: alpha)))
    }

    // MARK: - Helpers

    private struct Ember {
        let unitU: Double
        let unitV: Double
        let vx: Double
        let vy: Double
        let birth: Double
        let life: Double
        let intensity: Double
        let birthHue: HSB
    }

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

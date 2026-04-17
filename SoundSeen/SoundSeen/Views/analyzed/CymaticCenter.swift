//
//  CymaticCenter.swift
//  SoundSeen
//
//  The hero element at the center of the analyzed player. A harmonic
//  standing-wave pattern whose silhouette r(θ) is a superposition of
//  cos(k·θ) terms weighted by the current frequency spectrum:
//
//    r(θ) = R · (1 + Σ_k  A_k · bands[k] · cos((k+1)·θ + φ_k(t)))
//
//  Each of the 8 bands contributes a harmonic at a different angular
//  frequency, so the shape literally morphs to the audio: bass pushes
//  the low modes (egg, peanut), treble rides on the high modes (fine
//  scalloping). Three concentric layers at slightly different phases
//  create interference bands reminiscent of Chladni cymatics.
//
//  This replaces both KickPulseOrb (kick-driven scale pulse) and
//  BeatRingLayer (per-beat radiating rings): the cymatic field is
//  the only central element and it already breathes with beats via
//  beatPulse + scheduler-driven amplitude boost.
//

import SwiftUI

struct CymaticCenter: View {
    let visualizer: VisualizerState
    let scheduler: BeatScheduler
    let paletteColor: Color
    let paletteSecondary: Color

    /// Pulses to 1 on every beat and decays exponentially. Multiplicatively
    /// amplifies the wave amplitudes so the pattern "rings" with each hit.
    @State private var beatBoost: Double = 0
    @State private var beatBoostTimer: Task<Void, Never>? = nil

    private let layerCount = 3
    private let samplesPerLayer = 220

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let bands = visualizer.currentBands
            let pulse = max(0, min(1, visualizer.beatPulse))
            let arousal = max(0, min(1, visualizer.smoothedArousal))

            Canvas { ctx, size in
                let side = min(size.width, size.height)
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                // Whole shape thumps on beats — bass-scaled scale pulse that
                // rides on top of the harmonic deformation.
                let breath = 1.0 + 0.18 * pulse + 0.22 * beatBoost
                let baseRadius = Double(side) * 0.33 * breath
                // Rotation: considerably faster, arousal accelerates further.
                let rotation = t * (0.12 + arousal * 0.40)
                // Beats ring the amplitudes much harder now.
                let totalBoost = pulse * 0.55 + beatBoost * 1.2

                // Three concentric harmonic curves at slightly offset phases —
                // the small phase offset between layers creates interference
                // bands that read as cymatic nodes.
                for layer in 0..<layerCount {
                    let layerT = Double(layer)
                    let phaseOffset = layerT * 0.45
                    let scale = 1.0 - layerT * 0.11

                    let path = harmonicPath(
                        center: center,
                        baseRadius: baseRadius * scale,
                        bands: bands,
                        time: t + phaseOffset,
                        rotation: rotation,
                        boost: totalBoost,
                        samples: samplesPerLayer
                    )

                    // Inner layer: translucent fill that lights up hard on
                    // every beat — gives the "dish" a body and makes each
                    // beat read as a full-shape luminance flash.
                    if layer == layerCount - 1 {
                        ctx.fill(
                            path,
                            with: .color(paletteSecondary.opacity(0.22 + 0.45 * pulse + 0.25 * beatBoost))
                        )
                    }

                    // Stroke: primary layer crisp + bright, deeper layers soft.
                    // Line widths swell on beats so the outline feels impact.
                    let lineAlpha = 0.90 - layerT * 0.20
                    let lineWidth: CGFloat = (2.8 + 2.6 * CGFloat(beatBoost) + 1.4 * CGFloat(pulse)) - CGFloat(layerT) * 0.6
                    let strokeColor = layer == 0 ? paletteColor : paletteSecondary
                    ctx.stroke(
                        path,
                        with: .color(strokeColor.opacity(lineAlpha)),
                        style: StrokeStyle(
                            lineWidth: lineWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }

                // Antinode shimmer: draw tiny dots along the outer curve at
                // angles where the dominant harmonic peaks, so vibration
                // "escapes" the curve. Reads as standing-wave energy.
                drawAntinodes(
                    in: &ctx,
                    center: center,
                    baseRadius: baseRadius * 1.08,
                    bands: bands,
                    time: t,
                    rotation: rotation,
                    paletteColor: paletteColor,
                    pulse: pulse
                )
            }
            .blur(radius: 0.6)
        }
        .onAppear {
            scheduler.subscribe { beat in
                handleBeat(beat)
            }
        }
        .onDisappear {
            beatBoostTimer?.cancel()
        }
        .allowsHitTesting(false)
    }

    // MARK: - Harmonic curve

    /// Builds one closed radial curve whose radius is the Fourier-like
    /// superposition of cos(k·θ) terms weighted by the current spectrum.
    ///
    /// - Parameters:
    ///   - bands: 8 frequency-band energies in [0, 1].
    ///   - time: drives per-harmonic phase drift.
    ///   - rotation: whole-pattern rotation in radians.
    ///   - boost: multiplies all amplitudes for beat-driven ringing.
    private func harmonicPath(
        center: CGPoint,
        baseRadius: Double,
        bands: [Double],
        time: Double,
        rotation: Double,
        boost: Double,
        samples: Int
    ) -> Path {
        // Per-band amplitude. Aggressive — typical spectra push radius
        // well outside ±0.3·R on dominant bands, so the shape deforms
        // visibly every frame instead of sitting near-circular.
        let perBandAmp = 0.16
        let amplifier = 1.0 + boost

        var path = Path()
        for i in 0...samples {
            let theta = Double(i) / Double(samples) * 2.0 * .pi + rotation

            var radiusFactor = 1.0
            // Always-on base modulation (2-, 3-, 5-, 7-fold) so the curve
            // is never a pure circle even with zero spectrum input. Faster
            // drift rates than before so the resting shape is visibly
            // morphing every frame.
            radiusFactor += 0.11 * cos(2.0 * theta + time * 0.70)
            radiusFactor += 0.08 * cos(3.0 * theta - time * 0.55)
            radiusFactor += 0.06 * cos(5.0 * theta + time * 0.95)
            radiusFactor += 0.04 * cos(7.0 * theta - time * 1.20)

            for (k, band) in bands.enumerated() {
                let harmonic = Double(k + 1)
                // Each harmonic drifts at its own rate so the symmetry
                // continuously breaks and re-forms. Faster rates than
                // before — makes the pattern feel alive, not hypnotic.
                let phase = time * (0.55 + 0.18 * Double(k)) + Double(k) * 1.2
                let contribution = band * perBandAmp * cos(harmonic * theta + phase)
                radiusFactor += contribution
            }
            radiusFactor *= amplifier
            // Guard against negative radii on extreme spectra.
            let r = max(baseRadius * 0.35, baseRadius * radiusFactor)

            let x = center.x + CGFloat(cos(theta) * r)
            let y = center.y + CGFloat(sin(theta) * r)
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Antinode shimmer

    /// Picks the dominant band and scatters small dots at the angles where
    /// its harmonic peaks (i.e. cos((k+1)θ) ≈ 1). These are the antinodes
    /// of the standing wave — the places where sand would pile up on a
    /// Chladni plate.
    private func drawAntinodes(
        in ctx: inout GraphicsContext,
        center: CGPoint,
        baseRadius: Double,
        bands: [Double],
        time: Double,
        rotation: Double,
        paletteColor: Color,
        pulse: Double
    ) {
        guard let (dominantIdx, dominantAmp) = bands
            .enumerated()
            .max(by: { $0.element < $1.element }),
              dominantAmp > 0.05 else { return }

        let modeCount = dominantIdx + 1
        let phase = time * (0.55 + 0.18 * Double(dominantIdx)) + Double(dominantIdx) * 1.2
        let dotRadius: CGFloat = 3.5 + 7.0 * CGFloat(pulse)
        let dotAlpha = min(1.0, 0.60 + dominantAmp * 0.8)

        for m in 0..<modeCount {
            // Antinode angles: cos((modeCount)·θ + phase) = 1 when
            //   (modeCount)·θ + phase = 2π·m  ⇒  θ = (2π·m − phase) / modeCount
            let theta = (2.0 * .pi * Double(m) - phase) / Double(modeCount) + rotation
            let x = center.x + CGFloat(cos(theta) * baseRadius)
            let y = center.y + CGFloat(sin(theta) * baseRadius)
            let rect = CGRect(
                x: x - dotRadius,
                y: y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )
            ctx.fill(
                Path(ellipseIn: rect),
                with: .color(paletteColor.opacity(dotAlpha))
            )
        }
    }

    // MARK: - Beat handling

    private func handleBeat(_ beat: BeatEvent) {
        // Hit harder than literal intensity — downbeats slam to 1.4, off-beats
        // hold a 0.7 floor so even soft beats ring the shape visibly.
        let strength = beat.isDownbeat ? 1.4 : max(0.7, beat.intensity * 1.2)
        beatBoostTimer?.cancel()
        beatBoost = strength
        beatBoostTimer = Task { @MainActor in
            let steps = 18
            let duration: Double = 0.55
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(Int(duration * 1000 / Double(steps))))
                if Task.isCancelled { return }
                let t = Double(step) / Double(steps)
                let decay = pow(1.0 - t, 2.0)
                beatBoost = strength * decay
            }
            beatBoost = 0
        }
    }
}

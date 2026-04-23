//
//  VisualizerPreview.swift
//  SoundSeen
//
//  Live preview harness for the visualizer. Generates a synthetic
//  SongAnalysis on the fly (30s of varied structural content) and a
//  simulated clock that ticks time forward at 60Hz — no backend, no
//  audio file required. Hit "Play" in the Xcode Preview canvas and
//  the full voice stack runs.
//
//  Use when: tuning voice parameters, testing drop choreography,
//  adjusting palette blending. For real audio + haptic testing you
//  still need the simulator/device + backend.
//

import SwiftUI

// MARK: - Synthetic analysis

extension SongAnalysis {
    /// Build a fake SongAnalysis with obvious structural phases so voice
    /// behavior is readable: intro → verse → chorus → buildup → drop → outro.
    /// Tuned for visual demo more than musical realism.
    static func syntheticDemo(duration: Double = 30) -> SongAnalysis {
        let frameDurationMs: Double = 23.2  // ~hop_length=512 at 22050Hz
        let frameDurationS = frameDurationMs / 1000.0
        let frameCount = Int(duration / frameDurationS)

        var time = [Double]()
        var energy = [Double]()
        var bands = [[Double]]()
        var centroid = [Double]()
        var flux = [Double]()
        var hue = [Double]()
        var chromaStrength = [Double]()
        var harmonicRatio = [Double]()

        time.reserveCapacity(frameCount)
        energy.reserveCapacity(frameCount)
        bands.reserveCapacity(frameCount)

        for i in 0..<frameCount {
            let t = Double(i) * frameDurationS
            let phase = SyntheticPhase.phase(at: t, duration: duration)
            time.append(t)
            energy.append(phase.energy + 0.05 * sin(t * 6.28))
            bands.append(phase.bands(at: t))
            centroid.append(phase.centroidHz + 300 * sin(t * 1.1))
            flux.append(phase.flux * (0.6 + 0.4 * abs(sin(t * 3.3))))
            // Chroma hue sweeps slowly through the circle so the harmonic
            // voice has something to pull toward.
            hue.append((t * 0.04).truncatingRemainder(dividingBy: 1))
            chromaStrength.append(phase.chromaStrength)
            harmonicRatio.append(phase.harmonicRatio)
        }

        // Beats at 120 BPM = every 0.5s. Downbeats every 4 beats.
        var beatEvents: [BeatEvent] = []
        var bt = 0.0
        var beatIx = 0
        while bt < duration {
            let phase = SyntheticPhase.phase(at: bt, duration: duration)
            beatEvents.append(BeatEvent(
                time: bt,
                intensity: phase.beatIntensity,
                sharpness: phase.beatSharpness,
                bassIntensity: phase.energy,
                isDownbeat: beatIx % 4 == 0
            ))
            bt += 0.5
            beatIx += 1
        }

        // Onsets roughly 4x beat density with varying attack envelopes.
        var onsetEvents: [OnsetEvent] = []
        var ot = 0.0
        while ot < duration {
            let phase = SyntheticPhase.phase(at: ot, duration: duration)
            onsetEvents.append(OnsetEvent(
                time: ot,
                intensity: phase.onsetIntensity,
                sharpness: phase.beatSharpness * 0.9,
                attackStrength: phase.onsetIntensity,
                attackTimeMs: 8,
                decayTimeMs: 120,
                sustainLevel: 0.3,
                attackSlope: phase.beatSharpness
            ))
            ot += 0.125 + Double.random(in: 0...0.08)
        }

        // Emotion at 0.5s resolution. Valence rises through verse+chorus,
        // dips at buildup, peaks at drop.
        let emotionInterval = 0.5
        let emotionCount = Int(duration / emotionInterval)
        var valence = [Double](), arousal = [Double]()
        for i in 0..<emotionCount {
            let t = Double(i) * emotionInterval
            let phase = SyntheticPhase.phase(at: t, duration: duration)
            valence.append(phase.valence)
            arousal.append(phase.arousal)
        }

        // Sections — tight narrative for demo.
        let sections: [SongSection] = [
            .init(start: 0,            end: duration * 0.16, label: "intro",  energyProfile: "building"),
            .init(start: duration*0.16, end: duration * 0.40, label: "verse",  energyProfile: "moderate"),
            .init(start: duration*0.40, end: duration * 0.62, label: "chorus", energyProfile: "high"),
            .init(start: duration*0.62, end: duration * 0.78, label: "bridge", energyProfile: "building"),
            .init(start: duration*0.78, end: duration * 0.88, label: "drop",   energyProfile: "intense"),
            .init(start: duration*0.88, end: duration,        label: "outro",  energyProfile: "fading")
        ]

        return SongAnalysis(
            songId: "preview-synthetic",
            filename: "synthetic.mp3",
            storagePath: "",
            durationSeconds: duration,
            bpm: 120,
            bandNames: ["sub_bass", "bass", "low_mid", "mid", "upper_mid", "presence", "brilliance", "ultra_high"],
            beatEvents: beatEvents,
            onsetEvents: onsetEvents,
            sections: sections,
            emotion: Emotion(interval: emotionInterval, valence: valence, arousal: arousal),
            frames: Frames(
                frameDurationMs: frameDurationMs,
                count: frameCount,
                time: time,
                energy: energy,
                bands: bands,
                centroid: centroid,
                flux: flux,
                hue: hue,
                chromaStrength: chromaStrength,
                harmonicRatio: harmonicRatio,
                rolloff: nil,
                zcr: nil,
                spectralContrast: nil,
                mfcc: nil,
                chroma: nil
            ),
            processingTimeSeconds: 0
        )
    }
}

/// Hand-authored per-phase parameters the synthetic generator plays back
/// as a function of normalized song position. Mirrors the section layout.
private struct SyntheticPhase {
    let energy: Double
    let flux: Double
    let centroidHz: Double
    let chromaStrength: Double
    let harmonicRatio: Double
    let beatIntensity: Double
    let beatSharpness: Double
    let onsetIntensity: Double
    let valence: Double
    let arousal: Double
    /// Per-band bias multipliers so low bands dominate early and highs
    /// come alive at the drop. Multiplied into a time-varying base.
    let bandBias: [Double]

    func bands(at t: Double) -> [Double] {
        // Base wave pattern: each band has its own phase so they don't
        // pulse in lock-step. Combined with phase-specific bias so the
        // overall spectrum shifts through the song.
        var out = [Double]()
        out.reserveCapacity(8)
        for i in 0..<8 {
            let base = 0.25 + 0.35 * abs(sin(t * (1.2 + Double(i) * 0.17)))
            out.append(min(1, max(0, base * bandBias[i])))
        }
        return out
    }

    static func phase(at t: Double, duration: Double) -> SyntheticPhase {
        let n = max(0, min(1, t / max(duration, 0.001)))
        switch n {
        case 0..<0.16:   // intro — building
            return SyntheticPhase(
                energy: 0.20 + 0.20 * (n / 0.16),
                flux: 0.15,
                centroidHz: 1400,
                chromaStrength: 0.65,
                harmonicRatio: 0.85,
                beatIntensity: 0.45,
                beatSharpness: 0.25,
                onsetIntensity: 0.20,
                valence: 0.55,
                arousal: 0.30 + 0.10 * (n / 0.16),
                bandBias: [1.3, 1.1, 0.9, 0.7, 0.5, 0.4, 0.3, 0.2]
            )
        case 0.16..<0.40: // verse — moderate
            return SyntheticPhase(
                energy: 0.45,
                flux: 0.32,
                centroidHz: 1900,
                chromaStrength: 0.75,
                harmonicRatio: 0.70,
                beatIntensity: 0.60,
                beatSharpness: 0.45,
                onsetIntensity: 0.40,
                valence: 0.62,
                arousal: 0.50,
                bandBias: [1.0, 1.1, 1.0, 0.9, 0.8, 0.7, 0.5, 0.4]
            )
        case 0.40..<0.62: // chorus — high
            return SyntheticPhase(
                energy: 0.75,
                flux: 0.55,
                centroidHz: 2600,
                chromaStrength: 0.85,
                harmonicRatio: 0.55,
                beatIntensity: 0.80,
                beatSharpness: 0.60,
                onsetIntensity: 0.65,
                valence: 0.80,
                arousal: 0.72,
                bandBias: [0.9, 1.0, 1.0, 1.1, 1.1, 1.0, 0.85, 0.7]
            )
        case 0.62..<0.78: // bridge — building
            let lp = (n - 0.62) / 0.16
            return SyntheticPhase(
                energy: 0.55 + 0.30 * lp,
                flux: 0.40 + 0.40 * lp,
                centroidHz: 2300,
                chromaStrength: 0.60,
                harmonicRatio: 0.45,
                beatIntensity: 0.70,
                beatSharpness: 0.55 + 0.30 * lp,
                onsetIntensity: 0.55 + 0.35 * lp,
                valence: 0.55 - 0.15 * lp,
                arousal: 0.65 + 0.30 * lp,
                bandBias: [0.8, 1.0, 1.0, 1.0, 1.1, 1.1, 1.0, 0.8]
            )
        case 0.78..<0.88: // drop — intense
            return SyntheticPhase(
                energy: 0.92,
                flux: 0.88,
                centroidHz: 3200,
                chromaStrength: 0.70,
                harmonicRatio: 0.30,
                beatIntensity: 1.00,
                beatSharpness: 0.92,
                onsetIntensity: 0.95,
                valence: 0.70,
                arousal: 0.95,
                bandBias: [1.2, 1.2, 1.0, 1.0, 1.1, 1.2, 1.2, 1.3]
            )
        default:          // outro — fading
            let lp = (n - 0.88) / 0.12
            return SyntheticPhase(
                energy: 0.60 - 0.50 * lp,
                flux: 0.25,
                centroidHz: 1600,
                chromaStrength: 0.75,
                harmonicRatio: 0.80,
                beatIntensity: 0.55,
                beatSharpness: 0.30,
                onsetIntensity: 0.35,
                valence: 0.60,
                arousal: 0.40 - 0.30 * lp,
                bandBias: [1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3]
            )
        }
    }
}

// MARK: - Preview harness

/// Standalone view that drives the visualizer off a simulated clock — no
/// AVAudioPlayer, no backend. Tap the screen to seek back to start.
struct VisualizerPreviewHarness: View {
    let analysis: SongAnalysis
    @State private var visualizer: VisualizerState
    @State private var choreography: DropChoreography? = nil
    @State private var narrative: SceneNarrative? = nil
    @State private var startReference: Date = Date()
    @State private var lastUpdatedTime: Double = 0

    init(analysis: SongAnalysis = .syntheticDemo()) {
        self.analysis = analysis
        _visualizer = State(initialValue: VisualizerState(analysis: analysis))
    }

    var body: some View {
        ZStack {
            if let choreo = choreography, let nar = narrative {
                VisualizerRoot(
                    state: visualizer,
                    choreography: choreo,
                    narrative: nar
                )

                VStack {
                    SectionCaption(state: visualizer)
                        .padding(.top, 72)
                    Spacer()
                    VStack(spacing: 4) {
                        Text("PREVIEW · tap to restart")
                            .font(SSDesign.Typography.caption(10))
                            .kerning(2)
                            .textCase(.uppercase)
                            .foregroundStyle(.white.opacity(0.55))
                        Text(String(format: "t = %.2fs / %.0fs", elapsed(), analysis.durationSeconds))
                            .font(SSDesign.Typography.meta(11))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .padding(.bottom, 32)
                }
                .allowsHitTesting(false)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture {
            startReference = Date()
            lastUpdatedTime = 0
        }
        .onAppear {
            if choreography == nil {
                choreography = DropChoreography(state: visualizer)
                narrative = SceneNarrative(state: visualizer)
                startReference = Date()
            }
        }
        .modifier(PreviewTickModifier { now in
            // Loop the playhead so the preview is eternal — after outro,
            // jump back to start.
            var t = now
            if analysis.durationSeconds > 0 {
                t = t.truncatingRemainder(dividingBy: analysis.durationSeconds)
            }
            let prev = lastUpdatedTime
            visualizer.update(prevTime: prev, currentTime: t)
            choreography?.tick(prevTime: prev, currentTime: t)
            narrative?.tick(prevTime: prev, currentTime: t)
            lastUpdatedTime = t
        })
    }

    private func elapsed() -> Double {
        Date().timeIntervalSince(startReference)
    }
}

/// Runs a ~60Hz update closure bound to a SwiftUI `TimelineView(.animation)`.
/// Wrapping the tick side-effect here keeps the harness body readable.
private struct PreviewTickModifier: ViewModifier {
    let onTick: (Double) -> Void
    @State private var origin: Date = Date()

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(origin)
            content.onChange(of: timeline.date) { _, _ in
                onTick(elapsed)
            }
        }
    }
}

// MARK: - Previews

#Preview("Visualizer — synthetic song") {
    VisualizerPreviewHarness()
        .preferredColorScheme(.dark)
}

#Preview("Visualizer — short loop (10s)") {
    VisualizerPreviewHarness(analysis: .syntheticDemo(duration: 10))
        .preferredColorScheme(.dark)
}

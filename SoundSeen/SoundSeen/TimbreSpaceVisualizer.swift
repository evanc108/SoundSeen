//
//  TimbreSpaceVisualizer.swift
//  SoundSeen
//
//  Circular spectrum: energy radiates around a ring (no “floor” ellipse). 3D tilt on the whole field.
//

import SwiftUI

/// Spectrum + timbre mapped to a **ring** around the center (works with the circular glow behind it).
struct TimbreSpaceVisualizer: View {
    @EnvironmentObject private var player: AudioReactivePlayer
    var isPaused: Bool

    private let ringSegments = 36

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isPaused)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let levels = player.barLevels
            let n = max(1, levels.count)

            let br = Double(player.timbreBrightness)
            let air = Double(player.timbreAir)
            let grain = Double(player.timbreGrain)
            let mem = Double(player.timbreMemory)
            let sheen = Double(player.timbreSheen)
            let beat = Double(player.beatPulse)
            let bass = Double(player.bassEnergy)

            let confuse = grain * 17 + sheen * 31
            let rotX = br * 14 + sin(t * 0.9 + mem * 6) * (7 + grain * 10) - beat * 4
            let rotY = air * 18 + cos(t * 0.65 + sheen * 9) * (8 + bass * 6) - grain * 8
            let rotZ = beat * 10 + sheen * 24 - br * 5

            ZStack {
                // Faint orbit guides (not a “dark floor” — thin rings you read as 3D space).
                orbitGuides(sheen: sheen, t: t)

                // Memory ring — inner, softer, phase-shifted sampling.
                circularRing(
                    levels: levels,
                    n: n,
                    t: t,
                    confuse: confuse + 13,
                    opacity: 0.38 + mem * 0.18,
                    strokeScale: 0.8,
                    air: air,
                    grain: grain,
                    sheen: sheen,
                    brightness: br,
                    radiusScale: 0.72,
                    barLengthScale: 0.55
                )
                .rotation3DEffect(
                    .degrees(-rotX * 0.55),
                    axis: (x: 1, y: 0.2, z: 0),
                    anchor: .center,
                    anchorZ: 45,
                    perspective: 0.5
                )
                .blur(radius: 2)

                // Main ring — bars point **outward** from the circle.
                circularRing(
                    levels: levels,
                    n: n,
                    t: t,
                    confuse: confuse,
                    opacity: 1,
                    strokeScale: 1,
                    air: air,
                    grain: grain,
                    sheen: sheen,
                    brightness: br,
                    radiusScale: 1,
                    barLengthScale: 1
                )
                .rotation3DEffect(
                    .degrees(rotX),
                    axis: (x: 1, y: 0.1, z: 0),
                    anchor: .center,
                    anchorZ: 60,
                    perspective: 0.42
                )
                .rotation3DEffect(
                    .degrees(rotY),
                    axis: (x: 0.08, y: 1, z: 0),
                    anchor: .center,
                    anchorZ: 60,
                    perspective: 0.42
                )
                .rotation3DEffect(
                    .degrees(rotZ),
                    axis: (x: 0, y: 0, z: 1),
                    anchor: .center,
                    anchorZ: 60,
                    perspective: 0.42
                )

                sheenHalo(t: t, sheen: sheen, air: air, beat: beat)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
        }
    }

    /// Soft ellipses read as a shallow bowl / orbit — light, not a black smudge.
    private func orbitGuides(sheen: Double, t: TimeInterval) -> some View {
        ZStack {
            Ellipse()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.12 + sheen * 0.08),
                            SoundSeenTheme.purpleAccent.opacity(0.2),
                            Color.white.opacity(0.1),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .frame(width: 220, height: 94)
                .rotation3DEffect(.degrees(-52 + sin(t * 0.35) * 3), axis: (x: 1, y: 0, z: 0), anchor: .center, anchorZ: 0, perspective: 0.7)
                .opacity(0.55)

            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                .frame(width: 118, height: 118)
        }
        .allowsHitTesting(false)
    }

    private func circularRing(
        levels: [CGFloat],
        n: Int,
        t: TimeInterval,
        confuse: Double,
        opacity: Double,
        strokeScale: CGFloat,
        air: Double,
        grain: Double,
        sheen: Double,
        brightness: Double,
        radiusScale: CGFloat,
        barLengthScale: CGFloat
    ) -> some View {
        GeometryReader { geo in
            let cx = geo.size.width / 2
            let cy = geo.size.height / 2
            let R = min(geo.size.width, geo.size.height) / 2 * radiusScale
            let innerR = R * 0.52
            let maxBar = R * 0.48 * barLengthScale
            let step = max(3, n / ringSegments)
            let coprime = 7 + Int(confuse.truncatingRemainder(dividingBy: 5))
            let barW = max(2.2, CGFloat.pi * 2 * innerR / CGFloat(ringSegments * 2))

            ZStack {
                ForEach(0..<ringSegments, id: \.self) { i in
                    let a = 2 * CGFloat.pi * CGFloat(i) / CGFloat(ringSegments) - .pi / 2
                    let j = (i * coprime + Int(t * 4 + confuse)) % n
                    let k = (j + step) % n
                    let aD = Double(a)
                    let aLevels = levels[j]
                    let bLevels = levels[k]
                    let mix = CGFloat(brainMix(i: i, t: t, grain: grain))
                    let intensity = aLevels * mix + bLevels * (1 - mix)
                    let hue = Double(i) / Double(ringSegments) * 0.62 + air * 0.28 + sin(t + Double(i) * 0.18) * sheen * 0.1
                    let barLen = max(7, CGFloat(intensity) * maxBar * (0.52 + CGFloat(brightness) * 0.42))

                    RoundedRectangle(cornerRadius: barW / 2, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(hue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.5 + Double(intensity) * 0.48),
                                    Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.98),
                                ],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: barW, height: barLen)
                        .overlay {
                            RoundedRectangle(cornerRadius: barW / 2, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.4), Color.white.opacity(0.06)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 0.5 * strokeScale
                                )
                        }
                        .shadow(
                            color: Color(hue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.55)
                                .opacity(0.45 + Double(intensity) * 0.35),
                            radius: 4 + CGFloat(intensity) * 6,
                            x: CGFloat(cos(aD)) * 2,
                            y: CGFloat(sin(aD)) * 2 + 3
                        )
                        .rotationEffect(.radians(Double(a) + .pi / 2))
                        .position(
                            x: cx + CGFloat(cos(aD)) * (innerR + barLen / 2),
                            y: cy + CGFloat(sin(aD)) * (innerR + barLen / 2)
                        )
                        .opacity(opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func brainMix(i: Int, t: TimeInterval, grain: Double) -> CGFloat {
        let x = Double(i) * 0.37 + t * 1.3
        let g = sin(x) * 0.5 + 0.5
        return CGFloat((1 - grain) * g + grain * (1 - g))
    }

    private func sheenHalo(t: TimeInterval, sheen: Double, air: Double, beat: Double) -> some View {
        Circle()
            .strokeBorder(
                AngularGradient(
                    colors: [
                        Color(hue: 0.55 + air * 0.2, saturation: 0.7, brightness: 1),
                        Color(hue: 0.12 + sheen * 0.3, saturation: 0.85, brightness: 1),
                        Color(hue: 0.75 - beat * 0.15, saturation: 0.6, brightness: 0.9),
                        Color(hue: 0.55 + air * 0.2, saturation: 0.7, brightness: 1),
                    ],
                    center: .center,
                    angle: .degrees(t * -40 + sheen * 120)
                ),
                lineWidth: 2 + sheen * 4
            )
            .frame(width: 168 + CGFloat(sheen) * 70, height: 168 + CGFloat(sheen) * 70)
            .opacity(0.2 + sheen * 0.45 + beat * 0.12)
            .blur(radius: 1 + CGFloat(sheen) * 2)
            .rotation3DEffect(.degrees(sin(t * 1.2) * sheen * 18), axis: (x: 1, y: 1, z: 0), anchor: .center, anchorZ: 35, perspective: 0.55)
            .allowsHitTesting(false)
    }
}

#Preview {
    TimbreSpaceVisualizer(isPaused: false)
        .environmentObject(AudioReactivePlayer())
        .background(Color.black)
}

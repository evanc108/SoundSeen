//
//  VisualizerRoot.swift
//  SoundSeen
//
//  Composes all texture layers on a single 60Hz timeline. Every texture
//  reads three things from this frame: VisualizerState (the data bus),
//  the transformed EmotionScheme (emotion palette × section transform),
//  and the active SectionDialect.
//
//  Z order (back → front):
//    1.  AtmosphereBackdrop         — deep radial wash
//    2.  TextureBundle              — scene textures incl. archetypes
//        (wrapped with .saturation() when pre-drop anticipation rises)
//    3.  ChorusLift bloom           — one-shot top bloom on chorus entry
//    4.  Palette invert overlay     — drop flash (difference blend)
//    5.  FilmGrainTexture           — colorless/cool unrest
//    6.  BreakCalm vignette         — top+bottom darken during break/outro
//    7.  Dashboard                  — valence + chroma + key compass
//    8.  PreDropAnticipation bars   — cinematic letterbox at peak buildup
//

import SwiftUI

struct VisualizerRoot: View {
    @Bindable var state: VisualizerState
    @Bindable var choreography: DropChoreography
    let narrative: SceneNarrative

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
            let now = timeline.date
            let dialect = SectionDialectResolver.resolve(
                label: state.currentSectionLabel,
                progress: state.currentSectionProgress,
                energyProfile: state.currentSectionEnergyProfile
            )
            let baseScheme = HybridEmotionPalette.scheme(
                from: state.biomeWeights,
                chromaHue: state.currentHue,
                chromaStrength: state.currentChromaStrength
            )
            let scheme = baseScheme.transformed(by: dialect)
            let shimmerStrength = ThermalShimmer.strength(
                state: state,
                dialect: dialect,
                choreography: choreography
            )

            ZStack {
                AtmosphereBackdrop(scheme: scheme, energy: state.currentEnergy)

                TextureBundle(
                    state: state,
                    choreography: choreography,
                    scheme: scheme,
                    dialect: dialect,
                    now: now
                )
                .applySceneTransform(dialect: dialect)
                .applyThermalShimmer(strength: shimmerStrength, now: now)
                .saturation(narrative.anticipation.saturationScale)

                ChorusLiftBloom(
                    strength: narrative.lift.strength,
                    scheme: scheme
                )

                if choreography.invertAmount > 0.01 {
                    Rectangle()
                        .fill(scheme.primary.color(opacity: 1))
                        .blendMode(.difference)
                        .opacity(choreography.invertAmount)
                        .allowsHitTesting(false)
                }

                FilmGrainTexture(state: state, dialect: dialect, now: now)

                BreakCalmVignette(strength: narrative.calm.strength)

                DashboardBundle(
                    state: state,
                    scheme: scheme,
                    dialect: dialect,
                    now: now
                )

                PreDropLetterbox(progress: narrative.anticipation.letterboxProgress)
            }
            .ignoresSafeArea()
            .compositingGroup()
        }
    }
}

// MARK: - Atmosphere backdrop

struct AtmosphereBackdrop: View {
    let scheme: EmotionScheme
    let energy: Double

    var body: some View {
        let lift = 1.0 + max(0, min(1, energy)) * 0.12
        let center = HSB(
            h: scheme.primary.h,
            s: scheme.primary.s * 0.55,
            b: min(1.0, scheme.primary.b * 0.42 * lift)
        )
        let edge = scheme.atmosphere
        GeometryReader { geo in
            let size = max(geo.size.width, geo.size.height)
            RadialGradient(
                gradient: Gradient(colors: [
                    center.color(opacity: 1),
                    edge.color(opacity: 1)
                ]),
                center: .center,
                startRadius: size * 0.05,
                endRadius: size * 0.85
            )
        }
    }
}

// MARK: - Texture bundle

/// Bundle of scene textures that SHARE the section's scene transform and
/// thermal distortion. Grouped so the modifier chain wraps them as a
/// unit — not each texture individually.
private struct TextureBundle: View {
    @Bindable var state: VisualizerState
    @Bindable var choreography: DropChoreography
    let scheme: EmotionScheme
    let dialect: SectionDialect
    let now: Date

    /// Gate: FluxShatter only runs during high-arousal chorus/drop/bridge
    /// sections. Otherwise the horizon slashes read as laser-show chrome
    /// across lower-energy passages where they don't belong.
    private var fluxShatterEnabled: Bool {
        guard state.smoothedArousal > 0.6 else { return false }
        switch state.currentSectionLabel.lowercased() {
        case "chorus", "drop", "bridge": return true
        default: return false
        }
    }

    var body: some View {
        ZStack {
            SubBassRippleTexture(state: state, scheme: scheme, dialect: dialect, now: now)
            VelvetDarknessTexture(state: state, scheme: scheme, dialect: dialect, now: now)
            SmokeTexture(state: state, scheme: scheme, dialect: dialect, now: now)
            InkBleedTexture(state: state, scheme: scheme, dialect: dialect, now: now)
            AuroraTexture(state: state, scheme: scheme, dialect: dialect, now: now)
            BiomeArchetypeLayer(state: state, scheme: scheme, dialect: dialect, now: now)
            FrostTexture(state: state, scheme: scheme, dialect: dialect, now: now)
            EmberTexture(state: state, choreography: choreography, scheme: scheme, dialect: dialect, now: now)
            GlowPulseTexture(state: state, scheme: scheme, dialect: dialect, now: now)
            GodRaysTexture(state: state, scheme: scheme, dialect: dialect, now: now)
            if fluxShatterEnabled {
                FluxShatterTexture(state: state, scheme: scheme, dialect: dialect, now: now)
            }
        }
    }
}

// MARK: - Dashboard bundle

/// Dashboards stay readable through the bridge's rotation and chorus's
/// mirroring — they live outside the scene transform.
private struct DashboardBundle: View {
    @Bindable var state: VisualizerState
    let scheme: EmotionScheme
    let dialect: SectionDialect
    let now: Date

    var body: some View {
        ZStack {
            ValenceGradientTexture(state: state, dialect: dialect)
            ChromaSlickTexture(state: state, dialect: dialect, now: now)
            KeyRailTexture(state: state, dialect: dialect)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Narrative overlays

/// One-shot top-half radial bloom that fires on chorus entry. Scales with
/// `strength` in [0, 1]; zero means no-op.
private struct ChorusLiftBloom: View {
    let strength: Double
    let scheme: EmotionScheme

    var body: some View {
        if strength > 0.01 {
            GeometryReader { geo in
                let s = geo.size
                let h = s.height
                RadialGradient(
                    gradient: Gradient(colors: [
                        scheme.accent.color(opacity: 0.55 * strength),
                        scheme.primary.color(opacity: 0.25 * strength),
                        Color.clear
                    ]),
                    center: UnitPoint(x: 0.5, y: 0.0),
                    startRadius: 0,
                    endRadius: h * 0.85
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
            }
        }
    }
}

/// Vertical vignette that pinches the top and bottom of the frame during
/// `break` and `outro`. Top/bottom linear gradients darken inward while
/// the middle of the scene remains readable.
private struct BreakCalmVignette: View {
    let strength: Double

    var body: some View {
        if strength > 0.01 {
            GeometryReader { _ in
                VStack(spacing: 0) {
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.black.opacity(0.7 * strength),
                            Color.clear
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: UIScreen.main.bounds.height * 0.22)
                    Spacer()
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.clear,
                            Color.black.opacity(0.7 * strength)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: UIScreen.main.bounds.height * 0.22)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// Cinematic letterbox. Solid black bars at top and bottom, height scaled
/// by `progress` in [0, 1]; at full progress each bar is 8% of screen.
private struct PreDropLetterbox: View {
    let progress: Double

    var body: some View {
        if progress > 0.01 {
            GeometryReader { geo in
                let h = geo.size.height
                let barH = h * 0.08 * progress
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.black)
                        .frame(height: barH)
                    Spacer()
                    Rectangle()
                        .fill(Color.black)
                        .frame(height: barH)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Section scene transforms

private extension View {
    /// Apply dialect's composition transforms: mirror, rotation, origin
    /// shift. Applied to the texture bundle so every texture inside sees
    /// the same scene mapping.
    @ViewBuilder
    func applySceneTransform(dialect: SectionDialect) -> some View {
        let rotation = Angle.degrees(dialect.rotationDegrees)
        if dialect.mirrorX {
            self
                .overlay {
                    self
                        .scaleEffect(x: -1, y: 1, anchor: .center)
                        .opacity(0.22)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                }
                .rotationEffect(rotation, anchor: .center)
        } else {
            self.rotationEffect(rotation, anchor: .center)
        }
    }

    @ViewBuilder
    func applyThermalShimmer(strength: Double, now: Date) -> some View {
        if strength > 0.5 {
            self.distortionEffect(
                ThermalShimmer.shader(strength: strength, now: now),
                maxSampleOffset: CGSize(width: strength, height: strength)
            )
        } else {
            self
        }
    }
}

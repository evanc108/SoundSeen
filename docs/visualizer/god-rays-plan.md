# SoundSeen — Klsr-Inspired Cinematic God-Ray Visualizer

## Context

SoundSeen translates music into visuals and haptics for the Deaf/HoH community — the app's whole thesis is that visuals should communicate *emotion*, not just data. The current `AnalyzedPlayerView` already stacks 13 expressive SwiftUI layers (aurora ribbons, cymatic center, biome palettes, flux halos, onset particles, etc.) and does a lot well, but every layer is CPU-rendered SwiftUI with no GPU shaders, so the ceiling on cinematic, emotionally resonant imagery is capped.

We studied Klsr (tiktok @klsr.av), a Brighton audiovisual artist whose work conveys real emotion through music visualization. His technique: TouchDesigner + real-time audio reactivity, with two signature couplings running through almost every piece — **low-end energy drives brightness**, **snare hits drive feedback/bloom**. His favorite own piece ("Bliss") is cinematic, Hans Zimmer-inspired, built around slow builds and volumetric light.

Direction chosen: **cinematic light + god-rays** (over fluid feedback or kaleidoscopic symmetry), **add one new hero visualizer alongside existing layers** (don't rip anything out). That scope lets us ship one hero shader that carries the Klsr motion language, behind a user toggle, without losing any of the team's existing work.

iOS deployment target is **26.2**, so SwiftUI's Metal shader APIs (`.layerEffect`, `ShaderLibrary`, `Shader(function:arguments:)`) are fully available. This is the key enabler — we can bring real GPU rendering into the app without wrapping `MTKView` in `UIViewRepresentable`.

**The primary success criterion is emotional, not technical.** The visualizer needs to feel like an art piece — something that turns the music into an *experience* a DHH user can feel emotionally, not a dashboard of reactive elements. Everything in the plan below exists in service of that. If a shader optimization, a beat-reactive flourish, or a HUD control fights the emotional experience, cut it.

---

## Emotional Design Principles (the north star)

These are the design rules that distinguish an art piece from a visualizer. Every technical choice downstream should reinforce them.

1. **Restraint is emotional.** Klsr's work moves you because it doesn't react to everything. Only the kick and the snare and the build *matter* — hi-hats and small transients are *ignored*. The low-end-only gating on brightness (bass, not every beat) comes directly from this. The visualizer should feel like it's *choosing* what to respond to.

2. **Slowness earns the drops.** The biggest emotional payoff is the release after a build. The section-build envelope must ramp over 2-3+ seconds (not per-frame reactivity), so when the drop lands the rays flood in and it feels earned. A visualizer that's always at 100% intensity never makes anyone cry.

3. **Color carries the feeling, not the energy.** Valence/arousal should shift palette and beam shape, *not* brightness. Sad music can still be bright. Intensity drives how much light — emotion drives what kind. This matches how Klsr's own work handles mood (warm vs cool, tight vs diffused) separately from loudness.

4. **The scene should breathe even when the music is quiet.** In silence or between sections, dust motes should still drift, a faint glow should still hang in the air. Empty silence on screen reads as "app broken." A low baseline presence keeps the piece feeling alive and held.

5. **Every moving element should feel intentional.** No random jitter, no noise for noise's sake. If something moves, it moves *because* of an emotional or musical cause — arousal, a snare, a section change. This is what separates art from screensavers.

6. **Accessibility is emotion-preserving, not emotion-removing.** Reduce Motion should dim and slow — not flatten. A DHH user with vestibular sensitivity should still get the *feeling* of a drop, just gentler. Capping intensity at 0.3 is fine; killing the snare bloom entirely is not.

**Acceptance — this ships when:**
- Playing a cinematic build-to-drop song (Good Things Fall Apart, Lonely), at least one person in the room says "oh" out loud at the drop.
- A Deaf user who can't hear the music can tell you, watching only the visuals, *when* the chorus hits and *how* the song feels emotionally — not just that something is happening.
- Turning God Rays off feels like turning off a light, not like removing noise.

Everything below is in service of these principles.

---

## Approach

A single new hero layer inserted into the existing `AnalyzedPlayerView` ZStack, toggleable from the HUD. No architectural changes to the app — this is additive. Existing layers keep running; the god-ray layer composites additively on top of the biome background and cymatic center.

The shader reads a cheap placeholder "light source" texture (a soft radial gradient View), not the whole scene, so it doesn't force the rest of the ZStack through `.drawingGroup()`. That keeps the other 13 layers at full fidelity and the shader cost bounded to one full-screen pass.

---

## Critical Files

### New files
- `SoundSeen/SoundSeen/Shaders/GodRays.metal` — Metal fragment shader (~70 LoC). Must be added to the **SoundSeen app target's Compile Sources** in Xcode (drag into the file navigator and confirm target membership). iOS 26.2 Xcode auto-compiles `.metal` files in the target into `default.metallib` with no build-setting tweaks.
- `SoundSeen/SoundSeen/Views/analyzed/GodRayVisualizer.swift` — SwiftUI wrapper (~220 LoC). Owns the placeholder light-source view, the snare-bloom envelope, and the `.layerEffect` call. Subscribes to `visualizer.fluxSpikeGeneration` and high-sharpness beats for bloom triggers (pattern copied directly from `Views/analyzed/FluxHaloLayer.swift:72-76`).

### Modified files
- `SoundSeen/SoundSeen/Views/AnalyzedPlayerView.swift` — insert `GodRayVisualizer(...)` at **line ~89**, between the existing `CymaticCenter` (line 82-88) and `FluxHaloLayer` (line 90). Pass in `viz`, `beats`, `palette`, `paletteSecondary` (already computed just above at lines 54-68). Add `@State private var godRayEnabled: Bool = true` and `@State private var godRayIntensity: Double = 0.7`, gate the layer on `if godRayEnabled`. Wire a toggle + slider into the existing HUD control row.
- `SoundSeen/SoundSeen/Services/VisualizerState.swift` — add two computed derived signals that the god-ray shader needs (currently nothing exposes them):
  - `var bassEnergySmoothed: Double` — EMA over `(currentBands[0] + currentBands[1]) * 0.5` with τ≈80ms, updated inside `updateFrameState` at line 132. Without EMA the rays strobe on every frame; Klsr's look is tight but *smooth* coupling.
  - `var sectionBuildEnvelope: Double` — 0-1 based on `currentSection.energyProfile` (`minimal`/`building`/`drop`/etc.) with a 2-3s attack/release, updated inside `updateSection`. This drives slow cinematic builds. Reuse the energy-profile enum that already lives in `Models/SongAnalysis.swift`.

### Reference patterns (do not modify — copy the shape)
- `SoundSeen/SoundSeen/Views/analyzed/FluxHaloLayer.swift:33-76` — exact template for a TimelineView + onChange(fluxSpikeGeneration) + bounded pool. The snare-bloom envelope in `GodRayVisualizer` follows this pattern.
- `SoundSeen/SoundSeen/Services/BeatScheduler.swift:41-61` — `subscribe(...)` for per-beat callbacks. Use to catch high-sharpness beats as snare proxies.
- `SoundSeen/SoundSeen/Models/BiomeWeights.swift` — softmax weights over euphoric/serene/intense/melancholic. Collapse into a single `paletteMix: Float` scalar Swift-side (warm vs cool weighting) before passing to the shader — avoids 4 extra uniforms.
- `SoundSeen/SoundSeen/SoundSeenTheme.swift` — palette color constants to reuse for warm/cool ray colors.

---

## Shader Design

`GodRays.metal` fragment function signature — **argument order between Swift and Metal must match exactly; mismatch is the most common silent-failure mode and produces a black output with no error**:

```metal
[[ stitchable ]] half4 godRays(
    float2 pos, SwiftUI::Layer layer,
    float2 lightCenter,     // normalized, default (0.5, 0.38)
    float  time,            // CACurrentMediaTime, wrapped
    float  bassEnergy,      // EMA-smoothed
    float  beatPulse,
    float  snareBloom,      // 0-1 envelope, computed Swift-side
    float  valence, float arousal,
    float  hueDrift,
    float  sectionBuild,
    float  intensityScale,  // HUD slider * reduce-motion clamp
    float  paletteMix,      // single warm-vs-cool scalar from biomeWeights
    half4  paletteWarm, half4 paletteCool
);
```

Algorithm — each step maps to one emotional principle:

1. **Radial ray-march from each pixel toward `lightCenter`**, 16 fixed steps. This is the volumetric light itself — the thing that *feels* cinematic. Performance: unrolls on driver, ~5-8ms on A15, ~3-5ms on A17 at 3x native.
2. **Beam power exponent from valence.** High valence → tighter sharper rays (focused, triumphant). Low valence → diffused glow (melancholic, held). *Principle 3: color/shape carries feeling.*
3. **Brightness = `0.15 + 0.55·bass + 0.20·beatPulse·bass + 0.60·snareBloom + 0.30·sectionBuild`.** The `0.15` floor is the baseline presence (*Principle 4: the scene breathes in silence*). `beatPulse` is *gated by bass* so hi-hats don't pop the rays — only real kicks do (*Principle 1: restraint*). `sectionBuild` is the slow ramp that earns the drop (*Principle 2: slowness earns the drop*).
4. **Palette = `mix(paletteCool, paletteWarm, paletteMix)` with small `hueDrift` shift.** Emotion drives color; never brightness. Sad sections can still be bright. (*Principle 3.*)
5. **Dust motes in the same shader:** hash-noise field with `time`-driven parallax, density modulated by arousal. Density floor is non-zero — motes drift even at silence (*Principle 4*). No second pass.
6. **Composite additively onto the sampled layer color** — preserves everything underneath.

**What is deliberately *not* reactive:**
- Hi-hat sharpness (caught by the beat tracker but ignored — too busy, breaks restraint).
- Every onset event (already handled by `OnsetParticleLayer`; god-rays don't double-dip).
- `currentFlux` in general — only *spikes* matter (snare bloom), not continuous texture.
- Small per-frame noise in bass energy — that's why the EMA is there.

If it doesn't serve one of the 6 emotional principles, it shouldn't drive the shader.

---

## Signal Pipeline (Swift side)

Inside `GodRayVisualizer`:

1. Read `visualizer.bassEnergySmoothed`, `beatPulse`, `smoothedValence/Arousal`, `currentHue`, `sectionBuildEnvelope`. Cast `Double → Float` at the boundary.
2. Compute `snareBloom` envelope. Two trigger sources:
   - `BeatScheduler.subscribe` callback: if `beat.sharpness > 0.6`, reset bloom to 1.0.
   - `.onChange(of: visualizer.fluxSpikeGeneration)`: also reset bloom (catches snare-like transients the beat tracker misses).
   - Decay at `-1 / 0.3` per second inside the TimelineView — bloom rings out in ~300ms.
3. Collapse `biomeWeights` into single `paletteMix` scalar: `(euphoric + intense) - (serene + melancholic)`, normalized 0-1. Warm biomes push mix toward 1, cool biomes toward 0.
4. Read `@Environment(\.accessibilityReduceMotion)`. If true, clamp `intensityScale` to 0.3 and set `time = 0` so dust freezes.
5. Build `Shader(function: ShaderLibrary.default.godRays, arguments: [.float2(lightCenter), .float(time), ...])` in the body on every TimelineView tick. Apply via `.layerEffect(shader, maxSampleOffset: CGSize(width: 400, height: 400))` to the placeholder gradient view.

The placeholder view is a `Color.black.ignoresSafeArea().overlay(RadialGradient(...))` — cheap to rasterize, keeps shader texture-cache warm. Do **not** apply `.layerEffect` to the full ZStack; that would force-rasterize all 13 layers.

---

## HUD Integration

Add two controls to the existing HUD control row in `AnalyzedPlayerView`:

- Toggle button with SF Symbol `sun.max.fill`, label "God rays", bound to `godRayEnabled`. Hide behind a settings sheet if the HUD row is already dense.
- Intensity slider 0.0-1.0, bound to `godRayIntensity`.

Accessibility floor: `effectiveIntensity = min(godRayIntensity, reduceMotionFloor)` so the user slider cannot override the reduce-motion clamp upward. The slider still works going downward (user can dim below the floor but never brighten past it).

Auto-disable `godRayEnabled` when a future "reduce visualizations" preference (from the P1 spec) is set, matching what other heavy layers will presumably do.

---

## Risks & Mitigations

- **Shader argument order mismatch → silent black output.** Mitigate with a comment block at the top of `GodRays.metal` listing the exact expected order, and a matching comment in `GodRayVisualizer.swift` where the arguments array is built. Consider a `#if DEBUG` assertion that the argument count matches a known constant.
- **Metal file not added to app target → `ShaderLibrary.default.godRays` returns a shader that renders transparent.** After drag-in, verify target membership in Build Phases → Compile Sources. This is easy to miss.
- **`.floatArray` per-frame allocation churn** — we sidestep this entirely by not passing the full 8-band array. Bass scalar is all the god-ray shader needs.
- **Performance on older devices** — full-screen `.layerEffect` ray-march on A13/A14 may drop below 60fps. Gate `godRayEnabled` default to `false` when `ProcessInfo.processInfo.thermalState != .nominal` or on pre-A15 devices. Keep the toggle accessible so the user can force it on if they accept the frame drop.
- **Argument order of iOS 26.x shader API quirks** — `.layerEffect` expects the shader's first two parameters to be `float2 pos, SwiftUI::Layer layer`; the remaining parameters are what the Swift `arguments: [...]` array fills. Document this in the `.metal` file header.

---

## Verification

### Emotional tests (the ones that actually matter)

1. **The "oh" test.** Watch a cinematic build-to-drop song (Good Things Fall Apart, Lonely) with the rays on, sound muted if necessary to judge visuals alone. Does the drop feel *earned*? Does the color change in the chorus feel like a different emotional state, not just a different setting? If not, the section build envelope is too fast or the palette mix is too subtle.
2. **The silence test.** Pause the track mid-song. The scene should *not* go dark or empty — dust should still drift, rays should still hang faintly. If it looks dead, the baseline floors (brightness `0.15`, dust density floor) are too low.
3. **The hi-hat test.** Play any track with a busy hi-hat pattern. The rays should *ignore* the hi-hats entirely — only kicks and snares should move them. If rays are skittering, the bass gating isn't working.
4. **The emotion-vs-energy test.** Play a loud sad song and a quiet happy song back to back. The loud sad one should be bright but cool and diffuse. The quiet happy one should be dimmer but warm and tight. If both end up looking the same because loudness dominates, the color-vs-brightness separation (Principle 3) is broken.
5. **The DHH communication test.** Before running implementation, confirm with a teammate: watch the visuals with audio off, see if they can identify chorus/verse/drop transitions and describe the emotional feel of the song. If yes, the piece is communicating.

### Technical tests (required but not sufficient)

6. **Build smoke test.** Fresh build on iOS 26.2 simulator. Open any analyzed song. Toggle God Rays on with audio paused — expect soft static rays centered slightly above middle + slowly drifting dust motes. If black: check target membership of `GodRays.metal`.
7. **Low-end → brightness test.** Play `SoundSeen/SoundSeen/Resources/Knock2 - crank the bass play the muzik.mp3` (title suggests bass-forward trap — perfect stress test). Rays should visibly pump with kick drums but *not* with hi-hats. This confirms the bass-gated coupling, not raw `beatPulse`.
8. **Snare bloom test.** Play `SoundSeen/SoundSeen/Resources/BLIND RAVE MIX.mp3`. Watch for brief bright flashes (~300ms) distinct from the steady bass pump — these are snare/transient-driven bloom pulses.
9. **Accessibility test.** Simulator Settings → Accessibility → Reduce Motion **ON**. Dust motes slow (don't freeze completely — Principle 6), rays dim to ≤30% regardless of HUD slider position. HUD slider can still dim further but cannot brighten past 0.3. A drop should still *feel* like a drop, just gentler.
10. **Performance.** Xcode Instruments → Metal System Trace during playback. GPU time per frame target <6ms. Core Animation FPS ≥58. If it dips, drop the ray-march loop from 16 to 12 taps — visual difference is minor, emotional difference is zero.
11. **Toggle-off regression.** Turn God Rays off → existing 13 layers should render identically to before this change (insertion is additive, not replacing any existing layer).

---

## Out of Scope (intentional)

- True TouchDesigner-style frame-feedback loop (would require ping-pong textures + `MTKView`; rejected in favor of "cinematic light" over "fluid feedback"). The snare-feedback coupling is approximated via the bloom envelope instead.
- Kaleidoscopic symmetry / mirror warping (would need its own separate shader).
- Modifying or removing any of the 13 existing visualization layers.
- Backend changes — the existing analysis pipeline already produces everything the shader needs.
- A full HUD redesign — just add two controls to the existing row.

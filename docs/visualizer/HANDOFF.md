# Visualizer Session Handoff

Short context primer for anyone (Claude or human) picking up the god-rays visualizer work. For the full design see `god-rays-plan.md` in this folder.

## What this is

Design documentation for a new optional hero visualizer layer being added to SoundSeen's `AnalyzedPlayerView`. It's a Klsr-inspired cinematic god-rays + dust-motes effect driven by a Metal fragment shader, sitting alongside (not replacing) the existing 13 SwiftUI visualization layers.

## TL;DR

We're translating the motion language of TikTok audiovisual artist Klsr (@klsr.av) — whose work uses low-end-to-brightness and snare-to-bloom couplings to make music feel emotionally cinematic — into one new toggle-able visualizer in SoundSeen. The goal is an art piece that makes DHH users *feel* music, not a dashboard of reactive elements.

## The one thing to remember

**The primary success criterion is emotional, not technical.** If a technical choice fights the emotional experience, cut it. The six "Emotional Design Principles" at the top of `god-rays-plan.md` are the north star for every implementation decision downstream. Read them before touching anything.

## Team

BENEV capstone: Benson Vo, Vincent Liu, Edward Lee, Nicole Zhou, Evan Chang.

- **Nicole** — designed this visualizer. Working from Windows, so she can edit Swift code but **cannot build or run the iOS app locally**. She needs a Mac-having collaborator to verify visuals.
- **Evan** — created the Xcode project. Likely the best build/test partner for this work.

## Key constraints

- **iOS 26.2 deployment target** — all modern SwiftUI shader APIs (`.layerEffect`, `ShaderLibrary`, `Shader(function:arguments:)`) are fully available. This is what makes the approach viable without `MTKView` + `UIViewRepresentable`.
- **Additive only** — the plan does not modify or remove any existing visualization layer. The new layer is gated behind a user toggle.
- **No backend changes needed** — the existing `soundseen-backend/` analysis pipeline already produces every signal the shader consumes (beats, onsets, flux spikes, 8 spectral bands, valence/arousal, sections).

## What was produced this session

- `god-rays-plan.md` — full design doc: emotional principles, shader design (Metal pseudocode, argument signature), signal pipeline (Swift side), HUD integration, risks, verification tests. All implementation hooks include file paths with line numbers into the current codebase.

No code was written yet. Implementation is the next step and requires a Mac.

## To continue this work

### Starting a fresh Claude Code session on a MacBook

```
git fetch && git checkout nicole/god-rays-plan
```

Then open Claude Code in the repo and say something like:

> I'm continuing SoundSeen capstone work on the `nicole/god-rays-plan` branch. Please read `docs/visualizer/HANDOFF.md` and `docs/visualizer/god-rays-plan.md` to catch up. I'd like to start implementing [the shader / the SwiftUI wrapper / the HUD toggle].

The plan is detailed enough that Claude can go straight into implementation after reading it.

### If you're a teammate (not Nicole)

Read `god-rays-plan.md` → "Emotional Design Principles" first. Those are not negotiable — they're the reason the rest of the plan exists. The technical design flows from them. Don't optimize a detail that breaks a principle without flagging it to Nicole.

### First implementation steps

From `god-rays-plan.md` → "Critical Files":

1. Create `SoundSeen/SoundSeen/Shaders/GodRays.metal` (new file, ~70 LoC). Add to the SoundSeen app target's Compile Sources in Xcode — this is the most common silent-failure point.
2. Create `SoundSeen/SoundSeen/Views/analyzed/GodRayVisualizer.swift` (new file, ~220 LoC). Use `Views/analyzed/FluxHaloLayer.swift` as the nearest existing pattern.
3. Extend `Services/VisualizerState.swift` with `bassEnergySmoothed` and `sectionBuildEnvelope` derived properties.
4. Insert the new view into `Views/AnalyzedPlayerView.swift` ZStack between `CymaticCenter` (line 82-88) and `FluxHaloLayer` (line 90).
5. Add the HUD toggle + intensity slider.

Run the emotional verification tests (the "oh" test, the silence test, the hi-hat test) before the technical ones — they're what matters for the accessibility mission.

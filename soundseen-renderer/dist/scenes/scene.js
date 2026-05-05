// Scene contract. Each biome's visual treatment implements this.
//
// The runtime owns the renderer, camera, and timeline; scenes own their
// own meshes/materials/uniforms. A scene's render() is called once per
// output video frame with the full CompositionSpec (so scenes can scan
// onset_track / phrase_track for window-spawning behavior) and a fully-
// resolved FrameContext (with interpolated per-frame timbre).
export {};
//# sourceMappingURL=scene.js.map
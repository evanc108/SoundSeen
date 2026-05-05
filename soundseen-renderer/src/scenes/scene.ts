// Scene contract. Each biome's visual treatment implements this.
//
// The runtime owns the renderer, camera, and timeline; scenes own their
// own meshes/materials/uniforms. A scene's render() is called once per
// output video frame with the full CompositionSpec (so scenes can scan
// onset_track / phrase_track for window-spawning behavior) and a fully-
// resolved FrameContext (with interpolated per-frame timbre).

import * as THREE from "three";
import type { CompositionSpec, FrameContext } from "../types.js";

export interface Scene {
  /// Three.js scene root the runtime adds to the WebGLRenderer.
  readonly object3D: THREE.Scene;
  /// Per-scene camera. Runtime reads it for rendering and may
  /// modulate position based on the section's CameraMove.
  readonly camera: THREE.Camera;
  /// Called once per output frame.
  render(spec: CompositionSpec, ctx: FrameContext): void;
  /// Free GPU resources.
  dispose(): void;
}

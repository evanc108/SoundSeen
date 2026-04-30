// Scene contract. Each biome's visual treatment implements this.
//
// The runtime owns the renderer, camera, and timeline; scenes own their
// own meshes/materials/uniforms. A scene's render() is called once per
// output video frame with a fully-resolved FrameContext.

import * as THREE from "three";
import type { FrameContext } from "../types";

export interface Scene {
  /// Three.js scene root the runtime adds to the WebGLRenderer.
  readonly object3D: THREE.Scene;
  /// Per-scene camera. Runtime reads it for rendering and may
  /// modulate position based on the section's CameraMove.
  readonly camera: THREE.Camera;
  /// Called once per output frame.
  render(ctx: FrameContext): void;
  /// Free GPU resources.
  dispose(): void;
}

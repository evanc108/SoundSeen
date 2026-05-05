// Scene registry. The plan calls for four biome scenes:
// serene_dawn, euphoric_bloom, intense_storm, melancholic_rain.
// MVP scaffold ships with serene_dawn; the rest fall back to it
// until they're implemented in Phase 4.

import type { SceneName } from "../types.js";
import type { Scene } from "./scene.js";
import { SereneDawnScene } from "./serene_dawn.js";

type SceneFactory = () => Scene;

const REGISTRY: Record<SceneName, SceneFactory> = {
  serene_dawn:      () => new SereneDawnScene(),
  euphoric_bloom:   () => new SereneDawnScene(), // TODO Phase 4
  intense_storm:    () => new SereneDawnScene(), // TODO Phase 4
  melancholic_rain: () => new SereneDawnScene(), // TODO Phase 4
};

export function makeScene(name: SceneName): Scene {
  const factory = REGISTRY[name];
  if (!factory) {
    throw new Error(`Unknown scene: ${name}`);
  }
  return factory();
}

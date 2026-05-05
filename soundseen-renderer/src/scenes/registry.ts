// Scene registry. Four biome scenes, all implemented:
// serene_dawn, euphoric_bloom, intense_storm, melancholic_rain.
// Renderer picks one per section based on the biome the section's
// average (V, A) falls into. CompositionSpec is the source of truth.

import type { SceneName } from "../types.js";
import type { Scene } from "./scene.js";
import { SereneDawnScene }      from "./serene_dawn.js";
import { EuphoricBloomScene }   from "./euphoric_bloom.js";
import { IntenseStormScene }    from "./intense_storm.js";
import { MelancholicRainScene } from "./melancholic_rain.js";

type SceneFactory = () => Scene;

const REGISTRY: Record<SceneName, SceneFactory> = {
  serene_dawn:      () => new SereneDawnScene(),
  euphoric_bloom:   () => new EuphoricBloomScene(),
  intense_storm:    () => new IntenseStormScene(),
  melancholic_rain: () => new MelancholicRainScene(),
};

export function makeScene(name: SceneName): Scene {
  const factory = REGISTRY[name];
  if (!factory) {
    throw new Error(`Unknown scene: ${name}`);
  }
  return factory();
}

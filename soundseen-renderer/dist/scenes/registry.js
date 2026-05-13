// Scene registry. Four biome scenes, all implemented:
// serene_dawn, euphoric_bloom, intense_storm, melancholic_rain.
// Renderer picks one per section based on the biome the section's
// average (V, A) falls into. CompositionSpec is the source of truth.
import { SereneDawnScene } from "./serene_dawn.js";
import { EuphoricBloomScene } from "./euphoric_bloom.js";
import { IntenseStormScene } from "./intense_storm.js";
import { MelancholicRainScene } from "./melancholic_rain.js";
const REGISTRY = {
    serene_dawn: () => new SereneDawnScene(),
    euphoric_bloom: () => new EuphoricBloomScene(),
    intense_storm: () => new IntenseStormScene(),
    melancholic_rain: () => new MelancholicRainScene(),
};
export function makeScene(name) {
    const factory = REGISTRY[name];
    if (!factory) {
        throw new Error(`Unknown scene: ${name}`);
    }
    return factory();
}
//# sourceMappingURL=registry.js.map
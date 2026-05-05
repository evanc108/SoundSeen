// Serene dawn — high-V, low-A biome.
//
// Slow-drifting noise field in warm analogous palette (cream + sienna)
// with soft bokeh particles and a gentle radial god-ray wash. Beats
// register as soft ripples; drops are heavily softened — this biome
// doesn't punch.
//
// Palette is intentionally ANALOGOUS, not complementary, per
// Schloss & Palmer (2011) "Aesthetic response to color combinations":
// analogous color pairs are perceived as more harmonious than
// complementary, contradicting Itten's classical doctrine. A low-tension
// biome should sit in the harmony zone. Earlier teal+peach (~160° apart)
// read as quietly tense; cream+sienna sits at ~25-35° hue interval —
// firmly analogous.
//
// MVP-level implementation: the goal here is the SHAPE of the pipeline,
// not flagship visual quality. Iterate on the fragment shader (or swap in
// Pavel Dobryakov's WebGL fluid sim later) to push fidelity.
import * as THREE from "three";
import { OnsetParticleEmitter } from "./onset_emitter.js";
const BG_VERTEX = /* glsl */ `
  varying vec2 vUv;
  void main() {
    vUv = uv;
    gl_Position = vec4(position, 1.0);
  }
`;
// Two octaves of value noise sampled in slow-drifting UV space, blended
// with a radial gradient so the center reads as the light source.
const BG_FRAGMENT = /* glsl */ `
  precision highp float;
  varying vec2 vUv;
  uniform float uTime;
  uniform float uBeat;
  uniform float uDrop;
  uniform vec3  uColorCore;
  uniform vec3  uColorEdge;
  uniform float uSaturation;
  uniform float uBrightness;
  // v3 per-frame timbre.
  uniform float uCentroid;        // 0..1 — Marks 1989, brightness lift
  uniform float uHarmonicRatio;   // 0..1 — softer when high (Bouba/Kiki)
  uniform float uChromaStrength;  // 0..1 — Itoh 2017, saturation lock-in
  uniform float uModeWarm;        // -1..+1 — minor cool / major warm
  uniform float uHueDistance;     // 0..1 — Schloss & Palmer; high = tense
  uniform float uPhrasePulse;     // 0..1 — Krumhansl phrase boundary

  // Hash without sin — cheap, no driver-specific drift.
  float hash(vec2 p) {
    p = fract(p * vec2(443.897, 441.423));
    p += dot(p, p.yx + 19.19);
    return fract((p.x + p.y) * p.x);
  }

  float valueNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
  }

  vec3 desaturate(vec3 col, float amt) {
    float l = dot(col, vec3(0.299, 0.587, 0.114));
    return mix(vec3(l), col, amt);
  }

  void main() {
    vec2 uv = vUv;
    // Bouba/Kiki applied to the noise field itself: high harmonic_ratio
    // (tonal/sustained) → softer, smoother noise; low → more granular.
    // Modulate sample frequency so tonal passages read as smoother.
    float boubaScale = mix(3.0, 1.8, uHarmonicRatio);
    vec2 p = uv * boubaScale + vec2(uTime * 0.03, uTime * 0.018);
    float n = valueNoise(p) * 0.6 + valueNoise(p * 2.1) * 0.4;

    // Radial falloff so the frame has a visible "source" rather than
    // reading as a flat field.
    float r = length(uv - 0.5) * 1.8;
    float vignette = smoothstep(1.0, 0.2, r);

    // Beat ripple — small radial pulse that biases the noise outward.
    float ripple = uBeat * (1.0 - smoothstep(0.0, 0.6, abs(r - uBeat * 0.4)));

    float lum = vignette * (0.5 + 0.5 * n) + ripple * 0.25;
    lum += uDrop * 0.20 * (1.0 - r);
    // Marks 1989: bright timbre lifts visual luminance.
    lum += uCentroid * 0.18;

    vec3 col = mix(uColorEdge, uColorCore, lum);

    // Itoh 2017: tonal passages (high chroma_strength) lock saturation
    // toward the core; atonal noise smears toward the edge desaturate.
    float chromaSat = mix(0.85, 1.10, uChromaStrength);
    col = desaturate(col, uSaturation * chromaSat);

    // Mode bias: minor → slight cool tilt, major → slight warm tilt.
    // Small effect (±3%) so it doesn't override the biome identity.
    col.r *= 1.0 + uModeWarm * 0.03;
    col.b *= 1.0 - uModeWarm * 0.03;

    // Schloss & Palmer hue_distance: tension splits the RGB channels
    // slightly along x, reading as quiet chromatic dissonance. Subtle
    // here — Serene shouldn't go full prismatic.
    if (uHueDistance > 0.20) {
      vec2 splitOff = vec2(uHueDistance * 0.004, 0);
      vec2 sp = uv * boubaScale + vec2(uTime * 0.03, uTime * 0.018);
      float nR = valueNoise(sp + splitOff) * 0.6 + valueNoise((sp + splitOff) * 2.1) * 0.4;
      float nB = valueNoise(sp - splitOff) * 0.6 + valueNoise((sp - splitOff) * 2.1) * 0.4;
      vec3 colR = mix(uColorEdge, uColorCore, vignette * (0.5 + 0.5 * nR) + ripple * 0.25);
      vec3 colB = mix(uColorEdge, uColorCore, vignette * (0.5 + 0.5 * nB) + ripple * 0.25);
      col.r = mix(col.r, colR.r, uHueDistance * 0.5);
      col.b = mix(col.b, colB.b, uHueDistance * 0.5);
    }

    // Phrase boundary: brief overall lift so the listener gets a
    // visual anchor at structural moments.
    col += vec3(uPhrasePulse * 0.06);

    col *= uBrightness;
    gl_FragColor = vec4(col, 1.0);
  }
`;
export class SereneDawnScene {
    object3D;
    camera;
    bgMaterial;
    particles;
    particleMaterial;
    particlePositions;
    onsetEmitter;
    constructor() {
        this.object3D = new THREE.Scene();
        this.camera = new THREE.PerspectiveCamera(50, 16 / 9, 0.1, 100);
        this.camera.position.set(0, 0, 4);
        // Full-screen background quad with the noise/god-ray fragment shader.
        this.bgMaterial = new THREE.ShaderMaterial({
            vertexShader: BG_VERTEX,
            fragmentShader: BG_FRAGMENT,
            uniforms: {
                uTime: { value: 0 },
                uBeat: { value: 0 },
                uDrop: { value: 0 },
                // Analogous warm palette — Schloss & Palmer (2011). Both hues
                // sit in the 25-35° amber/cream/sienna range so the pair reads
                // harmonious rather than tense.
                uColorCore: { value: new THREE.Color("#fff0c2") }, // soft cream
                uColorEdge: { value: new THREE.Color("#a8654a") }, // warm sienna
                uSaturation: { value: 1.0 },
                uBrightness: { value: 1.0 },
                uCentroid: { value: 0.5 },
                uHarmonicRatio: { value: 0.7 },
                uChromaStrength: { value: 0.0 },
                uModeWarm: { value: 0.0 },
                uHueDistance: { value: 0.2 },
                uPhrasePulse: { value: 0.0 },
            },
            depthTest: false,
            depthWrite: false,
        });
        const bg = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), this.bgMaterial);
        bg.frustumCulled = false;
        bg.renderOrder = -10;
        this.object3D.add(bg);
        // Soft drifting bokeh particles in the foreground.
        const N = 220;
        this.particlePositions = new Float32Array(N * 3);
        for (let i = 0; i < N; i++) {
            this.particlePositions[i * 3 + 0] = (Math.random() - 0.5) * 6;
            this.particlePositions[i * 3 + 1] = (Math.random() - 0.5) * 4;
            this.particlePositions[i * 3 + 2] = -(Math.random() * 3.0);
        }
        const geo = new THREE.BufferGeometry();
        geo.setAttribute("position", new THREE.BufferAttribute(this.particlePositions, 3));
        // Bokeh stays in the warm-cream family so the particles read as
        // part of the same scene and don't introduce a third hue.
        this.particleMaterial = new THREE.PointsMaterial({
            color: new THREE.Color("#fff5dc"),
            size: 0.04,
            sizeAttenuation: true,
            transparent: true,
            opacity: 0.55,
            blending: THREE.AdditiveBlending,
            depthWrite: false,
        });
        this.particles = new THREE.Points(geo, this.particleMaterial);
        this.object3D.add(this.particles);
        // Onset particles — soft cream tint, smaller max size for a
        // restrained biome. Each musical onset becomes one short-lived
        // bokeh whose ADSR envelope mirrors the source instrument.
        this.onsetEmitter = new OnsetParticleEmitter({
            baseColor: new THREE.Color("#fff5dc"),
            maxSize: 18,
            poolSize: 192,
        });
        this.object3D.add(this.onsetEmitter.object3D);
    }
    render(spec, ctx) {
        const u = this.bgMaterial.uniforms;
        u.uTime.value = ctx.t;
        // Soften beats — this biome doesn't punch on the beat.
        u.uBeat.value = ctx.beatPulse * 0.45;
        u.uDrop.value = ctx.dropImpulse * 0.30;
        // V&M continuous palette modulation × section-intent multiplier.
        // The section value is V&M baseline × section-intent already, but
        // we still want frame-level interpolation between emotion samples
        // so the visuals don't step at 0.5s boundaries.
        const sectionGainSat = ctx.section?.saturation ?? 1.0;
        const sectionGainBri = ctx.section?.brightness ?? 1.0;
        u.uSaturation.value = ctx.vmSaturation * (sectionGainSat / Math.max(0.5, ctx.vmSaturation));
        u.uBrightness.value = ctx.vmBrightness * (sectionGainBri / Math.max(0.5, ctx.vmBrightness));
        // v3 — pipe per-frame timbre + section mode into the shader.
        u.uCentroid.value = ctx.audio.centroid;
        u.uHarmonicRatio.value = ctx.audio.harmonicRatio;
        u.uChromaStrength.value = ctx.audio.chromaStrength;
        const modeStrength = ctx.section?.mode_strength ?? 0;
        const modeWarm = ctx.section?.mode === "minor" ? -modeStrength : modeStrength;
        u.uModeWarm.value = modeWarm;
        u.uHueDistance.value = ctx.section?.hue_distance ?? 0.2;
        u.uPhrasePulse.value = ctx.phrasePulse;
        // Gentle drift so the bokeh feels alive, not stamped.
        const pos = this.particles.geometry.getAttribute("position");
        for (let i = 0; i < pos.count; i++) {
            const y = this.particlePositions[i * 3 + 1] + Math.sin(ctx.t * 0.18 + i) * 0.0015;
            pos.setY(i, y);
        }
        pos.needsUpdate = true;
        this.particleMaterial.opacity = 0.45 + ctx.beatPulse * 0.20;
        // Onset emitter walks (prev, t] and spawns per-onset particles.
        this.onsetEmitter.update(spec, ctx);
    }
    dispose() {
        this.bgMaterial.dispose();
        this.particleMaterial.dispose();
        this.particles.geometry.dispose();
        this.onsetEmitter.dispose();
    }
}
//# sourceMappingURL=serene_dawn.js.map
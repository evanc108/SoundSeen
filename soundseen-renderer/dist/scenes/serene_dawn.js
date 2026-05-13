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
import { hash1, hash2 } from "./lib/deterministic_hash.js";
import { SereneSunScene } from "./serene_sun.js";
import { Skyline } from "./effects/skyline.js";
import { GodRays } from "./effects/godrays.js";
import { cinematicCameraDeltas } from "./lib/cinematic_camera.js";
import { TextureOverlay } from "./effects/texture_overlay.js";
import { curlNoise2 } from "./curl_noise.js";
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
    // Domain warp: perturb sample coords by a second noise lookup.
    // Costs 2 extra noise reads but transforms a static-feeling fbm
    // into a flowing liquid/smoke field — reads as "alive."
    vec2 warp = vec2(
      valueNoise(p + vec2(1.7, 9.2)),
      valueNoise(p + vec2(8.3, 2.8))
    ) * 0.30;
    vec2 wp = p + warp;
    float n = valueNoise(wp) * 0.6 + valueNoise(wp * 2.1) * 0.4;

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

    // (Schloss & Palmer hue_distance RGB-split moved to the
    // ChromaticAberrationEffect post-pass — it now sees the bloom halo,
    // reading like a real lens rather than a per-fragment channel skew.)

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
    sun;
    skyline;
    godrays;
    texture;
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
            this.particlePositions[i * 3 + 0] = (hash1(i + 1) - 0.5) * 6;
            this.particlePositions[i * 3 + 1] = (hash2(i, 1) - 0.5) * 4;
            this.particlePositions[i * 3 + 2] = -(hash2(i, 2) * 3.0);
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
        // Serene Dawn hero stack — low warm sun + cloud strata, distant
        // rolling-hills skyline, warm-gold god-rays.
        this.sun = new SereneSunScene();
        this.object3D.add(this.sun.object3D);
        this.skyline = new Skyline({
            buildingColor: new THREE.Color("#4a3a2a"), // warm dark hills
            windowColor: new THREE.Color("#fff2d4"), // unused (no windows)
            flickerColor: new THREE.Color("#ffd9a0"),
            hazeTint: new THREE.Color("#3a2818"),
            shape: "hills",
            enableFlicker: false, // Serene doesn't punch with lightning
            windowReactivity: 0,
            farY: 0.6,
            nearY: 0.0,
        });
        this.object3D.add(this.skyline.object3D);
        // Warm cream-gold god-rays sweeping from the sun position.
        this.godrays = new GodRays({
            shaftColor: new THREE.Color("#ffe2a8"),
            warmTint: new THREE.Color("#ffc878"),
            sunPos: new THREE.Vector2(0.55, 0.42), // matches sun
            intensityBase: 0.18,
            intensityScale: 0.85,
        });
        this.object3D.add(this.godrays.object3D);
        this.texture = new TextureOverlay({
            tintColor: new THREE.Color("#ffe0c0"),
        });
        this.object3D.add(this.texture.object3D);
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
        // Curl-noise drift — divergence-free 2D flow per particle. Reads as
        // "alive" rather than "looping" (sin-drift bunches particles into
        // visible oscillations). Each particle samples a slowly-translating
        // noise field; rolloff still clamps the vertical range so bright
        // mixes let particles fill upper frame.
        const rolloff = ctx.audio.rolloff;
        const ceilY = 1.5 * rolloff;
        const floorY = -1.5 * (1.0 - rolloff * 0.5);
        const pos = this.particles.geometry.getAttribute("position");
        const dt = 1 / 60;
        const flowScale = 0.030;
        const sampleScale = 0.40;
        const tDrift = ctx.t * 0.05;
        // Pitch direction: rising melody nudges particles up, falling nudges
        // down. Small bias so it composes with curl-noise rather than
        // overwhelming it.
        const pitchBias = ctx.audio.pitchDirection * 0.060;
        for (let i = 0; i < pos.count; i++) {
            const ix3 = i * 3;
            const px = this.particlePositions[ix3];
            const py = this.particlePositions[ix3 + 1];
            const [vx, vy] = curlNoise2(px * sampleScale + tDrift, py * sampleScale);
            let x = px + vx * flowScale * dt;
            let y = py + (vy * flowScale + pitchBias) * dt;
            if (y > ceilY)
                y = ceilY;
            else if (y < floorY)
                y = floorY;
            this.particlePositions[ix3] = x;
            this.particlePositions[ix3 + 1] = y;
            pos.setX(i, x);
            pos.setY(i, y);
        }
        pos.needsUpdate = true;
        this.particleMaterial.opacity = 0.45 + ctx.beatPulse * 0.20;
        // Onset emitter walks (prev, t] and spawns per-onset particles.
        this.onsetEmitter.update(spec, ctx);
        const bands = ctx.audio.melBands;
        for (let k = 0; k < 8; k++) {
            this.onsetEmitter.spawnBandPulse(k, bands[k] ?? 0, ctx.t, ctx);
        }
        // Hero stack: sun + skyline + god-rays driven by audio features.
        this.sun.update(spec, ctx);
        this.skyline.update(spec, ctx);
        this.godrays.update(spec, ctx);
        this.texture.update(spec, ctx);
        // Cinematic camera — Serene wants gentler moves than Melancholic
        // (less sway, no shake — calm by definition). Sectional dolly
        // drifts forward slowly through the section.
        const sp = ctx.sectionProgress;
        const cam = cinematicCameraDeltas(ctx, {
            sway: 0.5,
            push: 0.6,
            phrase: 0.7,
            shake: 0.15, // near zero — Serene doesn't shake
            roll: 0.4,
        });
        this.camera.position.set(0, 0.08, 4 - sp * 0.3).add(cam.posDelta);
        this.camera.lookAt(0, 0, 0);
        this.camera.rotation.z = cam.rollZ;
        this.camera.updateProjectionMatrix();
    }
    dispose() {
        this.bgMaterial.dispose();
        this.particleMaterial.dispose();
        this.particles.geometry.dispose();
        this.onsetEmitter.dispose();
        this.sun.dispose();
        this.skyline.dispose();
        this.godrays.dispose();
        this.texture.dispose();
    }
}
//# sourceMappingURL=serene_dawn.js.map
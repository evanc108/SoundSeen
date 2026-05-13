// Intense storm — low-V, high-A biome.
//
// High-contrast turbulent noise field in blood-red and electric blue
// (a deliberate near-COMPLEMENTARY pairing — Schloss & Palmer 2011
// rate this as less harmonious, but for the Intense biome that's
// EXACTLY the affect you want; tension is the identity). Procedural
// lightning bolts fire on drops and downbeats. Frame strobes on
// heavy beats per Itti & Koch's saliency stacking — luminance
// contrast is the strongest bottom-up attention captor.
//
// V&M: high A → S≈0.95; brightness counter-modulated to ~0.85.
// Atmosphere is dark by design so the strobe punches.
//
// Bouba/Kiki: percussive content (typical for Intense) → high
// angularity → SHARP edges, hard silhouettes. Lightning bolts are
// jagged polylines, particles are square shards rather than round
// soft points. (Implementation uses Points but with smaller, harder
// material settings.)
import * as THREE from "three";
import { OnsetParticleEmitter } from "./onset_emitter.js";
import { hash1, hash2 } from "./lib/deterministic_hash.js";
import { IntenseLightningScene } from "./intense_lightning.js";
import { Skyline } from "./effects/skyline.js";
import { GodRays } from "./effects/godrays.js";
import { EventLayer } from "./effects/event_layer.js";
import { cinematicCameraDeltas } from "./lib/cinematic_camera.js";
import { TextureOverlay } from "./effects/texture_overlay.js";
const BG_VERTEX = /* glsl */ `
  varying vec2 vUv;
  void main() {
    vUv = uv;
    gl_Position = vec4(position, 1.0);
  }
`;
const BG_FRAGMENT = /* glsl */ `
  precision highp float;
  varying vec2 vUv;
  uniform float uTime;
  uniform float uBeat;
  uniform float uDownbeat;
  uniform float uDrop;
  uniform float uTension;
  uniform vec3  uColorRed;
  uniform vec3  uColorBlue;
  uniform vec3  uColorBlack;
  uniform float uSaturation;
  uniform float uBrightness;
  uniform float uCentroid;        // Marks 1989 — bright timbre lifts blue accents
  uniform float uHarmonicRatio;
  uniform float uZCR;             // sibilance density → grain
  uniform float uChromaStrength;
  uniform float uModeWarm;
  uniform float uHueDistance;
  uniform float uPhrasePulse;

  float hash(vec2 p) {
    p = fract(p * vec2(443.897, 441.423));
    p += dot(p, p.yx + 19.19);
    return fract((p.x + p.y) * p.x);
  }
  float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x),
               mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
  }
  // Two-octave fractal noise — turbulent stormcloud feel without
  // expensive multi-octave summation.
  float fbm(vec2 p) {
    return noise(p) * 0.65 + noise(p * 2.13) * 0.35;
  }

  vec3 desaturate(vec3 col, float amt) {
    float l = dot(col, vec3(0.299, 0.587, 0.114));
    return mix(vec3(l), col, amt);
  }

  void main() {
    vec2 uv = vUv;
    vec2 d = uv - vec2(0.5, 0.5);

    // Stormcloud — fbm with horizontal scrolling, shaped by a
    // top-heavy gradient so the cloud lives in the upper half.
    // Bouba/Kiki on cloud frequency: low harmonic_ratio → tighter,
    // higher-freq turbulence (more chaotic); high → broader, slower.
    float cloudFreqX = mix(3.5, 2.0, uHarmonicRatio);
    vec2 p = uv * vec2(cloudFreqX, cloudFreqX * 0.65) + vec2(uTime * 0.10, uTime * 0.04);
    // Domain warp: turbulent flow rather than static fbm cloud.
    // The warp itself drifts with time so the perturbation isn't
    // frozen — reads as wind pushing the cloud, not noise stamped on it.
    vec2 warp = vec2(
      fbm(p + vec2(4.1, 1.3) + uTime * 0.06),
      fbm(p + vec2(2.7, 5.9) - uTime * 0.04)
    ) * 0.40;
    float cloud = fbm(p + warp);
    // Pow sharpening also modulated — high HR keeps cloud softer.
    float cloudPow = mix(2.1, 1.4, uHarmonicRatio);
    cloud = pow(cloud, cloudPow);

    // Color: red dominates, blue accent in dim areas (contrast singleton
    // per Itti-Koch — opposite hue captures attention against the warm field).
    vec3 col = mix(uColorBlack, uColorRed, cloud);
    col = mix(col, uColorBlue, smoothstep(0.45, 0.20, cloud) * 0.45);

    // Beat strobe — abrupt luminance increment on heavy beats.
    // Itti & Koch (2001) — sudden luminance changes are the strongest
    // bottom-up attention captor. Keep the strobe brief & jerky.
    if (uDownbeat > 0.4) {
      col += vec3(uDownbeat * 0.55);
    }

    // Drop: full-frame fracture — invert + flash.
    col = mix(col, vec3(1.0) - col, uDrop * 0.50);
    col += vec3(uDrop * 0.35);

    // Tension drives a screen-warping shake-feel via low-amplitude UV
    // perturbation contributing to the cloud sample (above we used
    // raw uv; this is a second pass for "pressure" feel).
    float pressure = fbm(uv * 5.0 + uTime * 0.5) * uTension * 0.20;
    col += vec3(pressure * 0.4, pressure * 0.1, pressure * 0.5);

    // Bright timbre lifts the electric-blue contrast singleton.
    col.b += uCentroid * 0.12 * smoothstep(0.40, 0.10, cloud);

    // (Inline ZCR grain and frame-edge vignette removed — NoiseEffect
    // and VignetteEffect post-passes replace them and respect tonemap
    // ordering. ZCR still drives the post-grain opacity per frame.)
    float r = length(d) * 1.4;

    float chromaSat = mix(0.85, 1.10, uChromaStrength);
    col = desaturate(col, uSaturation * chromaSat);

    col.r *= 1.0 + uModeWarm * 0.04;
    col.b *= 1.0 - uModeWarm * 0.04;

    // (Inline hue_distance cloud channel-split removed — the
    // ChromaticAberration post-pass replaces it. Intense's CA
    // intensity is already biased high by the per-frame mutator.)

    // Phrase pulse: brief reverse-vignette flash at frame edges so
    // structural moments register as a "frame closing in."
    col += vec3(uPhrasePulse * 0.10) * (1.0 - smoothstep(0.7, 0.2, r));

    col *= uBrightness;
    gl_FragColor = vec4(col, 1.0);
  }
`;
export class IntenseStormScene {
    object3D;
    camera;
    bgMaterial;
    particles;
    particleMaterial;
    positions;
    static PARTICLE_COUNT = 220;
    // Lightning bolts: each bolt is a short-lived line segment set.
    boltGeometry;
    boltMaterial;
    boltLines;
    boltBuffer;
    onsetEmitter;
    static MAX_BOLT_VERTS = 256;
    prevDownbeat = 0;
    prevDrop = 0;
    hero;
    skyline;
    godrays;
    events;
    texture;
    constructor() {
        this.object3D = new THREE.Scene();
        this.camera = new THREE.PerspectiveCamera(50, 16 / 9, 0.1, 100);
        this.camera.position.set(0, 0, 4);
        this.bgMaterial = new THREE.ShaderMaterial({
            vertexShader: BG_VERTEX,
            fragmentShader: BG_FRAGMENT,
            uniforms: {
                uTime: { value: 0 },
                uBeat: { value: 0 },
                uDownbeat: { value: 0 },
                uDrop: { value: 0 },
                uTension: { value: 0.5 },
                uColorRed: { value: new THREE.Color("#c81e2a") }, // blood red
                uColorBlue: { value: new THREE.Color("#3868d8") }, // electric blue
                uColorBlack: { value: new THREE.Color("#0a0612") }, // dark base
                uSaturation: { value: 1.0 },
                uBrightness: { value: 1.0 },
                uCentroid: { value: 0.5 },
                uHarmonicRatio: { value: 0.3 },
                uZCR: { value: 0.3 },
                uChromaStrength: { value: 0.0 },
                uModeWarm: { value: 0.0 },
                uHueDistance: { value: 0.7 },
                uPhrasePulse: { value: 0.0 },
            },
            depthTest: false,
            depthWrite: false,
        });
        const bg = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), this.bgMaterial);
        bg.frustumCulled = false;
        bg.renderOrder = -10;
        this.object3D.add(bg);
        // Sharp percussive shards — small, hard-edged points in pale electric.
        const N = IntenseStormScene.PARTICLE_COUNT;
        this.positions = new Float32Array(N * 3);
        for (let i = 0; i < N; i++) {
            this.positions[i * 3 + 0] = (hash1(i + 1) - 0.5) * 7;
            this.positions[i * 3 + 1] = (hash2(i, 1) - 0.5) * 5;
            this.positions[i * 3 + 2] = -hash2(i, 2) * 3.0;
        }
        const pgeo = new THREE.BufferGeometry();
        pgeo.setAttribute("position", new THREE.BufferAttribute(this.positions, 3));
        this.particleMaterial = new THREE.PointsMaterial({
            color: new THREE.Color("#a8c8ff"),
            size: 0.025,
            sizeAttenuation: true,
            transparent: true,
            opacity: 0.45,
            blending: THREE.AdditiveBlending,
            depthWrite: false,
        });
        this.particles = new THREE.Points(pgeo, this.particleMaterial);
        this.object3D.add(this.particles);
        // Lightning lines — preallocated buffer, written each frame.
        this.boltBuffer = new Float32Array(IntenseStormScene.MAX_BOLT_VERTS * 3);
        this.boltGeometry = new THREE.BufferGeometry();
        this.boltGeometry.setAttribute("position", new THREE.BufferAttribute(this.boltBuffer, 3));
        this.boltMaterial = new THREE.LineBasicMaterial({
            color: new THREE.Color("#e8f0ff"),
            transparent: true,
            opacity: 0.0,
            blending: THREE.AdditiveBlending,
            depthWrite: false,
        });
        this.boltLines = new THREE.LineSegments(this.boltGeometry, this.boltMaterial);
        this.object3D.add(this.boltLines);
        // Per-onset shards — pale electric tint, smaller pool because
        // Intense's onsets tend to be sharp & sparse.
        this.onsetEmitter = new OnsetParticleEmitter({
            baseColor: new THREE.Color("#a8c8ff"),
            maxSize: 22,
            poolSize: 192,
        });
        this.object3D.add(this.onsetEmitter.object3D);
        // Intense hero stack: dark turbulent storm wall + persistent
        // lightning afterglow (each bolt leaves a fading trace 1.4 s).
        this.hero = new IntenseLightningScene();
        this.object3D.add(this.hero.object3D);
        // Crags silhouette skyline — jagged stormwall in the lower frame.
        this.skyline = new Skyline({
            buildingColor: new THREE.Color("#0a1020"),
            windowColor: new THREE.Color("#a0c8ff"),
            flickerColor: new THREE.Color("#e8f0ff"),
            hazeTint: new THREE.Color("#040814"),
            shape: "crags",
            enableFlicker: true,
            windowReactivity: 0.5,
            farY: -0.5,
            nearY: -1.2,
        });
        this.object3D.add(this.skyline.object3D);
        // Cold electric god-rays from above-center.
        this.godrays = new GodRays({
            shaftColor: new THREE.Color("#a8d4ff"),
            warmTint: new THREE.Color("#e0ecff"),
            sunPos: new THREE.Vector2(0.50, 1.05),
            intensityBase: 0.12,
            intensityScale: 1.1,
        });
        this.object3D.add(this.godrays.object3D);
        // Event layer — cool electric tint, sharper shockwave.
        this.events = new EventLayer({
            shockColor: new THREE.Color("#c8e0ff"),
            strobeColor: new THREE.Color("#ffffff"),
            burstColor: new THREE.Color("#8ab8ff"),
            shockSpread: 1.4, // fastest in any biome — storm drops slam
        });
        this.object3D.add(this.events.object3D);
        this.texture = new TextureOverlay({
            tintColor: new THREE.Color("#b8d0ff"),
        });
        this.object3D.add(this.texture.object3D);
    }
    render(spec, ctx) {
        const u = this.bgMaterial.uniforms;
        u.uTime.value = ctx.t;
        u.uBeat.value = ctx.beatPulse;
        u.uDownbeat.value = ctx.downbeatPulse;
        u.uDrop.value = ctx.dropImpulse;
        u.uTension.value = ctx.section?.tension ?? 0.5;
        const sectionGainSat = ctx.section?.saturation ?? 1.0;
        const sectionGainBri = ctx.section?.brightness ?? 1.0;
        u.uSaturation.value = ctx.vmSaturation * (sectionGainSat / Math.max(0.5, ctx.vmSaturation));
        u.uBrightness.value = ctx.vmBrightness * (sectionGainBri / Math.max(0.5, ctx.vmBrightness));
        u.uCentroid.value = ctx.audio.centroid;
        u.uHarmonicRatio.value = ctx.audio.harmonicRatio;
        u.uZCR.value = ctx.audio.zcr;
        u.uChromaStrength.value = ctx.audio.chromaStrength;
        const modeStrength = ctx.section?.mode_strength ?? 0;
        u.uModeWarm.value = ctx.section?.mode === "minor" ? -modeStrength : modeStrength;
        u.uHueDistance.value = ctx.section?.hue_distance ?? 0.7;
        u.uPhrasePulse.value = ctx.phrasePulse;
        // Trigger a bolt on the rising edge of downbeatPulse / dropImpulse
        // (i.e., when these values just spiked above a threshold).
        const downbeatFiring = ctx.downbeatPulse > 0.85 && this.prevDownbeat <= 0.85;
        const dropFiring = ctx.dropImpulse > 0.5 && this.prevDrop <= 0.5;
        this.prevDownbeat = ctx.downbeatPulse;
        this.prevDrop = ctx.dropImpulse;
        let vertCount = 0;
        if (downbeatFiring || dropFiring) {
            const intensity = dropFiring ? 1.4 : 0.9;
            vertCount = this.writeBolt(ctx.t, intensity);
            // Push the same bolt geometry into the persistent afterglow ring
            // buffer — the visible bolt vanishes in ~150 ms but the afterglow
            // lingers ~1.4 s, leaving a fading trail in the storm wall.
            this.hero.pushBolt(this.boltBuffer, vertCount, ctx.t, intensity);
        }
        this.boltGeometry.setDrawRange(0, vertCount);
        this.boltGeometry.getAttribute("position").needsUpdate = true;
        this.boltMaterial.opacity =
            Math.max(ctx.downbeatPulse, ctx.dropImpulse * 1.3) * 0.95;
        // Particles drift slightly with subtle jitter on beats — Intense
        // wants edges to feel agitated, not floating-calm.
        // Rolloff clamps the vertical range: high-rolloff (sibilant/treble-
        // heavy) passages let shards reach the upper frame; low-rolloff
        // squeezes them into the lower 2/3, reinforcing the claustrophobic
        // pressure of the biome on dark mixes.
        const rolloff = ctx.audio.rolloff;
        const ceilY = 2.5 * rolloff;
        const floorY = -2.5 * (1.0 - rolloff * 0.4);
        const pos = this.particles.geometry.getAttribute("position");
        const jitter = ctx.beatPulse * 0.04;
        for (let i = 0; i < IntenseStormScene.PARTICLE_COUNT; i++) {
            this.positions[i * 3 + 0] += (Math.sin(ctx.t * 4 + i) * 0.001) + (hash2(ctx.t, i) - 0.5) * jitter * 0.05;
            let y = this.positions[i * 3 + 1] + (Math.cos(ctx.t * 3 + i) * 0.001) + (hash2(ctx.t, i + 1000) - 0.5) * jitter * 0.05;
            if (y > ceilY)
                y = ceilY;
            else if (y < floorY)
                y = floorY;
            this.positions[i * 3 + 1] = y;
        }
        pos.needsUpdate = true;
        // Per-onset shards — tinted toward red on tonal hits for the
        // signature complementary contrast against the pale-blue base.
        this.onsetEmitter.update(spec, ctx, new THREE.Color("#ff5050"));
        const bands = ctx.audio.melBands;
        for (let k = 0; k < 8; k++) {
            this.onsetEmitter.spawnBandPulse(k, bands[k] ?? 0, ctx.t, ctx);
        }
        // Hero updates: storm wall + lightning afterglow ring buffer.
        this.hero.update(spec, ctx);
        this.skyline.update(spec, ctx);
        this.godrays.update(spec, ctx);
        this.events.update(spec, ctx);
        this.texture.update(spec, ctx);
        // Cinematic camera — Intense gets the loudest moves: strong shake,
        // strong sway, exaggerated push-in on drops.
        const sp = ctx.sectionProgress;
        const cam = cinematicCameraDeltas(ctx, {
            sway: 1.4,
            push: 1.2,
            phrase: 1.0,
            shake: 1.6,
            roll: 1.3,
        });
        this.camera.position.set(0, 0, 4 - sp * 0.15).add(cam.posDelta);
        this.camera.lookAt(0, 0, 0);
        this.camera.rotation.z = cam.rollZ;
        this.camera.updateProjectionMatrix();
    }
    /// Write a jagged polyline lightning bolt into the line-segment
    /// buffer. Returns the number of vertices written (must be even).
    writeBolt(seedTime, intensity) {
        const SEGMENTS = 10;
        const BRANCHES = intensity > 1.0 ? 3 : 1;
        let v = 0;
        const rand = (s) => {
            const x = Math.sin(s * 12.9898 + seedTime * 78.233) * 43758.5453;
            return x - Math.floor(x);
        };
        for (let b = 0; b < BRANCHES; b++) {
            // Bolt origin: random point near top of frame, descending downward.
            const x0 = (rand(b * 17.3) - 0.5) * 5;
            let x = x0;
            let y = 2.5;
            const targetY = -2.0 - rand(b * 31.7) * 0.5;
            const stepY = (targetY - y) / SEGMENTS;
            for (let s = 0; s < SEGMENTS && v < IntenseStormScene.MAX_BOLT_VERTS - 2; s++) {
                const x2 = x + (rand(b * 7 + s * 13.1) - 0.5) * 0.7 * intensity;
                const y2 = y + stepY;
                this.boltBuffer[v * 3 + 0] = x;
                this.boltBuffer[v * 3 + 1] = y;
                this.boltBuffer[v * 3 + 2] = 0;
                v++;
                this.boltBuffer[v * 3 + 0] = x2;
                this.boltBuffer[v * 3 + 1] = y2;
                this.boltBuffer[v * 3 + 2] = 0;
                v++;
                x = x2;
                y = y2;
            }
        }
        return v;
    }
    dispose() {
        this.bgMaterial.dispose();
        this.particleMaterial.dispose();
        this.particles.geometry.dispose();
        this.boltMaterial.dispose();
        this.boltGeometry.dispose();
        this.onsetEmitter.dispose();
        this.hero.dispose();
        this.skyline.dispose();
        this.godrays.dispose();
        this.events.dispose();
        this.texture.dispose();
    }
}
//# sourceMappingURL=intense_storm.js.map
// Euphoric bloom — high-V, high-A biome.
//
// Hot radial bloom with a luminous magenta→gold core, a halo that
// pulses outward on every beat, and ~600 GPU particles drifting in an
// additive-blended cloud. The whole frame is built around a single
// bright source — celebratory rather than busy.
//
// Palette: ANALOGOUS warm (gold ~45° → magenta ~330°, traversing the
// short way through orange/red, ~75° interval). Schloss & Palmer (2011)
// rate analogous palettes as more harmonious; for a high-V biome the
// celebration should read as resolution, not tension.
//
// V&M (1994): high A → S≈0.95, B≈0.86. Brightness intentionally NOT
// max-bright (β=−0.31 on arousal counter-modulates).
//
// Bouba/Kiki: euphoric music typically has high harmonic_ratio →
// rounded particles, soft halo. Sharp shapes would feel anxious.
import * as THREE from "three";
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
  uniform vec3  uColorCore;
  uniform vec3  uColorMid;
  uniform vec3  uColorEdge;
  uniform float uSaturation;
  uniform float uBrightness;

  // Cheap value noise for halo modulation.
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

  vec3 desaturate(vec3 col, float amt) {
    float l = dot(col, vec3(0.299, 0.587, 0.114));
    return mix(vec3(l), col, amt);
  }

  void main() {
    vec2 uv = vUv;
    vec2 center = vec2(0.5, 0.5);
    vec2 d = uv - center;
    float r = length(d) * 1.6;
    float angle = atan(d.y, d.x);

    // Three-stop radial: gold core → magenta mid → wine edge.
    vec3 col;
    if (r < 0.40) {
      col = mix(uColorCore, uColorMid, smoothstep(0.0, 0.40, r));
    } else {
      col = mix(uColorMid, uColorEdge, smoothstep(0.40, 1.05, r));
    }

    // Slow rotating shimmer in the mid band — keeps the bloom alive
    // between beats without reading as motion.
    float shimmer = noise(vec2(angle * 3.0 + uTime * 0.20, r * 4.0)) * 0.10;
    col += vec3(shimmer) * smoothstep(0.6, 0.2, r);

    // Beat halo — luminance ring expanding outward on each beat.
    float ringR = 0.18 + uBeat * 0.55;
    float ringW = 0.10;
    float ring = smoothstep(ringR + ringW, ringR, r)
               - smoothstep(ringR, max(ringR - ringW, 0.0), r);
    col += vec3(ring * uBeat * 0.55);

    // Downbeat lens-flare-feeling brightness pop at the core.
    if (uDownbeat > 0.05) {
      float flare = exp(-r * 4.5) * uDownbeat * 0.65;
      col += vec3(flare * 1.0, flare * 0.95, flare * 0.80);
    }

    // Drop: full-frame prismatic flash.
    col += vec3(uDrop * 0.50, uDrop * 0.30, uDrop * 0.45);

    // Mild edge vignette so the bloom reads as the focal point.
    col *= smoothstep(1.45, 0.30, r);

    col = desaturate(col, uSaturation);
    col *= uBrightness;
    gl_FragColor = vec4(col, 1.0);
  }
`;
export class EuphoricBloomScene {
    object3D;
    camera;
    bgMaterial;
    particles;
    particleMaterial;
    positions;
    velocities;
    static PARTICLE_COUNT = 600;
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
                // Analogous warm anchors (~45°, ~330°, ~350°).
                uColorCore: { value: new THREE.Color("#ffe7a3") }, // hot gold
                uColorMid: { value: new THREE.Color("#ff5588") }, // magenta
                uColorEdge: { value: new THREE.Color("#3a0e1f") }, // deep wine
                uSaturation: { value: 1.0 },
                uBrightness: { value: 1.0 },
            },
            depthTest: false,
            depthWrite: false,
        });
        const bg = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), this.bgMaterial);
        bg.frustumCulled = false;
        bg.renderOrder = -10;
        this.object3D.add(bg);
        // Particle storm — radial spawn pattern with outward drift, recycled
        // when a particle drifts past the frame edge. Position seeding is
        // deterministic per-particle (hash by index) so renders are
        // reproducible across runs.
        const N = EuphoricBloomScene.PARTICLE_COUNT;
        this.positions = new Float32Array(N * 3);
        this.velocities = new Float32Array(N * 3);
        for (let i = 0; i < N; i++) {
            const t = i / N;
            const angle = t * Math.PI * 2 * 13.7; // golden-angle-ish for spread
            const radius = 0.2 + (Math.sin(i * 1.234) + 1) * 1.5;
            this.positions[i * 3 + 0] = Math.cos(angle) * radius;
            this.positions[i * 3 + 1] = Math.sin(angle) * radius;
            this.positions[i * 3 + 2] = -Math.random() * 2.0;
            // Outward velocity, modulated.
            this.velocities[i * 3 + 0] = Math.cos(angle) * 0.18;
            this.velocities[i * 3 + 1] = Math.sin(angle) * 0.18;
            this.velocities[i * 3 + 2] = (Math.random() - 0.5) * 0.05;
        }
        const geo = new THREE.BufferGeometry();
        geo.setAttribute("position", new THREE.BufferAttribute(this.positions, 3));
        this.particleMaterial = new THREE.PointsMaterial({
            color: new THREE.Color("#fff5d4"),
            size: 0.06,
            sizeAttenuation: true,
            transparent: true,
            opacity: 0.65,
            blending: THREE.AdditiveBlending,
            depthWrite: false,
        });
        this.particles = new THREE.Points(geo, this.particleMaterial);
        this.object3D.add(this.particles);
    }
    render(ctx) {
        const u = this.bgMaterial.uniforms;
        u.uTime.value = ctx.t;
        u.uBeat.value = ctx.beatPulse;
        u.uDownbeat.value = ctx.downbeatPulse;
        u.uDrop.value = ctx.dropImpulse;
        const sectionGainSat = ctx.section?.saturation ?? 1.0;
        const sectionGainBri = ctx.section?.brightness ?? 1.0;
        u.uSaturation.value = ctx.vmSaturation * (sectionGainSat / Math.max(0.5, ctx.vmSaturation));
        u.uBrightness.value = ctx.vmBrightness * (sectionGainBri / Math.max(0.5, ctx.vmBrightness));
        // Particles drift outward, recycle to center when they leave the frame.
        // Beat pulse adds a velocity nudge so the bloom feels alive on rhythm.
        const pos = this.particles.geometry.getAttribute("position");
        const dt = 1 / 60;
        const beatBoost = 1.0 + ctx.beatPulse * 1.5;
        for (let i = 0; i < EuphoricBloomScene.PARTICLE_COUNT; i++) {
            const ix = i * 3;
            this.positions[ix + 0] += this.velocities[ix + 0] * dt * beatBoost;
            this.positions[ix + 1] += this.velocities[ix + 1] * dt * beatBoost;
            this.positions[ix + 2] += this.velocities[ix + 2] * dt;
            const r = Math.hypot(this.positions[ix], this.positions[ix + 1]);
            if (r > 4.5) {
                // Recycle near center with a fresh direction.
                const a = Math.random() * Math.PI * 2;
                this.positions[ix + 0] = Math.cos(a) * 0.3;
                this.positions[ix + 1] = Math.sin(a) * 0.3;
                this.positions[ix + 2] = -Math.random() * 2.0;
                this.velocities[ix + 0] = Math.cos(a) * 0.18;
                this.velocities[ix + 1] = Math.sin(a) * 0.18;
            }
        }
        pos.needsUpdate = true;
        // Particle intensity tracks beat and drop.
        this.particleMaterial.opacity = 0.55 + ctx.beatPulse * 0.30 + ctx.dropImpulse * 0.20;
        this.particleMaterial.size = 0.06 + ctx.dropImpulse * 0.05;
    }
    dispose() {
        this.bgMaterial.dispose();
        this.particleMaterial.dispose();
        this.particles.geometry.dispose();
    }
}
//# sourceMappingURL=euphoric_bloom.js.map
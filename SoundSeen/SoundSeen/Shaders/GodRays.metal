// GodRays.metal
// Klsr-inspired cinematic god-rays shader for SoundSeen
//
// CRITICAL: Argument order must match exactly between Swift and Metal.
// Swift arguments array fills parameters AFTER (float2 pos, SwiftUI::Layer layer).
//
// Order: lightCenter, time, bassEnergy, beatPulse, snareBloom, valence, arousal,
//        hueDrift, sectionBuild, intensityScale, paletteMix, paletteWarm, paletteCool

#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// Simple hash for dust mote noise
float hash21(float2 p) {
    p = fract(p * float2(234.34, 435.345));
    p += dot(p, p + 34.23);
    return fract(p.x * p.y);
}

// 2D noise for dust distribution
float noise2D(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f); // smoothstep

    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));

    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

[[ stitchable ]] half4 godRays(
    float2 pos,
    SwiftUI::Layer layer,
    float2 lightCenter,     // normalized coords, default (0.5, 0.38)
    float  time,            // CACurrentMediaTime, wrapped
    float  bassEnergy,      // EMA-smoothed bass (0-1)
    float  beatPulse,       // current beat pulse (0-1)
    float  snareBloom,      // snare/transient envelope (0-1)
    float  valence,         // emotional valence (0-1)
    float  arousal,         // emotional arousal (0-1)
    float  hueDrift,        // current hue for subtle color shift
    float  sectionBuild,    // section build envelope (0-1)
    float  intensityScale,  // HUD slider * reduce-motion clamp
    float  paletteMix,      // warm-vs-cool scalar (0=cool, 1=warm)
    half4  paletteWarm,     // warm palette color
    half4  paletteCool      // cool palette color
) {
    // Sample the underlying layer
    half4 base = layer.sample(pos);

    // Get layer bounds for normalization
    float2 bounds = float2(layer.info().size);
    float2 uv = pos / bounds;

    // Light center in pixel space
    float2 lightPos = lightCenter * bounds;

    // Direction and distance from pixel to light
    float2 toLight = lightPos - pos;
    float dist = length(toLight);
    float2 dir = toLight / max(dist, 1.0);

    // === RAY MARCHING ===
    // 16 fixed steps toward light center
    // This creates the volumetric god-ray effect

    float rayAccum = 0.0;
    float stepSize = dist / 16.0;

    // Beam power exponent: high valence = tight/triumphant, low = diffuse/melancholic
    // Range: 1.5 (diffuse) to 4.0 (tight)
    float beamPower = mix(1.5, 4.0, valence);

    for (int i = 0; i < 16; i++) {
        float t = float(i) / 15.0;
        float2 samplePos = pos + dir * (t * dist);
        float2 sampleUV = samplePos / bounds;

        // Distance from this sample to light center (normalized)
        float sampleDist = length(sampleUV - lightCenter);

        // Radial falloff with valence-controlled beam tightness
        float radial = exp(-sampleDist * beamPower * 3.0);

        // Angular variation for ray structure
        float2 fromCenter = sampleUV - lightCenter;
        float angle = atan2(fromCenter.y, fromCenter.x);
        float rayPattern = 0.5 + 0.5 * sin(angle * 12.0 + time * 0.3);
        rayPattern = pow(rayPattern, 2.0); // sharpen rays

        rayAccum += radial * rayPattern * (1.0 - t * 0.5);
    }
    rayAccum /= 16.0;

    // === BRIGHTNESS FORMULA ===
    // Principle 1: Restraint - beatPulse is GATED by bass (hi-hats don't pop)
    // Principle 2: sectionBuild for slow cinematic ramps
    // Principle 4: 0.15 floor so scene breathes in silence

    float brightness = 0.15                           // baseline presence
                     + 0.55 * bassEnergy              // bass drives brightness
                     + 0.20 * beatPulse * bassEnergy  // beats only matter with bass
                     + 0.60 * snareBloom              // snare transient bloom
                     + 0.30 * sectionBuild;           // slow section build

    brightness = clamp(brightness, 0.0, 1.5);

    // === COLOR ===
    // Principle 3: Color carries feeling, not energy
    // Valence/arousal shift palette, brightness stays separate

    half4 rayColor = mix(paletteCool, paletteWarm, half(paletteMix));

    // Subtle hue drift based on current audio hue
    float hueShift = hueDrift * 0.1;
    // Apply hue rotation (simplified - shift in RGB space)
    float3 rgb = float3(rayColor.rgb);
    float cosH = cos(hueShift * 6.28318);
    float sinH = sin(hueShift * 6.28318);
    float3 rotated;
    rotated.r = rgb.r * (0.299 + 0.701 * cosH + 0.168 * sinH)
              + rgb.g * (0.587 - 0.587 * cosH + 0.330 * sinH)
              + rgb.b * (0.114 - 0.114 * cosH - 0.497 * sinH);
    rotated.g = rgb.r * (0.299 - 0.299 * cosH - 0.328 * sinH)
              + rgb.g * (0.587 + 0.413 * cosH + 0.035 * sinH)
              + rgb.b * (0.114 - 0.114 * cosH + 0.292 * sinH);
    rotated.b = rgb.r * (0.299 - 0.300 * cosH + 1.250 * sinH)
              + rgb.g * (0.587 - 0.588 * cosH - 1.050 * sinH)
              + rgb.b * (0.114 + 0.886 * cosH - 0.203 * sinH);
    rayColor.rgb = half3(rotated);

    // === DUST MOTES ===
    // Principle 4: Scene breathes - dust drifts even in silence
    // Principle 5: Intentional movement - dust density tied to arousal

    float dustDensity = 0.3 + 0.7 * arousal; // floor ensures dust even when calm
    float dustScale = 80.0;

    // Parallax drift based on time
    float2 dustUV = uv * dustScale + float2(time * 0.02, time * 0.015);
    float dust1 = noise2D(dustUV);
    float dust2 = noise2D(dustUV * 1.7 + float2(100.0, 50.0) + float2(time * 0.01, -time * 0.008));

    // Combine layers with threshold for particle-like appearance
    float dustMask = smoothstep(0.6, 0.8, dust1 * dust2 * 2.0);
    dustMask *= dustDensity;

    // Dust brightness follows bass loosely but has its own floor
    float dustBright = 0.1 + 0.3 * bassEnergy + 0.2 * snareBloom;

    // === COMPOSITE ===
    // Additive blend preserves underlying layers

    float rayIntensity = rayAccum * brightness * intensityScale;
    float dustIntensity = dustMask * dustBright * intensityScale * 0.5;

    half4 godRayContrib = rayColor * half(rayIntensity);
    half4 dustContrib = half4(1.0, 1.0, 1.0, 1.0) * half(dustIntensity) * 0.3;

    // Additive composite
    half4 result = base + godRayContrib + dustContrib;
    result.a = base.a; // preserve alpha

    return result;
}

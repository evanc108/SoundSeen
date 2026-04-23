//
//  Textures.metal
//  SoundSeen
//
//  Metal shader functions for SwiftUI's .colorEffect, .distortionEffect,
//  and .layerEffect modifiers (iOS 17+). Two public entry points:
//
//    filmGrain  — adds luminance noise to every pixel. Used by
//                 FilmGrainTexture for atonality / flux unrest. Round 2
//                 adds a valence-driven color tint: low-valence passages
//                 receive a cool-blue bias, neutral+ stays colorless.
//    thermalShimmer — UV distortion displacing content by low-frequency
//                 noise. Used by ThermalShimmerTexture during drops and
//                 bridges for "heat pressure."
//

#include <metal_stdlib>
using namespace metal;

static float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = hash12(i);
    float b = hash12(i + float2(1.0, 0.0));
    float c = hash12(i + float2(0.0, 1.0));
    float d = hash12(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

/// Film grain — adds a luminance-only jitter per pixel, then applies an
/// optional cool-blue tint at tintStrength. The tint only kicks in during
/// low-valence passages (anxiety, sadness) — at neutral+ valence the call
/// site passes tintStrength = 0 and grain is colorless.
[[ stitchable ]]
half4 filmGrain(
    float2 position,
    half4 color,
    float time,
    float strength,
    float tintStrength
) {
    float2 seed = position + float2(time * 113.0, time * 97.0);
    float n = hash12(seed) - 0.5;
    float jitter = n * strength;
    half3 rgb = saturate(color.rgb + half3(jitter, jitter, jitter));

    // Cool-blue bias for low-valence unease. Values chosen to match HSB
    // (0.58, 0.2, 0.8) that the Swift side requests: slight blue lift,
    // slight red reduction.
    if (tintStrength > 0.001) {
        half3 coolTint = half3(0.55, 0.70, 1.0);
        rgb = mix(rgb, rgb * coolTint, half(tintStrength));
    }

    return half4(rgb, color.a);
}

[[ stitchable ]]
float2 thermalShimmer(
    float2 position,
    float time,
    float strength
) {
    float2 uv = position * 0.005;
    float n1 = valueNoise(uv + float2(0.0, time * 0.7));
    float n2 = valueNoise(uv * 2.3 + float2(time * 0.4, 0.0));
    float dx = (n1 - 0.5) * strength;
    float dy = (n2 - 0.5) * strength * 0.7 - strength * 0.15;
    return float2(position.x + dx, position.y + dy);
}

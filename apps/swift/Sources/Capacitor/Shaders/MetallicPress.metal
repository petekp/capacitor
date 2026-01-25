#include <metal_stdlib>
using namespace metal;

// MARK: - Metallic Specular Highlight (colorEffect)
//
// Creates an animated metallic specular highlight at the press point.
// Rings propagate outward from the click position over time.
// Three visual layers computed per-pixel:
//   1. Animated concentric rings expanding from press point
//   2. 8-fold anisotropic brightness (angle-dependent like brushed aluminium)
//   3. Tight Fresnel hotspot with warm→cool chromatic shift
//
// NOTE: This file must NOT include <SwiftUI/SwiftUI_Metal.h> — that header
// conflicts with colorEffect shaders.

[[ stitchable ]] half4 metallicPress(
    float2 position,
    half4 color,
    float2 pressPoint,
    float2 size,
    float intensity,
    float ringFrequency,
    float ringSharpness,
    float falloffRate,
    float specularTightness,
    float specularWeight,
    float ringWeight,
    float time,
    float rippleSpeed
) {
    float2 d = position - pressPoint;
    float dist = length(d);
    float maxDist = length(size) * 0.5;
    float n = dist / max(maxDist, 1.0);

    // Animated wavefront — rings expand outward from press point over time.
    // Subtracting (time * rippleSpeed) from the spatial phase makes rings propagate outward.
    float phase = n * ringFrequency - time * rippleSpeed;
    float rings = sin(phase) * 0.5 + 0.5;
    rings = pow(rings, ringSharpness);

    // Expanding envelope — the visible region grows outward from the press point.
    // Pixels beyond the wavefront are masked out for a clean propagation edge.
    float wavefront = time * rippleSpeed / max(ringFrequency, 1.0);
    float envelope = saturate(1.0 - (n - wavefront) * 8.0);

    // Smooth radial falloff
    float falloff = exp(-n * falloffRate);

    // Tight specular core
    float specular = exp(-n * specularTightness);

    // 8-fold anisotropic brightness — angle-dependent like real brushed metal
    float angle = atan2(d.y, d.x);
    float aniso = pow(abs(sin(angle * 4.0)), 3.0) * 0.4 + 0.6;

    // Chromatic shift: warm center → cool edge (like chrome reflection)
    half3 warm = half3(1.0h, 0.95h, 0.87h);
    half3 cool = half3(0.80h, 0.88h, 1.0h);
    half t = half(saturate(specular + falloff * 0.4));
    half3 col = mix(cool, warm, t);

    // Composite (premultiplied alpha) — rings masked by expanding envelope
    float a = (specular * specularWeight + rings * falloff * aniso * ringWeight * envelope) * intensity;

    return half4(col * half(a), half(a));
}

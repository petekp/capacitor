#include <metal_stdlib>
using namespace metal;

// Refractive glass effect for text/logos
// Creates animated caustics, fresnel reflections, and chromatic aberration

[[ stitchable ]]
half4 refractiveGlass(
    float2 position,
    half4 color,
    float2 size,
    float time,
    float fresnelPower,
    float fresnelIntensity,
    float chromaticAmount,
    float causticScale,
    float causticSpeed,
    float causticIntensity,
    float causticAngle,
    float glassClarity,
    float highlightSharpness,
    float highlightAngle,
    float internalReflection,
    float internalAngle
) {
    if (color.a < 0.001) {
        return color;
    }

    float2 uv = position / size;
    float2 center = float2(0.5, 0.5);
    float2 fromCenter = uv - center;
    float distFromCenter = length(fromCenter);

    // Fresnel effect - brighter at edges (simulates light bending at surface)
    float fresnel = pow(distFromCenter * 2.0, fresnelPower) * fresnelIntensity;
    fresnel = clamp(fresnel, 0.0, 1.0);

    // Animated caustic pattern with angle control
    float t = time * causticSpeed;
    float causticRad = causticAngle * 3.14159 / 180.0;
    float cosCaustic = cos(causticRad);
    float sinCaustic = sin(causticRad);

    // Rotate UV for caustic direction
    float2 rotatedUV = float2(
        uv.x * cosCaustic - uv.y * sinCaustic,
        uv.x * sinCaustic + uv.y * cosCaustic
    );
    float2 causticUV = rotatedUV * causticScale;

    // Multiple overlapping sine waves for organic caustic pattern
    float caustic1 = sin(causticUV.x * 8.0 + t * 2.0) * sin(causticUV.y * 6.0 + t * 1.4);
    float caustic2 = sin(causticUV.x * 5.0 - t * 1.6 + 1.5) * sin(causticUV.y * 9.0 + t);
    float caustic3 = sin((causticUV.x + causticUV.y) * 4.0 + t * 1.2);

    float caustics = (caustic1 + caustic2 + caustic3) / 3.0;
    caustics = caustics * 0.5 + 0.5;
    caustics = pow(caustics, 2.0) * causticIntensity;

    // Chromatic aberration - RGB channels offset differently
    float2 aberrationDir = normalize(fromCenter + 0.001);
    float aberrationDist = distFromCenter * chromaticAmount * 0.1;

    float2 uvR = uv + aberrationDir * aberrationDist;
    float2 uvB = uv - aberrationDir * aberrationDist;

    float brightnessR = 1.0 - length(uvR - center) * 0.3;
    float brightnessG = 1.0 - length(uv - center) * 0.3;
    float brightnessB = 1.0 - length(uvB - center) * 0.3;

    // Specular highlight with angle control
    // Position closer to center so it's visible when masked to text
    float highlightRad = highlightAngle * 3.14159 / 180.0;
    float highlightDist = 0.12;
    float2 lightPos = center + float2(cos(highlightRad), sin(highlightRad)) * highlightDist;
    float specDist = length(uv - lightPos);
    float specular = 1.0 - smoothstep(0.0, 0.25 / highlightSharpness, specDist);
    specular = pow(specular, max(highlightSharpness * 0.5, 1.0)) * 0.9;

    // Internal reflection with angle control
    float internalRad = internalAngle * 3.14159 / 180.0;
    float internalDist = 0.3;
    float2 reflectPos = center + float2(cos(internalRad), sin(internalRad)) * internalDist;
    float reflectDist = length(uv - reflectPos);
    float internalRefl = 1.0 - smoothstep(0.0, 0.2, reflectDist);
    internalRefl = pow(internalRefl, 2.0) * internalReflection * 0.4;

    // Combine all effects
    float3 glassColor;
    glassColor.r = brightnessR * glassClarity + fresnel * 0.3 + caustics * 0.8 + specular + internalRefl;
    glassColor.g = brightnessG * glassClarity + fresnel * 0.35 + caustics * 0.7 + specular + internalRefl;
    glassColor.b = brightnessB * glassClarity + fresnel * 0.4 + caustics * 0.6 + specular * 0.9 + internalRefl;

    // Add subtle edge glow
    float edgeGlow = smoothstep(0.3, 0.5, distFromCenter) * 0.15;
    glassColor += float3(edgeGlow * 0.8, edgeGlow * 0.9, edgeGlow);

    return half4(half3(glassColor) * color.a, color.a);
}

// Prismatic glass - adds rainbow dispersion to the refractive glass effect
[[ stitchable ]]
half4 prismaticGlass(
    float2 position,
    half4 color,
    float2 size,
    float time,
    float fresnelPower,
    float fresnelIntensity,
    float chromaticAmount,
    float causticScale,
    float causticSpeed,
    float causticIntensity,
    float causticAngle,
    float glassClarity,
    float highlightSharpness,
    float highlightAngle,
    float internalReflection,
    float internalAngle,
    float prismAmount
) {
    if (color.a < 0.001) {
        return color;
    }

    float2 uv = position / size;
    float2 center = float2(0.5, 0.5);
    float2 fromCenter = uv - center;
    float distFromCenter = length(fromCenter);

    // Fresnel effect
    float fresnel = pow(distFromCenter * 2.0, fresnelPower) * fresnelIntensity;
    fresnel = clamp(fresnel, 0.0, 1.0);

    // Animated caustics with angle control
    float t = time * causticSpeed;
    float causticRad = causticAngle * 3.14159 / 180.0;
    float cosCaustic = cos(causticRad);
    float sinCaustic = sin(causticRad);

    float2 rotatedUV = float2(
        uv.x * cosCaustic - uv.y * sinCaustic,
        uv.x * sinCaustic + uv.y * cosCaustic
    );
    float2 causticUV = rotatedUV * causticScale;

    float caustic1 = sin(causticUV.x * 8.0 + t * 2.0) * sin(causticUV.y * 6.0 + t * 1.4);
    float caustic2 = sin(causticUV.x * 5.0 - t * 1.6 + 1.5) * sin(causticUV.y * 9.0 + t);
    float caustic3 = sin((causticUV.x + causticUV.y) * 4.0 + t * 1.2);
    float caustics = (caustic1 + caustic2 + caustic3) / 3.0;
    caustics = caustics * 0.5 + 0.5;
    caustics = pow(caustics, 2.0) * causticIntensity;

    // Enhanced chromatic aberration for prismatic effect
    float2 aberrationDir = normalize(fromCenter + 0.001);
    float aberrationDist = distFromCenter * chromaticAmount * 0.15;

    float2 uvR = uv + aberrationDir * aberrationDist * 1.2;
    float2 uvG = uv;
    float2 uvB = uv - aberrationDir * aberrationDist * 1.2;

    // Prismatic rainbow based on angle from center
    float angle = atan2(fromCenter.y, fromCenter.x);
    float hue = (angle / 6.28318 + 0.5 + time * 0.1);

    // Rainbow color
    float3 prismColor;
    prismColor.r = 0.5 + 0.5 * sin(hue * 6.28318);
    prismColor.g = 0.5 + 0.5 * sin(hue * 6.28318 + 2.094);
    prismColor.b = 0.5 + 0.5 * sin(hue * 6.28318 + 4.188);

    // Base glass brightness
    float brightnessR = 1.0 - length(uvR - center) * 0.3;
    float brightnessG = 1.0 - length(uvG - center) * 0.3;
    float brightnessB = 1.0 - length(uvB - center) * 0.3;

    // Specular highlight with angle control
    // Position closer to center so it's visible when masked to text
    float highlightRad = highlightAngle * 3.14159 / 180.0;
    float highlightDist = 0.12;
    float2 lightPos = center + float2(cos(highlightRad), sin(highlightRad)) * highlightDist;
    float specDist = length(uv - lightPos);
    float specular = 1.0 - smoothstep(0.0, 0.25 / highlightSharpness, specDist);
    specular = pow(specular, max(highlightSharpness * 0.5, 1.0)) * 0.9;

    // Internal reflection with angle control
    float internalRad = internalAngle * 3.14159 / 180.0;
    float internalDist = 0.3;
    float2 reflectPos = center + float2(cos(internalRad), sin(internalRad)) * internalDist;
    float reflectDist = length(uv - reflectPos);
    float internalRefl = 1.0 - smoothstep(0.0, 0.2, reflectDist);
    internalRefl = pow(internalRefl, 2.0) * internalReflection * 0.4;

    // Combine glass and prismatic effects
    float3 glassColor;
    glassColor.r = brightnessR * glassClarity + fresnel * 0.3 + caustics * 0.8 + specular + internalRefl;
    glassColor.g = brightnessG * glassClarity + fresnel * 0.35 + caustics * 0.7 + specular + internalRefl;
    glassColor.b = brightnessB * glassClarity + fresnel * 0.4 + caustics * 0.6 + specular * 0.9 + internalRefl;

    // Mix in prismatic rainbow
    glassColor = mix(glassColor, prismColor * (glassClarity + caustics + specular * 0.5), prismAmount * fresnel);

    // Edge rainbow dispersion
    float edgeRainbow = smoothstep(0.2, 0.5, distFromCenter) * prismAmount;
    glassColor = mix(glassColor, prismColor, edgeRainbow * 0.3);

    return half4(half3(glassColor) * color.a, color.a);
}

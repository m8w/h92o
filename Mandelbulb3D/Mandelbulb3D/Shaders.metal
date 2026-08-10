//
//  Shaders.metal
//  Mandelbulb3D
//
//  Real-time Mandelbulb ray marcher. The distance-estimator is the
//  classic power-8 Mandelbulb formula popularized by Daniel White /
//  Paul Nylander (2009) and used throughout the fractal-rendering
//  community (Mandelbulb 3D, Shadertoy, Fragmentarium, etc.):
//
//    z <- z^n + c   in "triplex" (spherical) form, iterated per-sample,
//    with the running derivative dr used to turn the escape-time
//    iteration into a signed distance bound (Hart et al. distance
//    estimation for Julia/Mandelbrot-type sets).
//
//  Everything below runs entirely on the GPU: the vertex stage just
//  emits a full-screen triangle, and the fragment stage ray-marches
//  the fractal per-pixel.
//

#include <metal_stdlib>
using namespace metal;

#include "ShaderTypes.h"

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Full-screen triangle: 3 vertices, no vertex buffer needed.
vertex VertexOut vertexShader(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    VertexOut out;
    float2 p = positions[vertexID];
    out.position = float4(p, 0.0, 1.0);
    out.uv = p * 0.5 + 0.5;
    return out;
}

// ---- Mandelbulb distance estimator -----------------------------------

inline float mandelbulbDE(float3 pos, float power, int maxIterations, thread float &trap) {
    float3 z = pos;
    float dr = 1.0;
    float r = 0.0;
    trap = 1e10;

    for (int i = 0; i < maxIterations; i++) {
        r = length(z);
        if (r > 2.0) {
            break;
        }

        // Cartesian -> polar
        float theta = acos(clamp(z.z / r, -1.0, 1.0));
        float phi = atan2(z.y, z.x);
        dr = pow(r, power - 1.0) * power * dr + 1.0;

        // Scale and rotate the point
        float zr = pow(r, power);
        theta *= power;
        phi *= power;

        // polar -> Cartesian
        z = zr * float3(sin(theta) * cos(phi),
                         sin(phi) * sin(theta),
                         cos(theta));
        z += pos;

        trap = min(trap, r);
    }

    return 0.5 * log(max(r, 1e-6)) * r / dr;
}

inline float sceneDE(float3 pos, constant Uniforms &u, thread float &trap) {
    return mandelbulbDE(pos, u.power, u.maxIterations, trap);
}

inline float3 estimateNormal(float3 pos, constant Uniforms &u) {
    const float h = u.epsilon * 2.0;
    const float2 k = float2(1.0, -1.0);
    float t;
    float3 n =
        k.xyy * sceneDE(pos + k.xyy * h, u, t) +
        k.yyx * sceneDE(pos + k.yyx * h, u, t) +
        k.yxy * sceneDE(pos + k.yxy * h, u, t) +
        k.xxx * sceneDE(pos + k.xxx * h, u, t);
    return normalize(n);
}

inline float ambientOcclusion(float3 pos, float3 normal, constant Uniforms &u) {
    float occlusion = 0.0;
    float scale = 1.0;
    for (int i = 1; i <= 5; i++) {
        float dist = 0.02 * float(i) * float(i);
        float t;
        float sample = sceneDE(pos + normal * dist, u, t);
        occlusion += (dist - sample) * scale;
        scale *= 0.7;
    }
    return clamp(1.0 - u.aoStrength * occlusion, 0.0, 1.0);
}

inline float softShadow(float3 origin, float3 lightDir, constant Uniforms &u) {
    float res = 1.0;
    float t = 0.02;
    for (int i = 0; i < 48 && t < 6.0; i++) {
        float trap;
        float d = sceneDE(origin + lightDir * t, u, trap);
        if (d < u.epsilon) {
            return 0.0;
        }
        res = min(res, 12.0 * d / t);
        t += clamp(d, 0.01, 0.3);
    }
    return clamp(res, 0.0, 1.0);
}

// ---- Fragment: ray march + shade --------------------------------------

fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                constant Uniforms &u [[buffer(0)]]) {
    float2 ndc = in.uv * 2.0 - 1.0;
    float aspect = u.viewportSize.x / max(u.viewportSize.y, 1.0);
    ndc.x *= aspect;

    float3 rayDir = normalize(u.cameraForward.xyz
                               + ndc.x * u.tanHalfFov * u.cameraRight.xyz
                               + ndc.y * u.tanHalfFov * u.cameraUp.xyz);
    float3 rayOrigin = u.cameraPosition.xyz;

    float t = 0.0;
    float trap = 0.0;
    bool hit = false;
    int stepsTaken = 0;

    for (int i = 0; i < u.maxSteps; i++) {
        float3 pos = rayOrigin + rayDir * t;
        float d = sceneDE(pos, u, trap);
        stepsTaken = i;

        if (d < u.epsilon) {
            hit = true;
            break;
        }

        t += d;

        if (t > u.maxDistance) {
            break;
        }
    }

    // Background: soft vertical gradient, subtle glow toward the fractal.
    float3 bgTop = float3(0.02, 0.02, 0.05);
    float3 bgBottom = float3(0.08, 0.06, 0.12);
    float3 background = mix(bgBottom, bgTop, saturate(in.uv.y));
    float glow = float(stepsTaken) / float(u.maxSteps);
    background += float3(0.15, 0.08, 0.22) * glow * glow * 0.5;

    if (!hit) {
        return float4(background, 1.0);
    }

    float3 pos = rayOrigin + rayDir * t;
    float3 normal = estimateNormal(pos, u);
    float3 lightDir = normalize(-u.lightDirection.xyz);
    float3 viewDir = normalize(rayOrigin - pos);
    float3 halfVec = normalize(lightDir + viewDir);

    float diffuse = max(dot(normal, lightDir), 0.0);
    float specular = pow(max(dot(normal, halfVec), 0.0), 32.0);
    float ao = ambientOcclusion(pos, normal, u);
    float shadow = u.enableShadows != 0 ? softShadow(pos + normal * u.epsilon * 2.0, lightDir, u) : 1.0;

    // Orbit-trap coloring: how close the iteration got to the origin
    // gives an organic, banded color pattern characteristic of
    // Mandelbulb renders.
    float trapT = saturate(1.0 - trap);
    float3 albedo = mix(u.baseColorA.xyz, u.baseColorB.xyz, trapT);

    float3 ambient = albedo * 0.18 * ao;
    float3 direct = albedo * diffuse * shadow * ao;
    float3 specColor = float3(1.0) * specular * shadow * 0.6;

    float3 color = ambient + direct + specColor;

    // Cheap fog toward the background color for depth cueing.
    float fog = saturate(t / u.maxDistance);
    color = mix(color, background, fog * fog * 0.35);

    // Simple filmic-ish tonemap + gamma.
    color = color / (color + 1.0);
    color = pow(color, float3(1.0 / 2.2));

    return float4(color, 1.0);
}

//
//  ShaderTypes.h
//  Mandelbulb3D
//
//  Types shared between the Objective-C++ host code and the Metal
//  fragment shader. Kept as a plain C header with simd types so it can
//  be #included from both Renderer.mm and Shaders.metal.
//
//  All directional/positional quantities use float4 (not float3): a
//  bare float3 has sizeof==16 on the CPU side (simd_float3 pads to 16
//  bytes) but Metal Shading Language only guarantees 16-byte
//  *alignment* for float3, not 16-byte *size* — a following scalar can
//  legally pack right after byte 12. That mismatch silently corrupts
//  a shared struct's layout. float4 is 16 bytes with 16-byte alignment
//  identically on both sides, so it's the safe choice here; the unused
//  w component is ignored.
//

#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

struct Uniforms {
    simd_float4 cameraPosition;
    simd_float4 cameraForward;
    simd_float4 cameraRight;
    simd_float4 cameraUp;

    simd_float2 viewportSize;
    float tanHalfFov;
    float time;

    float power;            // Mandelbulb exponent (classic value: 8.0)
    int   maxIterations;    // fractal escape-time iterations
    int   maxSteps;         // ray-march steps
    float epsilon;          // surface hit threshold

    float maxDistance;      // ray-march far plane
    float aoStrength;       // ambient-occlusion intensity
    int   enableShadows;    // 0/1
    float _pad0;

    simd_float4 lightDirection;
    simd_float4 baseColorA; // orbit-trap color gradient, low end
    simd_float4 baseColorB; // orbit-trap color gradient, high end
};

#endif /* ShaderTypes_h */

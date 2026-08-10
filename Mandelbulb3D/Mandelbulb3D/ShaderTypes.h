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
//  identically on both sides, so it's the safe choice here; unused w
//  components are ignored (or repurposed, see FractalType).
//

#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

// Which distance-estimator the fragment shader evaluates. Keep in sync
// with the switch in Shaders.metal's sceneDE() and with the presets in
// Renderer.mm's -applyPresetForFractalType:.
enum FractalType {
    FractalTypeMandelbulb        = 0, // classic White/Nylander power-n formula
    FractalTypeMandelbox         = 1, // Rrrola/Tglad "Amazing Box"
    FractalTypeMengerSponge      = 2, // Inigo Quilez's folded-box menger sponge SDF
    FractalTypeSierpinskiTetra   = 3, // tetrahedral IFS folding
    FractalTypeQuaternionJulia   = 4, // Crane's quaternion Julia set, sliced at w=0
    FractalTypeApollonian        = 5, // Knighty's sphere-inversion gasket
    FractalTypeCount             = 6,
};

struct Uniforms {
    simd_float4 cameraPosition;
    simd_float4 cameraForward;
    simd_float4 cameraRight;
    simd_float4 cameraUp;

    simd_float2 viewportSize;
    float tanHalfFov;
    float time;

    int   maxSteps;         // ray-march steps
    float epsilon;          // surface hit threshold
    float maxDistance;      // ray-march far plane
    float aoStrength;       // ambient-occlusion intensity

    int enableShadows;      // 0/1
    int fractalType;        // FractalType
    int juliaMode;          // Mandelbulb only: iterate from a fixed juliaC instead of from pos
    int maxIterations;      // shared iteration budget across all fractal types

    float power;            // Mandelbulb / Juliabulb exponent (classic value: 8.0)
    float mbScale;          // Mandelbox scale factor (classic value: -1.5 to -3.0)
    float mbMinRadius2;      // Mandelbox ball-fold inner radius^2
    float mbFixedRadius2;    // Mandelbox ball-fold outer radius^2

    float ifsScale;          // Menger/Sierpinski scale, or Apollonian fixed-radius^2
    float bailout;            // escape radius^2 (Mandelbulb/Juliabulb/Quaternion Julia)
    float _pad0;
    float _pad1;

    simd_float4 ifsOffset;    // Menger/Sierpinski fold offset (xyz used)
    simd_float4 juliaC;       // Juliabulb constant (xyz) or Quaternion Julia constant (xyzw)

    simd_float4 lightDirection;
    simd_float4 baseColorA;   // orbit-trap color gradient, low end
    simd_float4 baseColorB;   // orbit-trap color gradient, high end
};

#endif /* ShaderTypes_h */

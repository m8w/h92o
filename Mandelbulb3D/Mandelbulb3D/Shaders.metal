//
//  Shaders.metal
//  Mandelbulb3D
//
//  A small library of classic distance-estimated 3D fractals, all
//  ray-marched per-pixel on the GPU. Formula sources (all standard,
//  widely republished derivations — see this project's README for the
//  full writeup of each):
//
//   - Mandelbulb / Juliabulb: Daniel White & Paul Nylander's 2009
//     spherical ("triplex") power-n formula.
//   - Mandelbox: Tom Lowe's "Amazing Box", DE popularized by
//     Rrrola/Tglad on Fractal Forums.
//   - Menger Sponge: Inigo Quilez's folded-box SDF
//     (iquilezles.org/articles/menger).
//   - Sierpinski Tetrahedron: the standard tetrahedral-fold IFS DE,
//     as catalogued in Syntopia's "Distance Estimated 3D Fractals"
//     series and the Fractal Forums wiki.
//   - Quaternion Julia: Keenan Crane's "Ray Tracing Quaternion Julia
//     Sets on the GPU" (GPU Gems), sliced at w=0.
//   - Apollonian gasket: Knighty's sphere-inversion DE, as documented
//     on Fractal Forums / iquilezles.org.
//   - Kaleidoscopic IFS (KIFS): the tetrahedral-fold-plus-rotation
//     engine behind most of Mandelbulber2's abox_*/difs_* formula
//     family — same fold as the Sierpinski DE below, generalized with
//     a configurable per-iteration rotation, so scale/offset/rotation
//     alone reach a huge range of that family's look without a
//     separate formula per variant.
//   - Hybrid: Mandelbulber2's actual "hybrid fractal" mechanism —
//     rather than one formula's full escape-time loop, up to three
//     formulas each contribute one iteration step to a single shared
//     point, combined via a chosen operator (chain/add/subtract/cross
//     product) and blend weight.
//
//  The vertex stage just emits a full-screen triangle; the fragment
//  stage ray-marches whichever fractal is selected, per-pixel.
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

// GLSL-style mod: always returns a result with the sign of y (Metal's
// built-in fmod follows C semantics and can return negative values,
// which would silently break the folding formulas below).
inline float3 glslMod(float3 x, float3 y) {
    return x - y * floor(x / y);
}

// Rodrigues' rotation formula: rotate v around a (unit) axis by angle.
inline float3 rotateAroundAxis(float3 v, float3 axis, float angle) {
    float3 a = normalize(axis);
    float c = cos(angle);
    float s = sin(angle);
    return v * c + cross(a, v) * s + a * dot(a, v) * (1.0 - c);
}

// ---- Mandelbulb / Juliabulb -------------------------------------------
//
//   z_0 = pos,  c = juliaMode ? juliaC : pos
//   z_{n+1} = ||z_n||^power * (spherical rotation by `power`) + c
//
// dr tracks the running derivative so the escape-time iteration can be
// turned into a lower-bound signed distance (Hart et al.).

inline float mandelbulbDE(float3 pos, constant Uniforms &u, thread float &trap) {
    float3 z = pos;
    float3 c = (u.juliaMode != 0) ? u.juliaC.xyz : pos;
    float power = u.power;
    float dr = 1.0;
    float r = 0.0;
    trap = 1e10;

    for (int i = 0; i < u.maxIterations; i++) {
        r = length(z);
        if (r * r > u.bailout) {
            break;
        }

        float theta = acos(clamp(z.z / r, -1.0, 1.0));
        float phi = atan2(z.y, z.x);
        dr = pow(r, power - 1.0) * power * dr + 1.0;

        float zr = pow(r, power);
        theta *= power;
        phi *= power;

        z = zr * float3(sin(theta) * cos(phi),
                         sin(phi) * sin(theta),
                         cos(theta));
        z += c;

        trap = min(trap, r);
    }

    return 0.5 * log(max(r, 1e-6)) * r / dr;
}

// ---- Mandelbox ("Amazing Box") -----------------------------------------
//
//   box-fold each axis into [-1, 1], then ball-fold around the origin
//   (invert points that fall inside a shrinking sphere), then scale and
//   recenter on the original point. `clamp(z,-1,1)*2-z` is the standard
//   branchless form of the per-axis fold used in most shader ports.

inline float mandelboxDE(float3 pos, constant Uniforms &u, thread float &trap) {
    float3 z = pos;
    float dr = 1.0;
    trap = 1e10;
    float scale = u.mbScale;

    for (int i = 0; i < u.maxIterations; i++) {
        z = clamp(z, -1.0, 1.0) * 2.0 - z;

        float r2 = dot(z, z);
        if (r2 < u.mbMinRadius2) {
            float t = u.mbFixedRadius2 / u.mbMinRadius2;
            z *= t;
            dr *= t;
        } else if (r2 < u.mbFixedRadius2) {
            float t = u.mbFixedRadius2 / r2;
            z *= t;
            dr *= t;
        }

        z = z * scale + pos;
        dr = dr * abs(scale) + 1.0;
        trap = min(trap, length(z));
    }

    return length(z) / abs(dr);
}

// ---- Menger Sponge -------------------------------------------------------
//
// Inigo Quilez's folded-box formulation: repeatedly fold space into a
// unit cell, take the SDF of a "cross" of three boxes there, and carve
// it out of the running box SDF at ever-finer scale.

inline float sdBox(float3 p, float3 b) {
    float3 d = abs(p) - b;
    return length(max(d, float3(0.0))) + min(max(d.x, max(d.y, d.z)), 0.0);
}

inline float mengerSpongeDE(float3 pos, constant Uniforms &u, thread float &trap) {
    float d = sdBox(pos, float3(1.0));
    float s = 1.0;
    trap = 1e10;

    int foldIterations = clamp(u.maxIterations, 1, 8);
    for (int m = 0; m < foldIterations; m++) {
        float3 a = glslMod(pos * s + u.ifsOffset.xyz, float3(2.0)) - float3(1.0);
        s *= u.ifsScale;

        float3 r = abs(float3(1.0) - u.ifsScale * abs(a));
        float da = max(r.x, r.y);
        float db = max(r.y, r.z);
        float dc = max(r.z, r.x);
        float c = (min(da, min(db, dc)) - 1.0) / s;

        d = max(d, c);
        trap = min(trap, length(a));
    }

    return d;
}

// ---- Sierpinski Tetrahedron ----------------------------------------------
//
// Classic tetrahedral-fold IFS: reflect into the dominant octant pair
// at each step, then scale-and-translate away from the fold offset.

inline float sierpinskiDE(float3 pos, constant Uniforms &u, thread float &trap) {
    float3 z = pos;
    float scale = u.ifsScale;
    float r = 1.0;
    trap = 1e10;

    for (int i = 0; i < u.maxIterations; i++) {
        if (z.x + z.y < 0.0) z.xy = -z.yx;
        if (z.x + z.z < 0.0) z.xz = -z.zx;
        if (z.y + z.z < 0.0) z.yz = -z.zy;

        z = z * scale - u.ifsOffset.xyz * (scale - 1.0);
        r *= scale;
        trap = min(trap, length(z));
    }

    return length(z) / r;
}

// ---- Quaternion Julia -----------------------------------------------------
//
// Iterate q -> q^2 + c in the quaternions, tracking the derivative
// quaternion qp so the escape-time count becomes a distance bound.
// The 3D scene is the w=0 slice of the 4D set.

inline float4 quatMul(float4 a, float4 b) {
    // Components stored as (x, y, z, w) with w as the real part.
    return float4(
        a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
    );
}

inline float quaternionJuliaDE(float3 pos, constant Uniforms &u, thread float &trap) {
    float4 q = float4(pos, 0.0);
    float4 qp = float4(0.0, 0.0, 0.0, 1.0);
    float4 c = u.juliaC;
    trap = 1e10;

    for (int i = 0; i < u.maxIterations; i++) {
        qp = 2.0 * quatMul(q, qp);
        q = quatMul(q, q) + c;
        trap = min(trap, length(q));
        if (dot(q, q) > u.bailout) {
            break;
        }
    }

    float qlen = length(q);
    return 0.5 * qlen * log(max(qlen, 1e-6)) / max(length(qp), 1e-6);
}

// ---- Apollonian Gasket ------------------------------------------------------
//
// Knighty's sphere-inversion fractal: repeatedly fold into the unit
// cell and invert through a sphere, accumulating the total scale so the
// running distance estimate can be corrected back to world space.

inline float apollonianDE(float3 pos, constant Uniforms &u, thread float &trap) {
    float3 p = pos;
    float scale = 1.0;
    trap = 1e10;

    for (int i = 0; i < u.maxIterations; i++) {
        p = -1.0 + 2.0 * fract(0.5 * p + 0.5 + u.ifsOffset.xyz);
        float r2 = dot(p, p);
        float k = max(u.ifsScale / r2, 1.0);
        p *= k;
        scale *= k;
        trap = min(trap, r2);
    }

    return (0.25 * abs(p.y)) / scale;
}

// ---- Kaleidoscopic IFS (KIFS) ---------------------------------------------
//
// The same tetrahedral fold as the Sierpinski DE above, generalized
// with a configurable rotation applied each iteration before folding.
// This one engine — via ifsScale/ifsOffset/kifsRotationAngle/
// kifsRotationAxis — reaches most of the visual range of Mandelbulber2's
// abox_*/difs_* formula family, which differ from each other mainly in
// exactly these parameters.

inline float kifsDE(float3 pos, constant Uniforms &u, thread float &trap) {
    float3 z = pos;
    float scale = u.ifsScale;
    float r = 1.0;
    trap = 1e10;

    for (int i = 0; i < u.maxIterations; i++) {
        z = rotateAroundAxis(z, u.kifsRotationAxis.xyz, u.kifsRotationAngle);
        z = abs(z);

        if (z.x - z.y < 0.0) z.xy = z.yx;
        if (z.x - z.z < 0.0) z.xz = z.zx;
        if (z.y - z.z < 0.0) z.yz = z.zy;

        z = z * scale - u.ifsOffset.xyz * (scale - 1.0);
        r *= scale;
        trap = min(trap, length(z));
    }

    return length(z) / r;
}

// ---- Hybrid --------------------------------------------------------------
//
// Mandelbulber2's actual "hybrid fractal" mechanism: rather than one
// formula running its own escape-time loop, up to three formulas each
// contribute a single iteration step to one shared point z, combined
// into the running state via a per-slot operator and blend weight.
// Chain (the default) is plain function composition — each slot
// transforms whatever the previous one produced, which is how hybrids
// normally work. Add/Subtract/Cross instead combine the current point
// with this step's raw output as a vector operation, then blend that
// combination in by the slot's weight — CSG-style mixing rather than
// pure composition.

inline float3 hybridStepMandelbulb(float3 z, float3 c, float power, thread float &dr) {
    float r = length(z);
    if (r < 1e-6) {
        return z;
    }
    float theta = acos(clamp(z.z / r, -1.0, 1.0));
    float phi = atan2(z.y, z.x);
    dr = pow(r, power - 1.0) * power * dr + 1.0;
    float zr = pow(r, power);
    theta *= power;
    phi *= power;
    float3 next = zr * float3(sin(theta) * cos(phi), sin(phi) * sin(theta), cos(theta));
    return next + c;
}

inline float3 hybridStepMandelbox(float3 z, float3 c, constant Uniforms &u, thread float &dr) {
    z = clamp(z, -1.0, 1.0) * 2.0 - z;
    float r2 = dot(z, z);
    if (r2 < u.mbMinRadius2) {
        float t = u.mbFixedRadius2 / u.mbMinRadius2;
        z *= t;
        dr *= t;
    } else if (r2 < u.mbFixedRadius2) {
        float t = u.mbFixedRadius2 / r2;
        z *= t;
        dr *= t;
    }
    z = z * u.mbScale + c;
    dr = dr * abs(u.mbScale) + 1.0;
    return z;
}

inline float3 hybridStepKIFS(float3 z, constant Uniforms &u, thread float &dr) {
    z = rotateAroundAxis(z, u.kifsRotationAxis.xyz, u.kifsRotationAngle);
    z = abs(z);
    if (z.x - z.y < 0.0) z.xy = z.yx;
    if (z.x - z.z < 0.0) z.xz = z.zx;
    if (z.y - z.z < 0.0) z.yz = z.zy;
    z = z * u.ifsScale - u.ifsOffset.xyz * (u.ifsScale - 1.0);
    dr *= abs(u.ifsScale);
    return z;
}

inline float3 applyHybridSlot(float3 z, float3 pos, int formula, int op, float weight,
                               constant Uniforms &u, thread float &dr) {
    if (formula == HybridFormulaOff || weight <= 0.0) {
        return z;
    }

    float3 stepResult = z;
    switch (formula) {
        case HybridFormulaMandelbulb: stepResult = hybridStepMandelbulb(z, pos, u.power, dr); break;
        case HybridFormulaMandelbox:  stepResult = hybridStepMandelbox(z, pos, u, dr); break;
        case HybridFormulaKIFS:       stepResult = hybridStepKIFS(z, u, dr); break;
        default: break;
    }

    float3 combined = stepResult;
    switch (op) {
        case HybridOpChain:    combined = stepResult; break;
        case HybridOpAdd:      combined = z + stepResult; break;
        case HybridOpSubtract: combined = z - stepResult; break;
        case HybridOpCross:    combined = cross(z, stepResult); break;
        default: break;
    }

    return mix(z, combined, weight);
}

inline float hybridDE(float3 pos, constant Uniforms &u, thread float &trap) {
    float3 z = pos;
    float dr = 1.0;
    trap = 1e10;

    for (int i = 0; i < u.maxIterations; i++) {
        float r = length(z);
        if (r * r > u.bailout) {
            break;
        }

        z = applyHybridSlot(z, pos, u.hybridFormulas.x, u.hybridOps.x, u.hybridWeights.x, u, dr);
        z = applyHybridSlot(z, pos, u.hybridFormulas.y, u.hybridOps.y, u.hybridWeights.y, u, dr);
        z = applyHybridSlot(z, pos, u.hybridFormulas.z, u.hybridOps.z, u.hybridWeights.z, u, dr);

        trap = min(trap, length(z));
    }

    float r = length(z);
    return 0.5 * log(max(r, 1e-6)) * r / max(dr, 1e-6);
}

// ---- Dispatch --------------------------------------------------------------

inline float sceneDE(float3 pos, constant Uniforms &u, thread float &trap) {
    switch (u.fractalType) {
        case FractalTypeMandelbox:       return mandelboxDE(pos, u, trap);
        case FractalTypeMengerSponge:    return mengerSpongeDE(pos, u, trap);
        case FractalTypeSierpinskiTetra: return sierpinskiDE(pos, u, trap);
        case FractalTypeQuaternionJulia: return quaternionJuliaDE(pos, u, trap);
        case FractalTypeApollonian:      return apollonianDE(pos, u, trap);
        case FractalTypeKIFS:            return kifsDE(pos, u, trap);
        case FractalTypeHybrid:          return hybridDE(pos, u, trap);
        case FractalTypeMandelbulb:
        default:                          return mandelbulbDE(pos, u, trap);
    }
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
    // gives an organic, banded color pattern characteristic of these
    // fractal families.
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

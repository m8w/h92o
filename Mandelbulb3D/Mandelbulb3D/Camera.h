//
//  Camera.h
//  Mandelbulb3D
//
//  Plain C++ orbit camera: no Objective-C, no Metal — just the math,
//  so it is easy to unit test or reuse outside the renderer.
//

#pragma once

#include <simd/simd.h>
#include <algorithm>
#include <cmath>

class Camera {
public:
    float azimuth   = 0.9f;    // radians, rotation around Y
    float elevation = 0.45f;   // radians, clamped to avoid gimbal flip
    float distance  = 3.2f;    // distance from target
    float fovDegrees = 45.0f;

    simd_float3 target = {0.0f, 0.0f, 0.0f};

    static constexpr float kMinDistance = 0.6f;
    static constexpr float kMaxDistance = 12.0f;
    static constexpr float kMaxElevation = 1.55f; // just under 90 degrees

    void orbit(float deltaAzimuth, float deltaElevation) {
        azimuth += deltaAzimuth;
        elevation = std::clamp(elevation + deltaElevation, -kMaxElevation, kMaxElevation);
    }

    void dolly(float delta) {
        distance = std::clamp(distance + delta, kMinDistance, kMaxDistance);
    }

    simd_float3 position() const {
        const float ce = std::cos(elevation);
        simd_float3 p;
        p.x = target.x + distance * ce * std::sin(azimuth);
        p.y = target.y + distance * std::sin(elevation);
        p.z = target.z + distance * ce * std::cos(azimuth);
        return p;
    }

    // Right-handed camera basis: forward looks at target, right/up orthonormal.
    void basis(simd_float3 &forward, simd_float3 &right, simd_float3 &up) const {
        const simd_float3 eye = position();
        forward = simd_normalize(target - eye);
        const simd_float3 worldUp = {0.0f, 1.0f, 0.0f};
        right = simd_normalize(simd_cross(forward, worldUp));
        up = simd_cross(right, forward);
    }

    float tanHalfFov() const {
        return std::tan((fovDegrees * 0.5f) * (float)M_PI / 180.0f);
    }
};

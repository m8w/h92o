//
//  Renderer.mm
//  Mandelbulb3D
//

#import "Renderer.h"
#import "ShaderTypes.h"
#import "Camera.h"

#include <CoreFoundation/CoreFoundation.h>
#include <simd/simd.h>
#include <algorithm>
#include <cmath>

static const NSUInteger kMaxFramesInFlight = 3;
static const int kHybridPresetCount = 4;

// ---- Color: small RGB<->HSV helpers, used to hue-shift the palette
// for the "Animate Color" toggle without disturbing saturation/value. ----

static simd_float3 rgbToHsv(simd_float3 c) {
    float maxC = std::max(c.x, std::max(c.y, c.z));
    float minC = std::min(c.x, std::min(c.y, c.z));
    float delta = maxC - minC;

    float h = 0.0f;
    if (delta > 1e-6f) {
        if (maxC == c.x) {
            h = fmodf((c.y - c.z) / delta, 6.0f);
        } else if (maxC == c.y) {
            h = (c.z - c.x) / delta + 2.0f;
        } else {
            h = (c.x - c.y) / delta + 4.0f;
        }
        h *= 60.0f;
        if (h < 0.0f) {
            h += 360.0f;
        }
    }

    float s = (maxC <= 1e-6f) ? 0.0f : (delta / maxC);
    return simd_make_float3(h, s, maxC);
}

static simd_float3 hsvToRgb(simd_float3 hsv) {
    float h = hsv.x, s = hsv.y, v = hsv.z;
    float c = v * s;
    float x = c * (1.0f - fabsf(fmodf(h / 60.0f, 2.0f) - 1.0f));
    float m = v - c;

    simd_float3 rgb;
    if (h < 60.0f)        rgb = simd_make_float3(c, x, 0.0f);
    else if (h < 120.0f)  rgb = simd_make_float3(x, c, 0.0f);
    else if (h < 180.0f)  rgb = simd_make_float3(0.0f, c, x);
    else if (h < 240.0f)  rgb = simd_make_float3(0.0f, x, c);
    else if (h < 300.0f)  rgb = simd_make_float3(x, 0.0f, c);
    else                   rgb = simd_make_float3(c, 0.0f, x);

    return rgb + simd_make_float3(m, m, m);
}

static simd_float3 hueRotate(simd_float3 color, float degrees) {
    if (degrees == 0.0f) {
        return color;
    }
    simd_float3 hsv = rgbToHsv(color);
    hsv.x = fmodf(hsv.x + degrees, 360.0f);
    if (hsv.x < 0.0f) {
        hsv.x += 360.0f;
    }
    return hsvToRgb(hsv);
}

@interface Renderer ()
- (void)applyPresetForFractalType:(int)type;
- (void)applyHybridPresetAtIndex:(int)index;
@end

@implementation Renderer {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipelineState;

    dispatch_semaphore_t _frameSemaphore;

    Camera _camera;
    CFTimeInterval _startTime;
    CFTimeInterval _lastFrameTime;

    // Shared render parameters.
    int _maxSteps;
    float _epsilon;
    float _maxDistance;
    float _aoStrength;
    BOOL _shadowsEnabled;
    int _maxIterations;
    int _fractalType;
    simd_float3 _colorA;
    simd_float3 _colorB;

    // Animation: 5 independent toggles, identical across every fractal
    // type, plus a global speed multiplier. Param A/B are each
    // fractal's own two parameters (see -parameterNameA/B); the other
    // three are universal and work the same regardless of fractal.
    BOOL _animateParamA;
    BOOL _animateParamB;
    BOOL _animateCameraOrbit;
    BOOL _animateLight;
    BOOL _animateColor;
    float _animationSpeed;
    float _phaseA;          // accumulated phase, advances only while animateParamA is on
    float _phaseB;          // accumulated phase, advances only while animateParamB is on
    float _lightAngle;      // accumulated angle, advances only while animateLight is on
    float _colorHueShift;   // accumulated degrees, advances only while animateColor is on

    // Mandelbulb / Juliabulb.
    float _power;
    BOOL _juliaMode;
    float _bailout;

    // Mandelbox.
    float _mbScale;
    float _mbMinRadius2;
    float _mbFixedRadius2;

    // Menger / Sierpinski / Apollonian / KIFS.
    float _ifsScale;
    simd_float3 _ifsOffset;

    // KIFS: extra per-iteration rotation, on top of the fold.
    float _kifsRotationAngle;
    simd_float3 _kifsRotationAxis;

    // Juliabulb / Quaternion Julia constant.
    simd_float4 _juliaC;

    // Hybrid: up to 3 slots, each an optional formula + combine
    // operator + blend weight, cycled via a small set of built-in
    // presets (see -applyHybridPresetAtIndex:).
    int _hybridFormula[3];
    int _hybridOp[3];
    float _hybridWeight[3];
    int _hybridPresetIndex;

    // Preset values captured on type switch: animation oscillates
    // around these rather than drifting off whatever the last frame
    // left behind. Two independent parameters are animated per
    // fractal type, each with its own base + amplitude + frequency.
    float _basePower;
    float _baseBailout;
    float _baseMbScale;
    float _baseMbFixedRadius2;
    float _baseIfsScale;
    simd_float3 _baseIfsOffset;
    float _baseKifsRotationAngle;
    simd_float4 _baseJuliaC;
    float _baseHybridWeight[3];

    vector_uint2 _viewportSize;
}

- (nullable instancetype)initWithMetalKitView:(MTKView *)view {
    self = [super init];
    if (!self) {
        return nil;
    }

    _device = view.device;
    _commandQueue = [_device newCommandQueue];
    _frameSemaphore = dispatch_semaphore_create(kMaxFramesInFlight);

    _startTime = CFAbsoluteTimeGetCurrent();
    _lastFrameTime = _startTime;

    _maxSteps = 256;
    _aoStrength = 0.9f;
    _shadowsEnabled = YES;
    _animateParamA = NO;
    _animateParamB = NO;
    _animateCameraOrbit = NO;
    _animateLight = NO;
    _animateColor = NO;
    _animationSpeed = 1.0f;

    [self applyPresetForFractalType:FractalTypeMandelbulb];

    view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    view.clearColor = MTLClearColorMake(0.02, 0.02, 0.05, 1.0);

    NSError *error = nil;
    id<MTLLibrary> library = [_device newDefaultLibrary];
    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"vertexShader"];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"fragmentShader"];

    MTLRenderPipelineDescriptor *pipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDescriptor.label = @"Mandelbulb Pipeline";
    pipelineDescriptor.vertexFunction = vertexFunction;
    pipelineDescriptor.fragmentFunction = fragmentFunction;
    pipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat;

    _pipelineState = [_device newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error];
    if (!_pipelineState) {
        NSLog(@"Failed to create pipeline state: %@", error);
        return nil;
    }

    _viewportSize.x = (uint32_t)view.drawableSize.width;
    _viewportSize.y = (uint32_t)view.drawableSize.height;

    return self;
}

#pragma mark - Fractal presets

// Each fractal family needs different iteration counts, epsilon,
// camera framing, and its own parameters to look right by default.
// Switching types re-applies all of it rather than leaving over
// leftover values from whatever was selected before.
- (void)applyPresetForFractalType:(int)type {
    _fractalType = type;
    _juliaMode = NO;
    _power = 8.0f;
    _bailout = 4.0f;
    _mbScale = -1.5f;
    _mbMinRadius2 = 0.25f;
    _mbFixedRadius2 = 1.0f;
    _ifsScale = 2.0f;
    _ifsOffset = simd_make_float3(1.0f, 1.0f, 1.0f);
    _kifsRotationAngle = 0.0f;
    _kifsRotationAxis = simd_make_float3(0.0f, 1.0f, 0.0f);
    _juliaC = simd_make_float4(-0.2f, 0.8f, 0.0f, 0.0f);

    switch (type) {
        case FractalTypeMandelbulb:
            _maxIterations = 10;
            _epsilon = 0.0008f;
            _maxDistance = 12.0f;
            _colorA = simd_make_float3(0.05f, 0.35f, 0.85f);
            _colorB = simd_make_float3(0.95f, 0.55f, 0.15f);
            _camera.distance = 3.2f;
            break;

        case FractalTypeMandelbox:
            _maxIterations = 14;
            _epsilon = 0.0006f;
            _maxDistance = 24.0f;
            _colorA = simd_make_float3(0.05f, 0.65f, 0.60f);
            _colorB = simd_make_float3(0.85f, 0.10f, 0.55f);
            _camera.distance = 6.0f;
            break;

        case FractalTypeMengerSponge:
            _maxIterations = 4;
            _ifsScale = 3.0f;
            _epsilon = 0.0015f;
            _maxDistance = 8.0f;
            _colorA = simd_make_float3(0.90f, 0.65f, 0.15f);
            _colorB = simd_make_float3(0.10f, 0.20f, 0.65f);
            _camera.distance = 3.0f;
            break;

        case FractalTypeSierpinskiTetra:
            _maxIterations = 14;
            _ifsScale = 2.0f;
            _epsilon = 0.0008f;
            _maxDistance = 8.0f;
            _colorA = simd_make_float3(0.15f, 0.80f, 0.35f);
            _colorB = simd_make_float3(0.55f, 0.15f, 0.85f);
            _camera.distance = 3.2f;
            break;

        case FractalTypeQuaternionJulia:
            _maxIterations = 10;
            _bailout = 10.0f;
            _juliaC = simd_make_float4(-0.2f, 0.6f, 0.2f, 0.2f);
            _epsilon = 0.0008f;
            _maxDistance = 8.0f;
            _colorA = simd_make_float3(0.10f, 0.75f, 0.90f);
            _colorB = simd_make_float3(0.95f, 0.30f, 0.55f);
            _camera.distance = 3.0f;
            break;

        case FractalTypeApollonian:
            _maxIterations = 8;
            _ifsScale = 1.0f;
            _epsilon = 0.0004f;
            _maxDistance = 6.0f;
            _colorA = simd_make_float3(0.95f, 0.75f, 0.15f);
            _colorB = simd_make_float3(0.55f, 0.05f, 0.10f);
            _camera.distance = 2.4f;
            break;

        case FractalTypeKIFS:
            _maxIterations = 14;
            _ifsScale = 2.0f;
            _ifsOffset = simd_make_float3(1.0f, 1.0f, 1.0f);
            _kifsRotationAngle = 0.35f;
            _kifsRotationAxis = simd_make_float3(0.3f, 1.0f, 0.1f);
            _epsilon = 0.0008f;
            _maxDistance = 8.0f;
            _colorA = simd_make_float3(0.65f, 0.15f, 0.90f);
            _colorB = simd_make_float3(0.15f, 0.85f, 0.80f);
            _camera.distance = 3.2f;
            break;

        case FractalTypeHybrid:
            _maxIterations = 8;
            _bailout = 6.0f;
            _epsilon = 0.001f;
            _maxDistance = 8.0f;
            _colorA = simd_make_float3(0.90f, 0.20f, 0.35f);
            _colorB = simd_make_float3(0.20f, 0.55f, 0.95f);
            _camera.distance = 3.4f;
            _hybridPresetIndex = 0;
            [self applyHybridPresetAtIndex:0];
            break;
    }

    _basePower = _power;
    _baseBailout = _bailout;
    _baseMbScale = _mbScale;
    _baseMbFixedRadius2 = _mbFixedRadius2;
    _baseIfsScale = _ifsScale;
    _baseIfsOffset = _ifsOffset;
    _baseKifsRotationAngle = _kifsRotationAngle;
    _baseJuliaC = _juliaC;

    // Param A/B animation phases restart clean so the new type's
    // formulas begin exactly at their base value (sin(0) == 0); the
    // 3 universal animations (camera/light/color) are user
    // preferences that persist across type switches, same as
    // shadows/animation-speed, so their phases are left alone.
    _phaseA = 0.0f;
    _phaseB = 0.0f;

    _camera.azimuth = 0.9f;
    _camera.elevation = 0.45f;
}

// Hand-picked hybrid slot combinations, cycled with `,`/`.` while the
// Hybrid fractal is active. Each demonstrates a different combine
// operator so all four are worth seeing, not just tuning variations of
// one.
- (void)applyHybridPresetAtIndex:(int)index {
    _hybridPresetIndex = ((index % kHybridPresetCount) + kHybridPresetCount) % kHybridPresetCount;

    switch (_hybridPresetIndex) {
        case 0: // Bulb, twisted by a KIFS fold blended in.
            _hybridFormula[0] = HybridFormulaMandelbulb; _hybridOp[0] = HybridOpChain; _hybridWeight[0] = 1.0f;
            _hybridFormula[1] = HybridFormulaKIFS;       _hybridOp[1] = HybridOpAdd;   _hybridWeight[1] = 0.35f;
            _hybridFormula[2] = HybridFormulaOff;        _hybridOp[2] = HybridOpChain; _hybridWeight[2] = 0.0f;
            break;

        case 1: // Box, then bulb: classic sequential hybrid chaining.
            _hybridFormula[0] = HybridFormulaMandelbox;  _hybridOp[0] = HybridOpChain; _hybridWeight[0] = 1.0f;
            _hybridFormula[1] = HybridFormulaMandelbulb; _hybridOp[1] = HybridOpChain; _hybridWeight[1] = 0.6f;
            _hybridFormula[2] = HybridFormulaOff;        _hybridOp[2] = HybridOpChain; _hybridWeight[2] = 0.0f;
            break;

        case 2: // All three chained in sequence.
            _hybridFormula[0] = HybridFormulaMandelbulb; _hybridOp[0] = HybridOpChain; _hybridWeight[0] = 1.0f;
            _hybridFormula[1] = HybridFormulaMandelbox;  _hybridOp[1] = HybridOpChain; _hybridWeight[1] = 1.0f;
            _hybridFormula[2] = HybridFormulaKIFS;       _hybridOp[2] = HybridOpChain; _hybridWeight[2] = 1.0f;
            break;

        case 3: // Cross-product and subtract mixing instead of pure chaining.
            _hybridFormula[0] = HybridFormulaMandelbulb; _hybridOp[0] = HybridOpChain;    _hybridWeight[0] = 1.0f;
            _hybridFormula[1] = HybridFormulaKIFS;       _hybridOp[1] = HybridOpCross;    _hybridWeight[1] = 0.5f;
            _hybridFormula[2] = HybridFormulaMandelbox;  _hybridOp[2] = HybridOpSubtract; _hybridWeight[2] = 0.25f;
            break;
    }

    for (int i = 0; i < 3; i++) {
        _baseHybridWeight[i] = _hybridWeight[i];
    }
}

- (NSString *)currentFractalName {
    switch (_fractalType) {
        case FractalTypeMandelbulb:      return @"Mandelbulb";
        case FractalTypeMandelbox:       return @"Mandelbox";
        case FractalTypeMengerSponge:    return @"Menger Sponge";
        case FractalTypeSierpinskiTetra: return @"Sierpinski Tetrahedron";
        case FractalTypeQuaternionJulia: return @"Quaternion Julia";
        case FractalTypeApollonian:      return @"Apollonian Gasket";
        case FractalTypeKIFS:            return @"Kaleidoscopic IFS";
        case FractalTypeHybrid:          return [NSString stringWithFormat:@"Hybrid (preset %d)", _hybridPresetIndex + 1];
        default:                          return @"Unknown";
    }
}

- (void)selectFractalTypeAtIndex:(int)index {
    if (index < 0 || index >= FractalTypeCount) {
        return;
    }
    [self applyPresetForFractalType:index];
}

- (void)cycleFractalType:(BOOL)forward {
    int next = _fractalType + (forward ? 1 : -1);
    next = (next + FractalTypeCount) % FractalTypeCount;
    [self applyPresetForFractalType:next];
}

#pragma mark - Input

- (void)orbitByDeltaX:(float)deltaX deltaY:(float)deltaY {
    _camera.orbit(deltaX, deltaY);
}

- (void)dollyByDelta:(float)delta {
    _camera.dolly(delta);
}

- (void)adjustPowerByDelta:(float)delta {
    _power = std::clamp(_power + delta, 2.0f, 16.0f);
    _basePower = _power;
}

- (void)adjustIterationsByDelta:(int)delta {
    _maxIterations = std::clamp(_maxIterations + delta, 1, 24);
}

- (void)toggleAnimation {
    BOOL turnOn = !(_animateParamA || _animateParamB || _animateCameraOrbit || _animateLight || _animateColor);
    _animateParamA = turnOn;
    _animateParamB = turnOn;
    _animateCameraOrbit = turnOn;
    _animateLight = turnOn;
    _animateColor = turnOn;
}

- (void)toggleShadows {
    _shadowsEnabled = !_shadowsEnabled;
}

- (void)toggleJuliaMode {
    if (_fractalType == FractalTypeMandelbulb) {
        _juliaMode = !_juliaMode;
    }
}

- (void)toggleCameraOrbit {
    _animateCameraOrbit = !_animateCameraOrbit;
}

- (void)toggleLightAnimation {
    _animateLight = !_animateLight;
}

- (void)toggleColorAnimation {
    _animateColor = !_animateColor;
}

- (void)adjustAnimationSpeedByDelta:(float)delta {
    _animationSpeed = std::clamp(_animationSpeed + delta, 0.1f, 4.0f);
}

- (void)resetCamera {
    [self applyPresetForFractalType:_fractalType];
}

- (void)adjustSecondaryByDelta:(float)delta {
    if (_fractalType == FractalTypeKIFS) {
        _kifsRotationAngle += delta * 0.2f;
        _baseKifsRotationAngle = _kifsRotationAngle;
    } else if (_fractalType == FractalTypeHybrid) {
        [self applyHybridPresetAtIndex:_hybridPresetIndex + (delta > 0.0f ? 1 : -1)];
    }
}

#pragma mark - MTKViewDelegate

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    _viewportSize.x = (uint32_t)size.width;
    _viewportSize.y = (uint32_t)size.height;
}

- (void)drawInMTKView:(MTKView *)view {
    dispatch_semaphore_wait(_frameSemaphore, DISPATCH_TIME_FOREVER);

    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    CFTimeInterval elapsed = now - _startTime;

    // Per-frame delta time, not absolute elapsed time, drives every
    // animation below: each active toggle advances its own phase by
    // dt * animationSpeed. That makes turning a toggle on/off never
    // jump (the phase simply stops/resumes advancing) and makes
    // changing the speed slider apply immediately without rescaling
    // whatever's already happened -- unlike computing everything as a
    // function of absolute elapsed time, which would do both wrong.
    float dt = std::clamp((float)(now - _lastFrameTime), 0.0f, 0.1f);
    _lastFrameTime = now;
    float phaseStep = dt * _animationSpeed;

    // Two of a fractal's own parameters, independently toggleable --
    // see -parameterNameA/B for what each type calls them.
    if (_animateParamA) _phaseA += phaseStep;
    if (_animateParamB) _phaseB += phaseStep;
    if (_animateParamA || _animateParamB) {
        switch (_fractalType) {
            case FractalTypeMandelbulb:
                if (_animateParamA) _power = _basePower + sinf(_phaseA * 0.25f) * 2.5f;
                if (_animateParamB) _bailout = _baseBailout + sinf(_phaseB * 0.11f) * 1.5f;
                break;
            case FractalTypeMandelbox:
                if (_animateParamA) _mbScale = _baseMbScale + sinf(_phaseA * 0.2f) * 0.5f;
                if (_animateParamB) _mbFixedRadius2 = _baseMbFixedRadius2 + cosf(_phaseB * 0.13f) * 0.3f;
                break;
            case FractalTypeMengerSponge:
                if (_animateParamA) _ifsScale = _baseIfsScale + sinf(_phaseA * 0.15f) * 0.35f;
                if (_animateParamB) {
                    _ifsOffset = _baseIfsOffset + simd_make_float3(sinf(_phaseB * 0.09f) * 0.3f,
                                                                     cosf(_phaseB * 0.12f) * 0.3f,
                                                                     sinf(_phaseB * 0.07f) * 0.3f);
                }
                break;
            case FractalTypeSierpinskiTetra:
                if (_animateParamA) _ifsScale = _baseIfsScale + sinf(_phaseA * 0.2f) * 0.25f;
                if (_animateParamB) {
                    _ifsOffset = _baseIfsOffset + simd_make_float3(sinf(_phaseB * 0.16f) * 0.2f,
                                                                     cosf(_phaseB * 0.10f) * 0.2f,
                                                                     sinf(_phaseB * 0.13f) * 0.2f);
                }
                break;
            case FractalTypeQuaternionJulia:
                // Two independent rotating pairs: (x,y) at one rate,
                // (z,w) at another, composed into a Lissajous-like path
                // through the quaternion constant's 4D space.
                if (_animateParamA) {
                    _juliaC.x = _baseJuliaC.x + cosf(_phaseA * 0.30f) * 0.15f;
                    _juliaC.y = _baseJuliaC.y + sinf(_phaseA * 0.30f) * 0.15f;
                }
                if (_animateParamB) {
                    _juliaC.z = _baseJuliaC.z + cosf(_phaseB * 0.11f) * 0.15f;
                    _juliaC.w = _baseJuliaC.w + sinf(_phaseB * 0.11f) * 0.15f;
                }
                break;
            case FractalTypeApollonian:
                if (_animateParamA) _ifsScale = _baseIfsScale + sinf(_phaseA * 0.25f) * 0.15f;
                if (_animateParamB) {
                    _ifsOffset = _baseIfsOffset + simd_make_float3(sinf(_phaseB * 0.18f) * 0.1f,
                                                                     cosf(_phaseB * 0.14f) * 0.1f,
                                                                     0.0f);
                }
                break;
            case FractalTypeKIFS:
                // Continuous spin (not a pulse) reads as a turning
                // kaleidoscope; scale still breathes as the second param.
                if (_animateParamA) _kifsRotationAngle = _baseKifsRotationAngle + _phaseA * 0.15f;
                if (_animateParamB) _ifsScale = _baseIfsScale + sinf(_phaseB * 0.2f) * 0.3f;
                break;
            case FractalTypeHybrid:
                if (_animateParamA) _hybridWeight[0] = std::clamp(_baseHybridWeight[0] + sinf(_phaseA * 0.2f) * 0.3f, 0.0f, 1.0f);
                if (_animateParamB) _hybridWeight[1] = std::clamp(_baseHybridWeight[1] + cosf(_phaseB * 0.15f) * 0.3f, 0.0f, 1.0f);
                break;
        }
    }

    // Three more animations that work identically for every fractal
    // type, since they act on the camera/light/palette rather than on
    // fractal-specific parameters.
    if (_animateCameraOrbit) {
        _camera.azimuth += phaseStep * 0.3f;
    }
    if (_animateLight) {
        _lightAngle += phaseStep * 0.4f;
    }
    if (_animateColor) {
        _colorHueShift += phaseStep * 40.0f;
    }

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    commandBuffer.label = @"Mandelbulb Frame";

    dispatch_semaphore_t frameSemaphore = _frameSemaphore;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull) {
        dispatch_semaphore_signal(frameSemaphore);
    }];

    MTLRenderPassDescriptor *renderPassDescriptor = view.currentRenderPassDescriptor;
    if (renderPassDescriptor == nil) {
        dispatch_semaphore_signal(_frameSemaphore);
        [commandBuffer commit];
        return;
    }

    Uniforms uniforms;
    simd_float3 forward, right, up;
    _camera.basis(forward, right, up);
    simd_float3 eye = _camera.position();

    uniforms.cameraPosition = simd_make_float4(eye, 0.0f);
    uniforms.cameraForward = simd_make_float4(forward, 0.0f);
    uniforms.cameraRight = simd_make_float4(right, 0.0f);
    uniforms.cameraUp = simd_make_float4(up, 0.0f);
    uniforms.viewportSize = simd_make_float2((float)_viewportSize.x, (float)_viewportSize.y);
    uniforms.tanHalfFov = _camera.tanHalfFov();
    uniforms.time = (float)elapsed;

    uniforms.maxSteps = _maxSteps;
    uniforms.epsilon = _epsilon;
    uniforms.maxDistance = _maxDistance;
    uniforms.aoStrength = _aoStrength;

    uniforms.enableShadows = _shadowsEnabled ? 1 : 0;
    uniforms.fractalType = _fractalType;
    uniforms.juliaMode = _juliaMode ? 1 : 0;
    uniforms.maxIterations = _maxIterations;

    uniforms.power = _power;
    uniforms.mbScale = _mbScale;
    uniforms.mbMinRadius2 = _mbMinRadius2;
    uniforms.mbFixedRadius2 = _mbFixedRadius2;

    uniforms.ifsScale = _ifsScale;
    uniforms.bailout = _bailout;
    uniforms.kifsRotationAngle = _kifsRotationAngle;
    uniforms._pad0 = 0.0f;

    uniforms.ifsOffset = simd_make_float4(_ifsOffset, 0.0f);
    uniforms.juliaC = _juliaC;
    uniforms.kifsRotationAxis = simd_make_float4(_kifsRotationAxis, 0.0f);

    uniforms.hybridFormulas = simd_make_int4(_hybridFormula[0], _hybridFormula[1], _hybridFormula[2], 0);
    uniforms.hybridOps = simd_make_int4(_hybridOp[0], _hybridOp[1], _hybridOp[2], 0);
    uniforms.hybridWeights = simd_make_float4(_hybridWeight[0], _hybridWeight[1], _hybridWeight[2], 0.0f);

    simd_float3 lightDirection = simd_normalize(simd_make_float3(cosf(_lightAngle) * -0.7f, -1.0f, sinf(_lightAngle) * -0.7f));
    uniforms.lightDirection = simd_make_float4(lightDirection, 0.0f);
    uniforms.baseColorA = simd_make_float4(hueRotate(_colorA, _colorHueShift), 0.0f);
    uniforms.baseColorB = simd_make_float4(hueRotate(_colorB, _colorHueShift), 0.0f);

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    encoder.label = @"Mandelbulb Encoder";

    [encoder setRenderPipelineState:_pipelineState];
    [encoder setFragmentBytes:&uniforms length:sizeof(Uniforms) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];

    [commandBuffer presentDrawable:view.currentDrawable];
    [commandBuffer commit];
}

#pragma mark - Control panel: name lists

+ (NSArray<NSString *> *)fractalTypeNames {
    return @[@"Mandelbulb", @"Mandelbox", @"Menger Sponge", @"Sierpinski Tetrahedron",
             @"Quaternion Julia", @"Apollonian Gasket", @"Kaleidoscopic IFS", @"Hybrid"];
}

+ (NSArray<NSString *> *)hybridFormulaNames {
    return @[@"Off", @"Mandelbulb", @"Mandelbox", @"KIFS"];
}

+ (NSArray<NSString *> *)hybridOpNames {
    return @[@"Chain", @"Add", @"Subtract", @"Cross"];
}

#pragma mark - Control panel: getters

- (int)fractalType { return _fractalType; }
- (BOOL)juliaMode { return _juliaMode; }
- (BOOL)shadowsEnabled { return _shadowsEnabled; }
- (BOOL)animateParamA { return _animateParamA; }
- (BOOL)animateParamB { return _animateParamB; }
- (BOOL)animateCameraOrbit { return _animateCameraOrbit; }
- (BOOL)animateLight { return _animateLight; }
- (BOOL)animateColor { return _animateColor; }
- (float)animationSpeed { return _animationSpeed; }
- (float)power { return _power; }
- (int)maxIterations { return _maxIterations; }
- (float)ifsScale { return _ifsScale; }
- (float)mbScale { return _mbScale; }
- (float)mbFixedRadius2 { return _mbFixedRadius2; }
- (float)kifsRotationAngle { return _kifsRotationAngle; }

- (int)hybridFormulaAtSlot:(int)slot {
    return (slot >= 0 && slot < 3) ? _hybridFormula[slot] : HybridFormulaOff;
}

- (int)hybridOpAtSlot:(int)slot {
    return (slot >= 0 && slot < 3) ? _hybridOp[slot] : HybridOpChain;
}

- (float)hybridWeightAtSlot:(int)slot {
    return (slot >= 0 && slot < 3) ? _hybridWeight[slot] : 0.0f;
}

- (NSString *)parameterNameA {
    switch (_fractalType) {
        case FractalTypeMandelbulb:      return @"Power";
        case FractalTypeMandelbox:       return @"Scale";
        case FractalTypeMengerSponge:    return @"Fold Scale";
        case FractalTypeSierpinskiTetra: return @"Fold Scale";
        case FractalTypeQuaternionJulia: return @"C (x, y)";
        case FractalTypeApollonian:      return @"Fold Scale";
        case FractalTypeKIFS:            return @"Rotation";
        case FractalTypeHybrid:          return @"Slot A Weight";
        default:                          return @"Param A";
    }
}

- (NSString *)parameterNameB {
    switch (_fractalType) {
        case FractalTypeMandelbulb:      return @"Bailout";
        case FractalTypeMandelbox:       return @"Fixed Radius";
        case FractalTypeMengerSponge:    return @"Fold Offset";
        case FractalTypeSierpinskiTetra: return @"Fold Offset";
        case FractalTypeQuaternionJulia: return @"C (z, w)";
        case FractalTypeApollonian:      return @"Fold Offset";
        case FractalTypeKIFS:            return @"Fold Scale";
        case FractalTypeHybrid:          return @"Slot B Weight";
        default:                          return @"Param B";
    }
}

#pragma mark - Control panel: setters

- (void)setJuliaMode:(BOOL)enabled {
    if (_fractalType == FractalTypeMandelbulb) {
        _juliaMode = enabled;
    }
}

- (void)setShadowsEnabled:(BOOL)enabled {
    _shadowsEnabled = enabled;
}

- (void)setAnimateParamA:(BOOL)enabled {
    _animateParamA = enabled;
}

- (void)setAnimateParamB:(BOOL)enabled {
    _animateParamB = enabled;
}

- (void)setAnimateCameraOrbit:(BOOL)enabled {
    _animateCameraOrbit = enabled;
}

- (void)setAnimateLight:(BOOL)enabled {
    _animateLight = enabled;
}

- (void)setAnimateColor:(BOOL)enabled {
    _animateColor = enabled;
}

- (void)setAnimationSpeed:(float)speed {
    _animationSpeed = std::clamp(speed, 0.1f, 4.0f);
}

- (void)setPower:(float)value {
    _power = std::clamp(value, 2.0f, 16.0f);
    _basePower = _power;
}

- (void)setMaxIterations:(int)value {
    _maxIterations = std::clamp(value, 1, 24);
}

- (void)setIfsScale:(float)value {
    _ifsScale = value;
    _baseIfsScale = value;
}

- (void)setMbScale:(float)value {
    _mbScale = value;
    _baseMbScale = value;
}

- (void)setMbFixedRadius2:(float)value {
    _mbFixedRadius2 = std::max(value, 0.01f);
    _baseMbFixedRadius2 = _mbFixedRadius2;
}

- (void)setKifsRotationAngle:(float)value {
    _kifsRotationAngle = value;
    _baseKifsRotationAngle = value;
}

- (void)setHybridFormula:(int)formula atSlot:(int)slot {
    if (slot < 0 || slot >= 3) {
        return;
    }
    _hybridFormula[slot] = std::clamp(formula, (int)HybridFormulaOff, (int)HybridFormulaKIFS);
}

- (void)setHybridOp:(int)op atSlot:(int)slot {
    if (slot < 0 || slot >= 3) {
        return;
    }
    _hybridOp[slot] = std::clamp(op, (int)HybridOpChain, (int)HybridOpCross);
}

- (void)setHybridWeight:(float)weight atSlot:(int)slot {
    if (slot < 0 || slot >= 3) {
        return;
    }
    _hybridWeight[slot] = std::clamp(weight, 0.0f, 1.0f);
    _baseHybridWeight[slot] = _hybridWeight[slot];
}

@end

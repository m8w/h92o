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

static const NSUInteger kMaxFramesInFlight = 3;

@interface Renderer ()
- (void)applyPresetForFractalType:(int)type;
@end

@implementation Renderer {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipelineState;

    dispatch_semaphore_t _frameSemaphore;

    Camera _camera;
    CFTimeInterval _startTime;

    // Shared render parameters.
    int _maxSteps;
    float _epsilon;
    float _maxDistance;
    float _aoStrength;
    BOOL _shadowsEnabled;
    BOOL _animatePower;
    int _maxIterations;
    int _fractalType;
    simd_float3 _lightDirection;
    simd_float3 _colorA;
    simd_float3 _colorB;

    // Mandelbulb / Juliabulb.
    float _power;
    BOOL _juliaMode;
    float _bailout;

    // Mandelbox.
    float _mbScale;
    float _mbMinRadius2;
    float _mbFixedRadius2;

    // Menger / Sierpinski.
    float _ifsScale;
    simd_float3 _ifsOffset;

    // Juliabulb / Quaternion Julia constant.
    simd_float4 _juliaC;

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

    _maxSteps = 256;
    _aoStrength = 0.9f;
    _shadowsEnabled = YES;
    _animatePower = NO;
    _lightDirection = simd_normalize(simd_make_float3(-0.5f, -1.0f, -0.4f));

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
    }

    _camera.azimuth = 0.9f;
    _camera.elevation = 0.45f;
}

- (NSString *)currentFractalName {
    switch (_fractalType) {
        case FractalTypeMandelbulb:      return @"Mandelbulb";
        case FractalTypeMandelbox:       return @"Mandelbox";
        case FractalTypeMengerSponge:    return @"Menger Sponge";
        case FractalTypeSierpinskiTetra: return @"Sierpinski Tetrahedron";
        case FractalTypeQuaternionJulia: return @"Quaternion Julia";
        case FractalTypeApollonian:      return @"Apollonian Gasket";
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
}

- (void)adjustIterationsByDelta:(int)delta {
    _maxIterations = std::clamp(_maxIterations + delta, 1, 24);
}

- (void)toggleAnimation {
    _animatePower = !_animatePower;
}

- (void)toggleShadows {
    _shadowsEnabled = !_shadowsEnabled;
}

- (void)toggleJuliaMode {
    if (_fractalType == FractalTypeMandelbulb) {
        _juliaMode = !_juliaMode;
    }
}

- (void)resetCamera {
    [self applyPresetForFractalType:_fractalType];
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

    if (_animatePower && _fractalType == FractalTypeMandelbulb) {
        _power = 8.0f + sinf((float)elapsed * 0.25f) * 2.5f;
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
    uniforms._pad0 = 0.0f;
    uniforms._pad1 = 0.0f;

    uniforms.ifsOffset = simd_make_float4(_ifsOffset, 0.0f);
    uniforms.juliaC = _juliaC;

    uniforms.lightDirection = simd_make_float4(_lightDirection, 0.0f);
    uniforms.baseColorA = simd_make_float4(_colorA, 0.0f);
    uniforms.baseColorB = simd_make_float4(_colorB, 0.0f);

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    encoder.label = @"Mandelbulb Encoder";

    [encoder setRenderPipelineState:_pipelineState];
    [encoder setFragmentBytes:&uniforms length:sizeof(Uniforms) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];

    [commandBuffer presentDrawable:view.currentDrawable];
    [commandBuffer commit];
}

@end

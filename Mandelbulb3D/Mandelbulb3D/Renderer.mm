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

@implementation Renderer {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipelineState;

    dispatch_semaphore_t _frameSemaphore;

    Camera _camera;
    CFTimeInterval _startTime;

    // Fractal / render parameters, tweakable at runtime.
    float _power;
    int _maxIterations;
    int _maxSteps;
    float _epsilon;
    float _maxDistance;
    float _aoStrength;
    BOOL _shadowsEnabled;
    BOOL _animatePower;
    simd_float3 _lightDirection;

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

    _power = 8.0f;
    _maxIterations = 10;
    _maxSteps = 256;
    _epsilon = 0.0008f;
    _maxDistance = 12.0f;
    _aoStrength = 0.9f;
    _shadowsEnabled = YES;
    _animatePower = NO;
    _lightDirection = simd_normalize(simd_make_float3(-0.5f, -1.0f, -0.4f));

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
    _maxIterations = std::clamp(_maxIterations + delta, 2, 20);
}

- (void)toggleAnimation {
    _animatePower = !_animatePower;
}

- (void)toggleShadows {
    _shadowsEnabled = !_shadowsEnabled;
}

- (void)resetCamera {
    _camera.reset();
    _power = 8.0f;
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

    if (_animatePower) {
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
    uniforms.power = _power;
    uniforms.maxIterations = _maxIterations;
    uniforms.maxSteps = _maxSteps;
    uniforms.epsilon = _epsilon;
    uniforms.maxDistance = _maxDistance;
    uniforms.aoStrength = _aoStrength;
    uniforms.enableShadows = _shadowsEnabled ? 1 : 0;
    uniforms.lightDirection = simd_make_float4(_lightDirection, 0.0f);
    uniforms.baseColorA = simd_make_float4(0.05f, 0.35f, 0.85f, 0.0f);
    uniforms.baseColorB = simd_make_float4(0.95f, 0.55f, 0.15f, 0.0f);

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

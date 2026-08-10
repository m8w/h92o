//
//  Renderer.h
//  Mandelbulb3D
//
//  MTKViewDelegate that owns the Metal pipeline and the fractal/camera
//  state, and is also the target for the input-handling code in
//  MetalView (mouse orbit, scroll dolly, keyboard shortcuts).
//

#import <MetalKit/MetalKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface Renderer : NSObject <MTKViewDelegate>

- (nullable instancetype)initWithMetalKitView:(MTKView *)view;

// Input handlers, called from MetalView on the main thread.
- (void)orbitByDeltaX:(float)deltaX deltaY:(float)deltaY;
- (void)dollyByDelta:(float)delta;
- (void)adjustPowerByDelta:(float)delta;
- (void)adjustIterationsByDelta:(int)delta;
- (void)toggleAnimation;
- (void)toggleShadows;
- (void)toggleJuliaMode;
- (void)resetCamera;

// Secondary per-type control: KIFS's per-iteration rotation angle,
// or (for Hybrid) cycling to the next/previous built-in slot preset.
// A no-op for types that don't have a secondary control.
- (void)adjustSecondaryByDelta:(float)delta;

// Fractal-type switching. Each type ships with its own default
// parameters and camera framing (see -applyPresetForFractalType: in
// the .mm); switching resets those defaults.
- (void)selectFractalTypeAtIndex:(int)index;
- (void)cycleFractalType:(BOOL)forward;
- (nonnull NSString *)currentFractalName;

@end

NS_ASSUME_NONNULL_END

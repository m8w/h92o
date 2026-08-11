//
//  Renderer.h
//  Mandelbulb3D
//
//  MTKViewDelegate that owns the Metal pipeline and the fractal/camera
//  state. It's driven from two places: MetalView's keyboard/mouse
//  handlers (ViewController.mm) and the on-screen control panel
//  (ControlPanel.mm) — both just call these same methods, so keyboard
//  and UI stay interchangeable and in sync.
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

// Static name lists, for populating the control panel's dropdowns.
+ (nonnull NSArray<NSString *> *)fractalTypeNames;
+ (nonnull NSArray<NSString *> *)hybridFormulaNames;
+ (nonnull NSArray<NSString *> *)hybridOpNames;

// Current-state getters, for the control panel to read and display
// (including values changed by keyboard shortcuts or by animation, so
// the panel can poll and stay in sync rather than owning state itself).
- (int)fractalType;
- (BOOL)juliaMode;
- (BOOL)shadowsEnabled;
- (BOOL)animateParamA;
- (BOOL)animateParamB;
- (float)power;
- (int)maxIterations;
- (float)ifsScale;
- (float)mbScale;
- (float)mbFixedRadius2;
- (float)kifsRotationAngle;
- (int)hybridFormulaAtSlot:(int)slot;
- (int)hybridOpAtSlot:(int)slot;
- (float)hybridWeightAtSlot:(int)slot;

// Parameter names for whatever's being animated by the current
// fractal type (e.g. "Power" / "Bailout" for Mandelbulb), so the panel
// can label its two "Animate ⟨name⟩" checkboxes correctly per type.
- (nonnull NSString *)parameterNameA;
- (nonnull NSString *)parameterNameB;

// Direct setters, for the control panel's sliders/checkboxes/popups.
// (Keyboard shortcuts use the delta-based adjust*/toggle* methods
// above instead; both paths converge on the same ivars.)
- (void)setJuliaMode:(BOOL)enabled;
- (void)setShadowsEnabled:(BOOL)enabled;
- (void)setAnimateParamA:(BOOL)enabled;
- (void)setAnimateParamB:(BOOL)enabled;
- (void)setPower:(float)value;
- (void)setMaxIterations:(int)value;
- (void)setIfsScale:(float)value;
- (void)setMbScale:(float)value;
- (void)setMbFixedRadius2:(float)value;
- (void)setKifsRotationAngle:(float)value;
- (void)setHybridFormula:(int)formula atSlot:(int)slot;
- (void)setHybridOp:(int)op atSlot:(int)slot;
- (void)setHybridWeight:(float)weight atSlot:(int)slot;

@end

NS_ASSUME_NONNULL_END

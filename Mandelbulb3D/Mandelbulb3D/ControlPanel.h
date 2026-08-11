//
//  ControlPanel.h
//  Mandelbulb3D
//
//  On-screen control panel: a dropdown listing every fractal type, and
//  per-type sliders/checkboxes/popups for every tunable parameter and
//  its animation, mirroring (and extending) what the keyboard shortcuts
//  can do. Docked to the right of the MTKView by ViewController.
//

#import <Cocoa/Cocoa.h>

@class Renderer;

NS_ASSUME_NONNULL_BEGIN

@interface ControlPanel : NSView

- (instancetype)initWithFrame:(NSRect)frameRect renderer:(Renderer *)renderer;

@end

NS_ASSUME_NONNULL_END

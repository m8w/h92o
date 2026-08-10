//
//  ViewController.mm
//  Mandelbulb3D
//
//  Hosts the MTKView, wires it to a Renderer, and translates mouse /
//  scroll / keyboard input into camera-orbit and fractal-parameter
//  changes. A small on-screen HUD label documents the controls.
//

#import "ViewController.h"
#import "Renderer.h"
#import <Metal/Metal.h>

// MetalView: a thin MTKView subclass that forwards raw input events to
// the Renderer. Kept private to this file since nothing else needs it.
@interface MetalView : MTKView
@property (nonatomic, weak) Renderer *renderer;
@end

@implementation MetalView {
    NSPoint _lastMouseLocation;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)mouseDown:(NSEvent *)event {
    _lastMouseLocation = event.locationInWindow;
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint location = event.locationInWindow;
    float deltaX = (float)(location.x - _lastMouseLocation.x);
    float deltaY = (float)(location.y - _lastMouseLocation.y);
    _lastMouseLocation = location;

    const float sensitivity = 0.008f;
    [self.renderer orbitByDeltaX:-deltaX * sensitivity deltaY:deltaY * sensitivity];
}

- (void)scrollWheel:(NSEvent *)event {
    float delta = (float)(-event.scrollingDeltaY) * 0.02f;
    [self.renderer dollyByDelta:delta];
}

- (void)magnifyWithEvent:(NSEvent *)event {
    // Trackpad pinch-to-zoom.
    [self.renderer dollyByDelta:(float)(-event.magnification) * 2.0f];
}

- (void)keyDown:(NSEvent *)event {
    NSString *characters = event.charactersIgnoringModifiers;
    if (characters.length == 0) {
        [super keyDown:event];
        return;
    }

    unichar key = [characters characterAtIndex:0];
    switch (key) {
        case '=':
        case '+':
            [self.renderer adjustPowerByDelta:0.25f];
            break;
        case '-':
        case '_':
            [self.renderer adjustPowerByDelta:-0.25f];
            break;
        case ']':
            [self.renderer adjustIterationsByDelta:1];
            break;
        case '[':
            [self.renderer adjustIterationsByDelta:-1];
            break;
        case ' ':
            [self.renderer toggleAnimation];
            break;
        case 's':
        case 'S':
            [self.renderer toggleShadows];
            break;
        case 'r':
        case 'R':
            [self.renderer resetCamera];
            break;
        default:
            [super keyDown:event];
            break;
    }
}

@end

@implementation ViewController {
    Renderer *_renderer;
    MetalView *_metalView;
}

- (void)loadView {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSAssert(device != nil, @"This Mac does not support Metal. A Metal-capable GPU (Apple Silicon or supported discrete/integrated GPU) is required.");

    NSRect frame = NSMakeRect(0, 0, 1280, 800);
    NSView *container = [[NSView alloc] initWithFrame:frame];

    _metalView = [[MetalView alloc] initWithFrame:frame device:device];
    _metalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _metalView.preferredFramesPerSecond = 60;
    _metalView.paused = NO;
    _metalView.enableSetNeedsDisplay = NO;

    _renderer = [[Renderer alloc] initWithMetalKitView:_metalView];
    NSAssert(_renderer != nil, @"Renderer failed to initialize.");
    _metalView.delegate = _renderer;
    _metalView.renderer = _renderer;

    [container addSubview:_metalView];

    NSTextField *hud = [NSTextField labelWithString:
        @"Drag: orbit   Scroll/Pinch: zoom   +/-: power   [ ]: detail   Space: animate   S: shadows   R: reset"];
    hud.textColor = [NSColor colorWithWhite:1.0 alpha:0.75];
    hud.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.35];
    hud.drawsBackground = YES;
    hud.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    hud.bezeled = NO;
    hud.editable = NO;
    hud.selectable = NO;
    hud.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:hud];

    [NSLayoutConstraint activateConstraints:@[
        [hud.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:12],
        [hud.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-12],
    ]];

    self.view = container;
}

- (void)viewDidAppear {
    [super viewDidAppear];
    [self.view.window makeFirstResponder:_metalView];
}

@end

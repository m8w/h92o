//
//  ControlPanel.mm
//  Mandelbulb3D
//

#import "ControlPanel.h"
#import "Renderer.h"
#import "ShaderTypes.h"

static const CGFloat kRowSpacing = 6.0;
static const CGFloat kSliderWidth = 150.0;
static const CGFloat kValueLabelWidth = 48.0;

@interface ControlPanel ()
@property (nonatomic, strong) Renderer *renderer;
@end

@implementation ControlPanel {
    NSStackView *_mainStack;
    NSStackView *_dynamicStack;

    NSPopUpButton *_fractalPopup;
    NSButton *_juliaCheckbox;
    NSButton *_shadowsCheckbox;
    NSButton *_animateACheckbox;
    NSButton *_animateBCheckbox;

    NSSlider *_powerSlider;
    NSTextField *_powerValueLabel;
    NSSlider *_iterationsSlider;
    NSTextField *_iterationsValueLabel;

    // Only one of these groups is populated at a time, matching
    // whichever fractal type the dynamic section was last built for
    // (see -rebuildDynamicSection); the rest sit nil and unused.
    NSSlider *_mbScaleSlider;
    NSSlider *_mbFixedRadiusSlider;
    NSSlider *_ifsScaleSlider;
    NSSlider *_kifsRotationSlider;
    NSPopUpButton *_hybridFormulaPopups[3];
    NSPopUpButton *_hybridOpPopups[3];
    NSSlider *_hybridWeightSliders[3];

    int _lastBuiltFractalType;
    NSTimer *_refreshTimer;
}

- (instancetype)initWithFrame:(NSRect)frameRect renderer:(Renderer *)renderer {
    self = [super initWithFrame:frameRect];
    if (!self) {
        return nil;
    }

    _renderer = renderer;
    _lastBuiltFractalType = -1;

    [self buildUI];
    [self rebuildDynamicSection];
    [self refresh];

    // The panel lives as long as the app runs (never torn down while
    // the window is open), so a self-retaining repeating timer here
    // never actually leaks in practice -- there is nothing to tear
    // down until process exit.
    _refreshTimer = [NSTimer timerWithTimeInterval:0.2
                                             target:self
                                           selector:@selector(refresh)
                                           userInfo:nil
                                            repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_refreshTimer forMode:NSRunLoopCommonModes];

    return self;
}

#pragma mark - Layout helpers

- (NSTextField *)labelWithText:(NSString *)text {
    NSTextField *label = [NSTextField labelWithString:text];
    label.textColor = [NSColor secondaryLabelColor];
    label.font = [NSFont systemFontOfSize:11];
    return label;
}

- (NSStackView *)rowWithViews:(NSArray<NSView *> *)views {
    NSStackView *row = [NSStackView stackViewWithViews:views];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 6;
    row.alignment = NSLayoutAttributeCenterY;
    return row;
}

- (NSSlider *)sliderWithMin:(float)minValue
                         max:(float)maxValue
                      target:(id)target
                      action:(SEL)action {
    NSSlider *slider = [NSSlider sliderWithValue:minValue
                                         minValue:minValue
                                         maxValue:maxValue
                                           target:target
                                           action:action];
    slider.continuous = YES;
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    [slider.widthAnchor constraintEqualToConstant:kSliderWidth].active = YES;
    return slider;
}

- (NSTextField *)valueLabel {
    NSTextField *label = [NSTextField labelWithString:@"0.00"];
    label.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    label.alignment = NSTextAlignmentRight;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [label.widthAnchor constraintEqualToConstant:kValueLabelWidth].active = YES;
    return label;
}

#pragma mark - Static UI

- (void)buildUI {
    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.35].CGColor;

    _mainStack = [[NSStackView alloc] init];
    _mainStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    _mainStack.alignment = NSLayoutAttributeLeading;
    _mainStack.spacing = 10;
    _mainStack.edgeInsets = NSEdgeInsetsMake(14, 14, 14, 14);
    _mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_mainStack];
    [NSLayoutConstraint activateConstraints:@[
        [_mainStack.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_mainStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_mainStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    ]];

    NSTextField *title = [NSTextField labelWithString:@"Fractal Controls"];
    title.font = [NSFont boldSystemFontOfSize:13];
    title.textColor = [NSColor labelColor];
    [_mainStack addArrangedSubview:title];

    _fractalPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_fractalPopup addItemsWithTitles:[Renderer fractalTypeNames]];
    _fractalPopup.target = self;
    _fractalPopup.action = @selector(fractalPopupChanged:);
    [_mainStack addArrangedSubview:_fractalPopup];

    _juliaCheckbox = [NSButton checkboxWithTitle:@"Julia Mode" target:self action:@selector(juliaCheckboxChanged:)];
    [_mainStack addArrangedSubview:_juliaCheckbox];

    _shadowsCheckbox = [NSButton checkboxWithTitle:@"Soft Shadows" target:self action:@selector(shadowsCheckboxChanged:)];
    [_mainStack addArrangedSubview:_shadowsCheckbox];

    NSTextField *powerLabel = [self labelWithText:@"Power"];
    powerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [powerLabel.widthAnchor constraintEqualToConstant:70].active = YES;
    _powerSlider = [self sliderWithMin:2.0 max:16.0 target:self action:@selector(powerSliderChanged:)];
    _powerValueLabel = [self valueLabel];
    [_mainStack addArrangedSubview:[self rowWithViews:@[powerLabel, _powerSlider, _powerValueLabel]]];

    NSTextField *iterationsLabel = [self labelWithText:@"Iterations"];
    iterationsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [iterationsLabel.widthAnchor constraintEqualToConstant:70].active = YES;
    _iterationsSlider = [self sliderWithMin:1.0 max:24.0 target:self action:@selector(iterationsSliderChanged:)];
    _iterationsValueLabel = [self valueLabel];
    [_mainStack addArrangedSubview:[self rowWithViews:@[iterationsLabel, _iterationsSlider, _iterationsValueLabel]]];

    _animateACheckbox = [NSButton checkboxWithTitle:@"Animate A" target:self action:@selector(animateACheckboxChanged:)];
    [_mainStack addArrangedSubview:_animateACheckbox];

    _animateBCheckbox = [NSButton checkboxWithTitle:@"Animate B" target:self action:@selector(animateBCheckboxChanged:)];
    [_mainStack addArrangedSubview:_animateBCheckbox];

    NSBox *divider = [[NSBox alloc] init];
    divider.boxType = NSBoxSeparator;
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    [divider.widthAnchor constraintEqualToConstant:220].active = YES;
    [_mainStack addArrangedSubview:divider];

    _dynamicStack = [[NSStackView alloc] init];
    _dynamicStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    _dynamicStack.alignment = NSLayoutAttributeLeading;
    _dynamicStack.spacing = kRowSpacing;
    [_mainStack addArrangedSubview:_dynamicStack];

    NSButton *resetButton = [NSButton buttonWithTitle:@"Reset Fractal" target:self action:@selector(resetTapped:)];
    [_mainStack addArrangedSubview:resetButton];
}

#pragma mark - Dynamic (per-fractal-type) section

// Rebuilt only when the fractal type actually changes, not on every
// refresh tick, so an in-progress drag on one of these controls is
// never interrupted by the periodic sync.
- (void)rebuildDynamicSection {
    for (NSView *view in [_dynamicStack.arrangedSubviews copy]) {
        [_dynamicStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    _mbScaleSlider = nil;
    _mbFixedRadiusSlider = nil;
    _ifsScaleSlider = nil;
    _kifsRotationSlider = nil;
    for (int i = 0; i < 3; i++) {
        _hybridFormulaPopups[i] = nil;
        _hybridOpPopups[i] = nil;
        _hybridWeightSliders[i] = nil;
    }

    int type = [_renderer fractalType];
    _lastBuiltFractalType = type;

    switch (type) {
        case FractalTypeMandelbox: {
            [_dynamicStack addArrangedSubview:[self sliderRowWithLabel:@"Scale" min:-3.0 max:3.0
                                                                   action:@selector(mbScaleSliderChanged:)
                                                                   slider:&_mbScaleSlider]];
            [_dynamicStack addArrangedSubview:[self sliderRowWithLabel:@"Fixed Radius" min:0.1 max:3.0
                                                                   action:@selector(mbFixedRadiusSliderChanged:)
                                                                   slider:&_mbFixedRadiusSlider]];
            break;
        }
        case FractalTypeMengerSponge:
        case FractalTypeSierpinskiTetra:
        case FractalTypeApollonian: {
            [_dynamicStack addArrangedSubview:[self sliderRowWithLabel:@"Fold Scale" min:0.5 max:4.0
                                                                   action:@selector(ifsScaleSliderChanged:)
                                                                   slider:&_ifsScaleSlider]];
            break;
        }
        case FractalTypeKIFS: {
            [_dynamicStack addArrangedSubview:[self sliderRowWithLabel:@"Fold Scale" min:0.5 max:4.0
                                                                   action:@selector(ifsScaleSliderChanged:)
                                                                   slider:&_ifsScaleSlider]];
            [_dynamicStack addArrangedSubview:[self sliderRowWithLabel:@"Rotation" min:-3.14 max:3.14
                                                                   action:@selector(kifsRotationSliderChanged:)
                                                                   slider:&_kifsRotationSlider]];
            break;
        }
        case FractalTypeHybrid: {
            NSArray<NSString *> *formulaNames = [Renderer hybridFormulaNames];
            NSArray<NSString *> *opNames = [Renderer hybridOpNames];

            for (int slot = 0; slot < 3; slot++) {
                NSTextField *slotLabel = [self labelWithText:[NSString stringWithFormat:@"Slot %c", 'A' + slot]];

                NSPopUpButton *formulaPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
                [formulaPopup addItemsWithTitles:formulaNames];
                formulaPopup.tag = slot;
                formulaPopup.target = self;
                formulaPopup.action = @selector(hybridFormulaPopupChanged:);
                _hybridFormulaPopups[slot] = formulaPopup;

                NSPopUpButton *opPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
                [opPopup addItemsWithTitles:opNames];
                opPopup.tag = slot;
                opPopup.target = self;
                opPopup.action = @selector(hybridOpPopupChanged:);
                _hybridOpPopups[slot] = opPopup;

                [_dynamicStack addArrangedSubview:[self rowWithViews:@[slotLabel, formulaPopup, opPopup]]];

                NSTextField *weightLabel = [self labelWithText:@"  Weight"];
                NSSlider *weightSlider = [self sliderWithMin:0.0 max:1.0 target:self action:@selector(hybridWeightSliderChanged:)];
                weightSlider.tag = slot;
                _hybridWeightSliders[slot] = weightSlider;
                [_dynamicStack addArrangedSubview:[self rowWithViews:@[weightLabel, weightSlider]]];
            }
            break;
        }
        default:
            break;
    }
}

- (NSStackView *)sliderRowWithLabel:(NSString *)text
                                  min:(float)minValue
                                  max:(float)maxValue
                               action:(SEL)action
                               slider:(NSSlider * __strong *)outSlider {
    NSTextField *label = [self labelWithText:text];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [label.widthAnchor constraintEqualToConstant:80].active = YES;
    NSSlider *slider = [self sliderWithMin:minValue max:maxValue target:self action:action];
    if (outSlider) {
        *outSlider = slider;
    }
    return [self rowWithViews:@[label, slider]];
}

#pragma mark - Refresh (pulls current renderer state into the controls)

- (void)refresh {
    int type = [_renderer fractalType];
    if (type != _lastBuiltFractalType) {
        [self rebuildDynamicSection];
    }

    [_fractalPopup selectItemAtIndex:type];

    _juliaCheckbox.enabled = (type == FractalTypeMandelbulb);
    _juliaCheckbox.state = [_renderer juliaMode] ? NSControlStateValueOn : NSControlStateValueOff;
    _shadowsCheckbox.state = [_renderer shadowsEnabled] ? NSControlStateValueOn : NSControlStateValueOff;

    _animateACheckbox.title = [NSString stringWithFormat:@"Animate %@", [_renderer parameterNameA]];
    _animateBCheckbox.title = [NSString stringWithFormat:@"Animate %@", [_renderer parameterNameB]];
    _animateACheckbox.state = [_renderer animateParamA] ? NSControlStateValueOn : NSControlStateValueOff;
    _animateBCheckbox.state = [_renderer animateParamB] ? NSControlStateValueOn : NSControlStateValueOff;

    _powerSlider.floatValue = [_renderer power];
    _powerValueLabel.stringValue = [NSString stringWithFormat:@"%.2f", [_renderer power]];
    _iterationsSlider.floatValue = [_renderer maxIterations];
    _iterationsValueLabel.stringValue = [NSString stringWithFormat:@"%d", [_renderer maxIterations]];

    switch (type) {
        case FractalTypeMandelbox: {
            _mbScaleSlider.floatValue = [_renderer mbScale];
            _mbFixedRadiusSlider.floatValue = [_renderer mbFixedRadius2];
            break;
        }
        case FractalTypeMengerSponge:
        case FractalTypeSierpinskiTetra:
        case FractalTypeApollonian: {
            _ifsScaleSlider.floatValue = [_renderer ifsScale];
            break;
        }
        case FractalTypeKIFS: {
            _ifsScaleSlider.floatValue = [_renderer ifsScale];
            _kifsRotationSlider.floatValue = [_renderer kifsRotationAngle];
            break;
        }
        case FractalTypeHybrid: {
            for (int slot = 0; slot < 3; slot++) {
                [_hybridFormulaPopups[slot] selectItemAtIndex:[_renderer hybridFormulaAtSlot:slot]];
                [_hybridOpPopups[slot] selectItemAtIndex:[_renderer hybridOpAtSlot:slot]];
                _hybridWeightSliders[slot].floatValue = [_renderer hybridWeightAtSlot:slot];
            }
            break;
        }
        default:
            break;
    }
}

#pragma mark - Actions

- (void)fractalPopupChanged:(NSPopUpButton *)sender {
    [_renderer selectFractalTypeAtIndex:(int)sender.indexOfSelectedItem];
    [self refresh];
}

- (void)juliaCheckboxChanged:(NSButton *)sender {
    [_renderer setJuliaMode:(sender.state == NSControlStateValueOn)];
}

- (void)shadowsCheckboxChanged:(NSButton *)sender {
    [_renderer setShadowsEnabled:(sender.state == NSControlStateValueOn)];
}

- (void)animateACheckboxChanged:(NSButton *)sender {
    [_renderer setAnimateParamA:(sender.state == NSControlStateValueOn)];
}

- (void)animateBCheckboxChanged:(NSButton *)sender {
    [_renderer setAnimateParamB:(sender.state == NSControlStateValueOn)];
}

- (void)powerSliderChanged:(NSSlider *)sender {
    [_renderer setPower:sender.floatValue];
    _powerValueLabel.stringValue = [NSString stringWithFormat:@"%.2f", sender.floatValue];
}

- (void)iterationsSliderChanged:(NSSlider *)sender {
    [_renderer setMaxIterations:(int)lroundf(sender.floatValue)];
    _iterationsValueLabel.stringValue = [NSString stringWithFormat:@"%d", (int)lroundf(sender.floatValue)];
}

- (void)mbScaleSliderChanged:(NSSlider *)sender {
    [_renderer setMbScale:sender.floatValue];
}

- (void)mbFixedRadiusSliderChanged:(NSSlider *)sender {
    [_renderer setMbFixedRadius2:sender.floatValue];
}

- (void)ifsScaleSliderChanged:(NSSlider *)sender {
    [_renderer setIfsScale:sender.floatValue];
}

- (void)kifsRotationSliderChanged:(NSSlider *)sender {
    [_renderer setKifsRotationAngle:sender.floatValue];
}

- (void)hybridFormulaPopupChanged:(NSPopUpButton *)sender {
    [_renderer setHybridFormula:(int)sender.indexOfSelectedItem atSlot:(int)sender.tag];
}

- (void)hybridOpPopupChanged:(NSPopUpButton *)sender {
    [_renderer setHybridOp:(int)sender.indexOfSelectedItem atSlot:(int)sender.tag];
}

- (void)hybridWeightSliderChanged:(NSSlider *)sender {
    [_renderer setHybridWeight:sender.floatValue atSlot:(int)sender.tag];
}

- (void)resetTapped:(id)sender {
    [_renderer resetCamera];
    [self refresh];
}

@end

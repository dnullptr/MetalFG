#import "../Headers/MetalFGOverlay.h"
#import "../Headers/MetalFGSynchronizer.h"
#import <UIKit/UIKit.h>
#import <math.h>

// ============================================================================
// Transparent, Non-Blocking Overlay Window
// ============================================================================
@interface MetalFGOverlayWindow : UIWindow
@end

@implementation MetalFGOverlayWindow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.windowLevel = UIWindowLevelAlert + 10000.0;
        self.userInteractionEnabled = YES;
        self.clipsToBounds = NO;
    }
    return self;
}

- (instancetype)initWithWindowScene:(UIWindowScene *)windowScene {
    self = [super initWithWindowScene:windowScene];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.windowLevel = UIWindowLevelAlert + 10000.0;
        self.userInteractionEnabled = YES;
        self.clipsToBounds = NO;
    }
    return self;
}

// Touch Pass-Through: Forward touches outside our HUD elements directly to the game
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self || hitView == self.rootViewController.view) {
        return nil; // Pass touches through to game view hierarchy!
    }
    return hitView;
}

@end

// ============================================================================
// Auto-Rotating View Controller to match Game Orientation
// ============================================================================
@interface MetalFGOverlayViewController : UIViewController
@end

@implementation MetalFGOverlayViewController

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w != self.view.window && w.rootViewController && w.rootViewController != self) {
            return [w.rootViewController supportedInterfaceOrientations];
        }
    }
    #pragma clang diagnostic pop
    return UIInterfaceOrientationMaskAll;
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w != self.view.window && w.rootViewController && w.rootViewController != self) {
            return [w.rootViewController preferredInterfaceOrientationForPresentation];
        }
    }
    #pragma clang diagnostic pop
    return UIInterfaceOrientationLandscapeRight;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.view.userInteractionEnabled = YES;
}

@end

// ============================================================================
// In-Game Live Tuning Panel (Frosted Dark Glass)
// ============================================================================
@interface MetalFGTuningView : UIView {
    UISegmentedControl *_presetSegment;
    UISlider *_motionSlider;
    UILabel *_motionValLabel;
    UISlider *_ghostSlider;
    UILabel *_ghostValLabel;
    UISlider *_uiSlider;
    UILabel *_uiValLabel;
}

@property (nonatomic, copy) void (^onClose)(void);

- (void)syncControlsWithSynchronizer;

@end

@implementation MetalFGTuningView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.layer.cornerRadius = 18.0;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 1.2;
        self.layer.borderColor = [UIColor colorWithRed:0.20 green:0.85 blue:0.45 alpha:0.75].CGColor;
        
        // Frosted dark glass blur
        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        blurView.frame = self.bounds;
        blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        blurView.userInteractionEnabled = YES;
        [self addSubview:blurView];
        
        UIView *content = blurView.contentView;
        
        // Pan gesture to drag tuning card anywhere on screen
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];
        
        // Header: Title & Version
        UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, 170, 20)];
        titleLabel.text = @"⚡ MetalFG Tuning";
        titleLabel.textColor = [UIColor whiteColor];
        titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightBold];
        [content addSubview:titleLabel];
        
        UILabel *verLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 32, 170, 14)];
        verLabel.text = @"v1.1.0 • Live Shader Control";
        verLabel.textColor = [UIColor colorWithRed:0.20 green:0.85 blue:0.45 alpha:0.9];
        verLabel.font = [UIFont monospacedDigitSystemFontOfSize:9.5 weight:UIFontWeightMedium];
        [content addSubview:verLabel];
        
        // Close Button (✕)
        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(self.bounds.size.width - 42, 10, 28, 28);
        [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
        closeBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
        [closeBtn setTitleColor:[UIColor colorWithWhite:0.85 alpha:1.0] forState:UIControlStateNormal];
        closeBtn.backgroundColor = [UIColor colorWithWhite:0.22 alpha:0.7];
        closeBtn.layer.cornerRadius = 14.0;
        [closeBtn addTarget:self action:@selector(handleClose) forControlEvents:UIControlEventTouchUpInside];
        [content addSubview:closeBtn];
        
        // Preset Segmented Control
        _presetSegment = [[UISegmentedControl alloc] initWithItems:@[@"Clear", @"Balanced", @"Fluid"]];
        _presetSegment.frame = CGRectMake(16, 52, self.bounds.size.width - 32, 28);
        if (@available(iOS 13.0, *)) {
            _presetSegment.selectedSegmentTintColor = [UIColor colorWithRed:0.20 green:0.85 blue:0.45 alpha:0.85];
            [_presetSegment setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor blackColor], NSFontAttributeName: [UIFont systemFontOfSize:11.5 weight:UIFontWeightBold]} forState:UIControlStateSelected];
            [_presetSegment setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor], NSFontAttributeName: [UIFont systemFontOfSize:11.5 weight:UIFontWeightMedium]} forState:UIControlStateNormal];
        }
        [_presetSegment addTarget:self action:@selector(handlePresetChange:) forControlEvents:UIControlEventValueChanged];
        [content addSubview:_presetSegment];
        
        CGFloat w = self.bounds.size.width - 32;
        
        // --- Slider 1: Motion Warp Scale ---
        UILabel *mTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, 88, 180, 16)];
        mTitle.text = @"Motion Warp Scale";
        mTitle.textColor = [UIColor whiteColor];
        mTitle.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold];
        [content addSubview:mTitle];
        
        _motionValLabel = [[UILabel alloc] initWithFrame:CGRectMake(self.bounds.size.width - 96, 88, 80, 16)];
        _motionValLabel.textColor = [UIColor colorWithRed:0.20 green:0.85 blue:0.45 alpha:1.0];
        _motionValLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.5 weight:UIFontWeightBold];
        _motionValLabel.textAlignment = NSTextAlignmentRight;
        [content addSubview:_motionValLabel];
        
        UILabel *mSub = [[UILabel alloc] initWithFrame:CGRectMake(16, 104, w, 12)];
        mSub.text = @"Camera whip factor (lower = zero edge ghosting)";
        mSub.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
        mSub.font = [UIFont systemFontOfSize:9.5 weight:UIFontWeightRegular];
        [content addSubview:mSub];
        
        _motionSlider = [[UISlider alloc] initWithFrame:CGRectMake(16, 118, w, 24)];
        _motionSlider.minimumValue = 0.10f;
        _motionSlider.maximumValue = 0.80f;
        _motionSlider.minimumTrackTintColor = [UIColor colorWithRed:0.20 green:0.85 blue:0.45 alpha:1.0];
        [_motionSlider addTarget:self action:@selector(handleMotionSliderChange:) forControlEvents:UIControlEventValueChanged];
        [content addSubview:_motionSlider];
        
        // --- Slider 2: Ghost Rejection (Disocclusion Cutoff) ---
        UILabel *gTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, 150, 180, 16)];
        gTitle.text = @"Ghost Rejection";
        gTitle.textColor = [UIColor whiteColor];
        gTitle.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold];
        [content addSubview:gTitle];
        
        _ghostValLabel = [[UILabel alloc] initWithFrame:CGRectMake(self.bounds.size.width - 96, 150, 80, 16)];
        _ghostValLabel.textColor = [UIColor colorWithRed:0.25 green:0.80 blue:1.0 alpha:1.0];
        _ghostValLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.5 weight:UIFontWeightBold];
        _ghostValLabel.textAlignment = NSTextAlignmentRight;
        [content addSubview:_ghostValLabel];
        
        UILabel *gSub = [[UILabel alloc] initWithFrame:CGRectMake(16, 166, w, 12)];
        gSub.text = @"Disocclusion cutoff (prevents 50/50 double image)";
        gSub.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
        gSub.font = [UIFont systemFontOfSize:9.5 weight:UIFontWeightRegular];
        [content addSubview:gSub];
        
        _ghostSlider = [[UISlider alloc] initWithFrame:CGRectMake(16, 180, w, 24)];
        _ghostSlider.minimumValue = 0.10f;
        _ghostSlider.maximumValue = 0.40f;
        _ghostSlider.minimumTrackTintColor = [UIColor colorWithRed:0.25 green:0.80 blue:1.0 alpha:1.0];
        [_ghostSlider addTarget:self action:@selector(handleGhostSliderChange:) forControlEvents:UIControlEventValueChanged];
        [content addSubview:_ghostSlider];
        
        // --- Slider 3: UI / HUD Protection ---
        UILabel *uTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, 212, 180, 16)];
        uTitle.text = @"UI / HUD Protection";
        uTitle.textColor = [UIColor whiteColor];
        uTitle.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold];
        [content addSubview:uTitle];
        
        _uiValLabel = [[UILabel alloc] initWithFrame:CGRectMake(self.bounds.size.width - 96, 212, 80, 16)];
        _uiValLabel.textColor = [UIColor colorWithRed:1.0 green:0.75 blue:0.2 alpha:1.0];
        _uiValLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.5 weight:UIFontWeightBold];
        _uiValLabel.textAlignment = NSTextAlignmentRight;
        [content addSubview:_uiValLabel];
        
        UILabel *uSub = [[UILabel alloc] initWithFrame:CGRectMake(16, 228, w, 12)];
        uSub.text = @"Preserves static UI, skill buttons & minimap";
        uSub.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
        uSub.font = [UIFont systemFontOfSize:9.5 weight:UIFontWeightRegular];
        [content addSubview:uSub];
        
        _uiSlider = [[UISlider alloc] initWithFrame:CGRectMake(16, 242, w, 24)];
        _uiSlider.minimumValue = 0.010f;
        _uiSlider.maximumValue = 0.080f;
        _uiSlider.minimumTrackTintColor = [UIColor colorWithRed:1.0 green:0.75 blue:0.2 alpha:1.0];
        [_uiSlider addTarget:self action:@selector(handleUiSliderChange:) forControlEvents:UIControlEventValueChanged];
        [content addSubview:_uiSlider];
        
        // --- Done Button ---
        UIButton *doneBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        doneBtn.frame = CGRectMake(16, 280, w, 36);
        doneBtn.backgroundColor = [UIColor colorWithRed:0.20 green:0.85 blue:0.45 alpha:0.22];
        doneBtn.layer.cornerRadius = 10.0;
        doneBtn.layer.borderWidth = 1.0;
        doneBtn.layer.borderColor = [UIColor colorWithRed:0.20 green:0.85 blue:0.45 alpha:0.65].CGColor;
        [doneBtn setTitle:@"✓ Apply & Close" forState:UIControlStateNormal];
        [doneBtn setTitleColor:[UIColor colorWithRed:0.25 green:0.95 blue:0.55 alpha:1.0] forState:UIControlStateNormal];
        doneBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
        [doneBtn addTarget:self action:@selector(handleClose) forControlEvents:UIControlEventTouchUpInside];
        [content addSubview:doneBtn];
        
        [self syncControlsWithSynchronizer];
    }
    return self;
}

- (void)handlePan:(UIPanGestureRecognizer *)recognizer {
    UIView *superview = self.superview;
    if (!superview) return;
    
    CGPoint translation = [recognizer translationInView:superview];
    CGPoint newCenter = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    
    CGFloat halfW = self.bounds.size.width / 2.0;
    CGFloat halfH = self.bounds.size.height / 2.0;
    newCenter.x = fmaxf(halfW, fminf(superview.bounds.size.width - halfW, newCenter.x));
    newCenter.y = fmaxf(halfH, fminf(superview.bounds.size.height - halfH, newCenter.y));
    
    self.center = newCenter;
    [recognizer setTranslation:CGPointZero inView:superview];
}

- (void)syncControlsWithSynchronizer {
    MetalFGSynchronizer *sync = [MetalFGSynchronizer sharedSynchronizer];
    if (sync.currentPreset >= 0 && sync.currentPreset < 3) {
        _presetSegment.selectedSegmentIndex = sync.currentPreset;
    } else {
        _presetSegment.selectedSegmentIndex = UISegmentedControlNoSegment;
    }
    
    _motionSlider.value = sync.motionScale;
    _motionValLabel.text = [NSString stringWithFormat:@"%.0f%%", sync.motionScale * 100.0f];
    
    _ghostSlider.value = sync.disocclusionThreshold;
    _ghostValLabel.text = [NSString stringWithFormat:@"%.2f", sync.disocclusionThreshold];
    
    _uiSlider.value = sync.uiSensitivity;
    _uiValLabel.text = [NSString stringWithFormat:@"%.3f", sync.uiSensitivity];
}

- (void)handlePresetChange:(UISegmentedControl *)sender {
    [[MetalFGSynchronizer sharedSynchronizer] applyPreset:sender.selectedSegmentIndex];
    [self syncControlsWithSynchronizer];
    
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback prepare];
    [feedback impactOccurred];
}

- (void)handleMotionSliderChange:(UISlider *)sender {
    MetalFGSynchronizer *sync = [MetalFGSynchronizer sharedSynchronizer];
    sync.motionScale = sender.value;
    sync.currentPreset = 3; // Custom
    _presetSegment.selectedSegmentIndex = UISegmentedControlNoSegment;
    _motionValLabel.text = [NSString stringWithFormat:@"%.0f%%", sender.value * 100.0f];
    [sync savePreferences];
}

- (void)handleGhostSliderChange:(UISlider *)sender {
    MetalFGSynchronizer *sync = [MetalFGSynchronizer sharedSynchronizer];
    sync.disocclusionThreshold = sender.value;
    sync.currentPreset = 3; // Custom
    _presetSegment.selectedSegmentIndex = UISegmentedControlNoSegment;
    _ghostValLabel.text = [NSString stringWithFormat:@"%.2f", sender.value];
    [sync savePreferences];
}

- (void)handleUiSliderChange:(UISlider *)sender {
    MetalFGSynchronizer *sync = [MetalFGSynchronizer sharedSynchronizer];
    sync.uiSensitivity = sender.value;
    sync.currentPreset = 3; // Custom
    _presetSegment.selectedSegmentIndex = UISegmentedControlNoSegment;
    _uiValLabel.text = [NSString stringWithFormat:@"%.3f", sender.value];
    [sync savePreferences];
}

- (void)handleClose {
    if (self.onClose) {
        self.onClose();
    }
}

@end

// ============================================================================
// On-Screen Floating Pill Badge with Integrated Tuning Controls
// ============================================================================
@interface MetalFGOverlay () {
    UIView *_pillView;
    UIView *_statusDot;
    UILabel *_fpsLabel;
    UIButton *_gearButton;
    BOOL _isMinimized;
    MetalFGOverlayWindow *_overlayWindow;
    MetalFGTuningView *_tuningView;
}

@end

@implementation MetalFGOverlay

+ (instancetype)sharedOverlay {
    static MetalFGOverlay *sOverlay = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sOverlay = [[MetalFGOverlay alloc] initWithFrame:CGRectMake(50, 40, 224, 36)];
    });
    return sOverlay;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        self.layer.zPosition = 99999;
        _isMinimized = NO;
        
        // Background container pill
        _pillView = [[UIView alloc] initWithFrame:self.bounds];
        _pillView.backgroundColor = [UIColor colorWithRed:0.08 green:0.10 blue:0.12 alpha:0.88];
        _pillView.layer.cornerRadius = 18.0;
        _pillView.layer.masksToBounds = YES;
        _pillView.layer.borderWidth = 1.4;
        _pillView.layer.borderColor = [UIColor colorWithRed:0.20 green:0.85 blue:0.45 alpha:0.85].CGColor;
        [self addSubview:_pillView];
        
        // Pulsing status dot
        _statusDot = [[UIView alloc] initWithFrame:CGRectMake(10, 13, 10, 10)];
        _statusDot.backgroundColor = [UIColor colorWithRed:0.20 green:0.85 blue:0.45 alpha:1.0];
        _statusDot.layer.cornerRadius = 5.0;
        [_pillView addSubview:_statusDot];
        
        // FPS text label
        _fpsLabel = [[UILabel alloc] initWithFrame:CGRectMake(26, 0, 158, 36)];
        _fpsLabel.textColor = [UIColor whiteColor];
        _fpsLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.5 weight:UIFontWeightBold];
        _fpsLabel.text = @"⚡ MetalFG: Ready";
        _fpsLabel.adjustsFontSizeToFitWidth = YES;
        [_pillView addSubview:_fpsLabel];
        
        // Gear Button (⚙️) for instant one-tap access to live tuning panel
        _gearButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _gearButton.frame = CGRectMake(188, 3, 30, 30);
        [_gearButton setTitle:@"⚙️" forState:UIControlStateNormal];
        _gearButton.titleLabel.font = [UIFont systemFontOfSize:14];
        _gearButton.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.35];
        _gearButton.layer.cornerRadius = 15.0;
        [_gearButton addTarget:self action:@selector(handleGearTap) forControlEvents:UIControlEventTouchUpInside];
        [_pillView addSubview:_gearButton];
        
        // Gestures: Drag to move, Single-Tap to toggle FG ON/OFF, Double-Tap to minimize/expand, Long-Press to tune
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];
        
        UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleSingleTap:)];
        singleTap.numberOfTapsRequired = 1;
        [self addGestureRecognizer:singleTap];
        
        UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
        doubleTap.numberOfTapsRequired = 2;
        [self addGestureRecognizer:doubleTap];
        
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        longPress.minimumPressDuration = 0.5;
        [self addGestureRecognizer:longPress];
        
        [singleTap requireGestureRecognizerToFail:doubleTap];
        [singleTap requireGestureRecognizerToFail:longPress];
    }
    return self;
}

- (void)handlePan:(UIPanGestureRecognizer *)recognizer {
    UIView *superview = self.superview;
    if (!superview) return;
    
    CGPoint translation = [recognizer translationInView:superview];
    CGPoint newCenter = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    
    // Keep within screen bounds
    CGFloat halfW = self.bounds.size.width / 2.0;
    CGFloat halfH = self.bounds.size.height / 2.0;
    newCenter.x = fmaxf(halfW, fminf(superview.bounds.size.width - halfW, newCenter.x));
    newCenter.y = fmaxf(halfH, fminf(superview.bounds.size.height - halfH, newCenter.y));
    
    self.center = newCenter;
    [recognizer setTranslation:CGPointZero inView:superview];
}

- (void)handleSingleTap:(UITapGestureRecognizer *)recognizer {
    MetalFGSynchronizer *sync = [MetalFGSynchronizer sharedSynchronizer];
    sync.isEnabled = !sync.isEnabled;
    
    // Physical haptic feedback on toggle
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback prepare];
    [feedback impactOccurred];
    
    [UIView animateWithDuration:0.2 animations:^{
        if (sync.isEnabled) {
            self->_statusDot.backgroundColor = [UIColor colorWithRed:0.20 green:0.85 blue:0.45 alpha:1.0];
            self->_pillView.layer.borderColor = [UIColor colorWithRed:0.20 green:0.85 blue:0.45 alpha:0.85].CGColor;
            self->_fpsLabel.text = @"⚡ FG: Resuming...";
        } else {
            self->_statusDot.backgroundColor = [UIColor colorWithRed:0.65 green:0.65 blue:0.65 alpha:1.0];
            self->_pillView.layer.borderColor = [UIColor colorWithRed:0.55 green:0.55 blue:0.55 alpha:0.7].CGColor;
            self->_fpsLabel.text = @"⏸ FG: OFF (Native)";
        }
    }];
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)recognizer {
    _isMinimized = !_isMinimized;
    
    [UIView animateWithDuration:0.25 animations:^{
        if (self->_isMinimized) {
            self.bounds = CGRectMake(0, 0, 36, 36);
            self->_pillView.frame = self.bounds;
            self->_pillView.layer.cornerRadius = 18.0;
            self->_statusDot.center = CGPointMake(18, 18);
            self->_fpsLabel.alpha = 0.0;
            self->_gearButton.alpha = 0.0;
        } else {
            self.bounds = CGRectMake(0, 0, 224, 36);
            self->_pillView.frame = self.bounds;
            self->_pillView.layer.cornerRadius = 18.0;
            self->_statusDot.frame = CGRectMake(10, 13, 10, 10);
            self->_fpsLabel.alpha = 1.0;
            self->_gearButton.alpha = 1.0;
        }
    }];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        [self toggleTuningPanel];
    }
}

- (void)handleGearTap {
    [self toggleTuningPanel];
}

- (void)toggleTuningPanel {
    if (!_overlayWindow || !_overlayWindow.rootViewController) return;
    
    if (_tuningView && _tuningView.superview && !_tuningView.hidden) {
        // Dismiss with smooth scale-down animation
        [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
            self->_tuningView.alpha = 0.0;
            self->_tuningView.transform = CGAffineTransformMakeScale(0.88, 0.88);
        } completion:^(BOOL finished) {
            [self->_tuningView removeFromSuperview];
        }];
        return;
    }
    
    if (!_tuningView) {
        _tuningView = [[MetalFGTuningView alloc] initWithFrame:CGRectMake(0, 0, 310, 330)];
        __weak MetalFGOverlay *weakSelf = self;
        _tuningView.onClose = ^{
            [weakSelf toggleTuningPanel];
        };
    }
    
    [_tuningView syncControlsWithSynchronizer];
    
    UIView *rootView = _overlayWindow.rootViewController.view;
    [rootView addSubview:_tuningView];
    
    // Position tuning panel intelligently relative to the pill badge
    CGFloat px = self.frame.origin.x;
    CGFloat py = CGRectGetMaxY(self.frame) + 10.0;
    if (py + 330.0 > rootView.bounds.size.height) {
        py = fmaxf(20.0, self.frame.origin.y - 330.0 - 10.0);
    }
    if (px + 310.0 > rootView.bounds.size.width) {
        px = fmaxf(10.0, rootView.bounds.size.width - 320.0);
    }
    _tuningView.frame = CGRectMake(px, py, 310, 330);
    _tuningView.alpha = 0.0;
    _tuningView.transform = CGAffineTransformMakeScale(0.88, 0.88);
    
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [feedback prepare];
    [feedback impactOccurred];
    
    [UIView animateWithDuration:0.32 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_tuningView.alpha = 1.0;
        self->_tuningView.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *activeScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                if (ws.activationState == UISceneActivationStateForegroundActive ||
                    ws.activationState == UISceneActivationStateForegroundInactive) {
                    activeScene = ws;
                    break;
                }
            }
        }
        
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (!activeScene) {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (w.windowScene) {
                    activeScene = w.windowScene;
                    break;
                }
            }
        }
        #pragma clang diagnostic pop
        
        if (!self->_overlayWindow) {
            if (activeScene) {
                self->_overlayWindow = [[MetalFGOverlayWindow alloc] initWithWindowScene:activeScene];
                self->_overlayWindow.frame = activeScene.coordinateSpace.bounds;
            } else {
                self->_overlayWindow = [[MetalFGOverlayWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            }
            
            MetalFGOverlayViewController *vc = [[MetalFGOverlayViewController alloc] init];
            self->_overlayWindow.rootViewController = vc;
            [vc.view addSubview:self];
            
            // Set initial position: top-left with safe padding
            self.frame = CGRectMake(50, 40, 224, 36);
        } else {
            if (activeScene && self->_overlayWindow.windowScene != activeScene) {
                self->_overlayWindow.windowScene = activeScene;
                self->_overlayWindow.frame = activeScene.coordinateSpace.bounds;
            }
        }
        
        self->_overlayWindow.hidden = NO;
        if (self.superview) {
            [self.superview bringSubviewToFront:self];
        }
        self.alpha = 1.0;
    });
}

- (void)updateWithNativeFPS:(double)nativeFps
               syntheticFPS:(double)syntheticFps {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self show];
        
        MetalFGSynchronizer *sync = [MetalFGSynchronizer sharedSynchronizer];
        if (!sync.isEnabled) {
            // Frame Generation is toggled OFF
            self->_fpsLabel.text = [NSString stringWithFormat:@"⏸ FG: OFF (Native: %.0f)", nativeFps];
            self->_statusDot.backgroundColor = [UIColor colorWithRed:0.65 green:0.65 blue:0.65 alpha:1.0];
            self->_pillView.layer.borderColor = [UIColor colorWithRed:0.55 green:0.55 blue:0.55 alpha:0.7].CGColor;
            return;
        }
        
        double totalFps = nativeFps + syntheticFps;
        if (syntheticFps > 5.0) {
            // Frame generation is actively injecting frames
            self->_fpsLabel.text = [NSString stringWithFormat:@"⚡ FG: %.0f (%.0f+%.0f)", totalFps, nativeFps, syntheticFps];
            self->_statusDot.backgroundColor = [UIColor colorWithRed:0.20 green:0.85 blue:0.45 alpha:1.0];
            self->_pillView.layer.borderColor = [UIColor colorWithRed:0.20 green:0.85 blue:0.45 alpha:0.85].CGColor;
            
            // Pulse animation on status dot
            [UIView animateWithDuration:0.3 animations:^{
                self->_statusDot.transform = CGAffineTransformMakeScale(1.3, 1.3);
            } completion:^(BOOL finished) {
                [UIView animateWithDuration:0.3 animations:^{
                    self->_statusDot.transform = CGAffineTransformIdentity;
                }];
            }];
        } else if (nativeFps > 0.0) {
            // Only native frames rendered so far
            self->_fpsLabel.text = [NSString stringWithFormat:@"⚡ Native: %.0f FPS", nativeFps];
            self->_statusDot.backgroundColor = [UIColor colorWithRed:1.0 green:0.75 blue:0.15 alpha:1.0];
            self->_pillView.layer.borderColor = [UIColor colorWithRed:1.0 green:0.75 blue:0.15 alpha:0.7].CGColor;
        } else {
            // Synchronizer initialized, waiting for first 3D frame
            self->_fpsLabel.text = @"⚡ MetalFG: Active";
            self->_statusDot.backgroundColor = [UIColor colorWithRed:0.30 green:0.75 blue:1.0 alpha:1.0];
            self->_pillView.layer.borderColor = [UIColor colorWithRed:0.30 green:0.75 blue:1.0 alpha:0.7].CGColor;
        }
    });
}

@end

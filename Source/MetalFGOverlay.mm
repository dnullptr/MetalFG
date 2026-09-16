#import "../Headers/MetalFGOverlay.h"

@interface MetalFGOverlay () {
    UIView *_pillView;
    UIView *_statusDot;
    UILabel *_fpsLabel;
    BOOL _isMinimized;
    CGPoint _dragStartOffset;
}

@end

@implementation MetalFGOverlay

+ (instancetype)sharedOverlay {
    static MetalFGOverlay *sOverlay = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sOverlay = [[MetalFGOverlay alloc] initWithFrame:CGRectMake(20, 60, 200, 36)];
    });
    return sOverlay;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        self.layer.zPosition = 99999; // Always on top of game views
        _isMinimized = NO;
        
        // Background container pill
        _pillView = [[UIView alloc] initWithFrame:self.bounds];
        _pillView.backgroundColor = [UIColor colorWithRed:0.08 green:0.10 blue:0.12 alpha:0.85];
        _pillView.layer.cornerRadius = 18.0;
        _pillView.layer.masksToBounds = YES;
        _pillView.layer.borderWidth = 1.2;
        _pillView.layer.borderColor = [UIColor colorWithRed:0.20 green:0.85 blue:0.45 alpha:0.75].CGColor;
        [self addSubview:_pillView];
        
        // Pulsing status dot
        _statusDot = [[UIView alloc] initWithFrame:CGRectMake(10, 13, 10, 10)];
        _statusDot.backgroundColor = [UIColor colorWithRed:0.20 green:0.85 blue:0.45 alpha:1.0];
        _statusDot.layer.cornerRadius = 5.0;
        [_pillView addSubview:_statusDot];
        
        // FPS text label
        _fpsLabel = [[UILabel alloc] initWithFrame:CGRectMake(26, 0, 164, 36)];
        _fpsLabel.textColor = [UIColor whiteColor];
        _fpsLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.5 weight:UIFontWeightBold];
        _fpsLabel.text = @"⚡ MetalFG: 120 FPS";
        _fpsLabel.adjustsFontSizeToFitWidth = YES;
        [_pillView addSubview:_fpsLabel];
        
        // Gestures: Drag to move, Tap to toggle compact mode
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self selector:@selector(handlePan:)];
        [self addGestureRecognizer:pan];
        
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self selector:@selector(handleTap:)];
        [self addGestureRecognizer:tap];
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

- (void)handleTap:(UITapGestureRecognizer *)recognizer {
    _isMinimized = !_isMinimized;
    
    [UIView animateWithDuration:0.25 animations:^{
        if (self->_isMinimized) {
            self.bounds = CGRectMake(0, 0, 36, 36);
            self->_pillView.frame = self.bounds;
            self->_pillView.layer.cornerRadius = 18.0;
            self->_statusDot.center = CGPointMake(18, 18);
            self->_fpsLabel.alpha = 0.0;
        } else {
            self.bounds = CGRectMake(0, 0, 200, 36);
            self->_pillView.frame = self.bounds;
            self->_pillView.layer.cornerRadius = 18.0;
            self->_statusDot.frame = CGRectMake(10, 13, 10, 10);
            self->_fpsLabel.alpha = 1.0;
        }
    }];
}

- (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.superview) return;
        
        UIWindow *targetWindow = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (!w.isHidden && w.isKeyWindow) {
                targetWindow = w;
                break;
            }
        }
        if (!targetWindow) {
            targetWindow = [UIApplication sharedApplication].windows.firstObject;
        }
        
        if (targetWindow) {
            [targetWindow addSubview:self];
            self.alpha = 0.0;
            [UIView animateWithDuration:0.5 animations:^{
                self.alpha = 1.0;
            }];
        }
    });
}

- (void)updateWithNativeFPS:(double)nativeFps
               syntheticFPS:(double)syntheticFps {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self show];
        
        double totalFps = nativeFps + syntheticFps;
        if (syntheticFps > 5.0) {
            // Frame generation is actively injecting frames
            self->_fpsLabel.text = [NSString stringWithFormat:@"⚡ FG: %.0f (%.0f+%.0f)", totalFps, nativeFps, syntheticFps];
            self->_statusDot.backgroundColor = [UIColor colorWithRed:0.20 green:0.85 blue:0.45 alpha:1.0];
            self->_pillView.layer.borderColor = [UIColor colorWithRed:0.20 green:0.85 blue:0.45 alpha:0.8].CGColor;
            
            // Pulse animation on status dot
            [UIView animateWithDuration:0.3 animations:^{
                self->_statusDot.transform = CGAffineTransformMakeScale(1.3, 1.3);
            } completion:^(BOOL finished) {
                [UIView animateWithDuration:0.3 animations:^{
                    self->_statusDot.transform = CGAffineTransformIdentity;
                }];
            }];
        } else {
            // Only native frames
            self->_fpsLabel.text = [NSString stringWithFormat:@"⚡ Native: %.0f FPS", nativeFps];
            self->_statusDot.backgroundColor = [UIColor colorWithRed:1.0 green:0.75 blue:0.15 alpha:1.0];
            self->_pillView.layer.borderColor = [UIColor colorWithRed:1.0 green:0.75 blue:0.15 alpha:0.6].CGColor;
        }
    });
}

@end

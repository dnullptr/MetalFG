#import "../Headers/TouchTracker.h"
#import <os/lock.h>

@interface MetalFGTouchTracker () {
    os_unfair_lock _lock;
    CGPoint _lastFilteredVelocity; // Points per second
    CFTimeInterval _lastEventTime;
    BOOL _isDragging;
}

@end

@implementation MetalFGTouchTracker

+ (instancetype)sharedTracker {
    static MetalFGTouchTracker *sShared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sShared = [[MetalFGTouchTracker alloc] init];
    });
    return sShared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _lastFilteredVelocity = CGPointZero;
        _lastEventTime = CACurrentMediaTime();
        _isDragging = NO;
    }
    return self;
}

- (void)processTouchEvent:(UIEvent *)event {
    if (!event || event.type != UIEventTypeTouches) return;
    
    NSSet<UITouch *> *touches = [event allTouches];
    if (!touches || touches.count == 0) return;
    
    CFTimeInterval now = CACurrentMediaTime();
    
    os_unfair_lock_lock(&_lock);
    CFTimeInterval dt = now - _lastEventTime;
    if (dt <= 0.0001) dt = 0.001;
    _lastEventTime = now;
    
    UITouch *bestTouch = nil;
    CGFloat maxDisplacementSq = 0.0;
    BOOL anyMoved = NO;
    BOOL allEnded = YES;
    
    for (UITouch *touch in touches) {
        if (touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled) {
            allEnded = NO;
        }
        
        if (touch.phase == UITouchPhaseMoved) {
            anyMoved = YES;
            UIWindow *win = touch.window;
            if (!win) continue;
            
            CGPoint curr = [touch locationInView:win];
            CGPoint prev = [touch previousLocationInView:win];
            CGFloat dx = curr.x - prev.x;
            CGFloat dy = curr.y - prev.y;
            CGFloat dispSq = dx * dx + dy * dy;
            
            // Prefer touches on the right half of the screen (standard camera look in mobile 3D games)
            if (curr.x > win.bounds.size.width * 0.4) {
                dispSq *= 2.0;
            }
            
            if (dispSq > maxDisplacementSq) {
                maxDisplacementSq = dispSq;
                bestTouch = touch;
            }
        }
    }
    
    if (allEnded) {
        _lastFilteredVelocity = CGPointZero;
        _isDragging = NO;
        os_unfair_lock_unlock(&_lock);
        return;
    }
    
    if (anyMoved && bestTouch) {
        UIWindow *win = bestTouch.window;
        CGPoint curr = [bestTouch locationInView:win];
        CGPoint prev = [bestTouch previousLocationInView:win];
        
        CGPoint instantaneousVelocity = CGPointMake((curr.x - prev.x) / dt,
                                                    (curr.y - prev.y) / dt);
        
        // Clamp extreme spikes
        instantaneousVelocity.x = fmaxf(-4000.0, fminf(4000.0, instantaneousVelocity.x));
        instantaneousVelocity.y = fmaxf(-4000.0, fminf(4000.0, instantaneousVelocity.y));
        
        // Exponential Moving Average filter for smooth velocity
        const CGFloat alpha = 0.65;
        _lastFilteredVelocity.x = alpha * instantaneousVelocity.x + (1.0 - alpha) * _lastFilteredVelocity.x;
        _lastFilteredVelocity.y = alpha * instantaneousVelocity.y + (1.0 - alpha) * _lastFilteredVelocity.y;
        _isDragging = YES;
    } else {
        // Natural exponential decay when touch is held static without movement
        _lastFilteredVelocity.x *= 0.80;
        _lastFilteredVelocity.y *= 0.80;
        if (fabs(_lastFilteredVelocity.x) < 5.0 && fabs(_lastFilteredVelocity.y) < 5.0) {
            _lastFilteredVelocity = CGPointZero;
            _isDragging = NO;
        }
    }
    
    os_unfair_lock_unlock(&_lock);
}

- (simd_float2)normalizedVelocityForScreenSize:(CGSize)screenSize {
    if (screenSize.width <= 0.0 || screenSize.height <= 0.0) {
        return simd_make_float2(0.0f, 0.0f);
    }
    
    CFTimeInterval now = CACurrentMediaTime();
    
    os_unfair_lock_lock(&_lock);
    
    // Auto-decay if no events received in over 80ms
    CFTimeInterval timeSinceEvent = now - _lastEventTime;
    if (timeSinceEvent > 0.080) {
        _lastFilteredVelocity.x *= 0.50;
        _lastFilteredVelocity.y *= 0.50;
        if (timeSinceEvent > 0.150) {
            _lastFilteredVelocity = CGPointZero;
            _isDragging = NO;
        }
    }
    
    CGPoint vel = _lastFilteredVelocity;
    os_unfair_lock_unlock(&_lock);
    
    // Convert velocity (points/second) to normalized UV offset per native frame (~16.6ms at 60 FPS)
    const float dtFrame = 1.0f / 60.0f;
    float deltaU = (float)(vel.x * dtFrame / screenSize.width);
    float deltaV = (float)(vel.y * dtFrame / screenSize.height);
    
    // Clamp to reasonable maximum screen delta per frame (e.g. max 15% of screen per frame)
    deltaU = fmaxf(-0.15f, fminf(0.15f, deltaU));
    deltaV = fmaxf(-0.15f, fminf(0.15f, deltaV));
    
    return simd_make_float2(deltaU, deltaV);
}

- (void)reset {
    os_unfair_lock_lock(&_lock);
    _lastFilteredVelocity = CGPointZero;
    _lastEventTime = CACurrentMediaTime();
    _isDragging = NO;
    os_unfair_lock_unlock(&_lock);
}

@end


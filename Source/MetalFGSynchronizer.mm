#import "../Headers/MetalFGSynchronizer.h"
#import "../Headers/MetalFGOverlay.h"
#import <UIKit/UIKit.h>
#import <os/lock.h>

@interface MetalFGSynchronizer () {
    NSThread *_syncThread;
    CADisplayLink *_displayLink;
    BOOL _shouldStopThread;
    
    CFTimeInterval _lastNativeFrameTime;
    simd_quatf _lastNativeOrientation;
    os_unfair_lock _syncLock;
    
    // Performance statistics
    uint64_t _nativeFrameCount;
    uint64_t _syntheticFrameCount;
    CFTimeInterval _lastStatsLogTime;
    
    BOOL _isBackgrounded;
}

@end

@implementation MetalFGSynchronizer

+ (instancetype)sharedSynchronizer {
    static MetalFGSynchronizer *sShared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sShared = [[MetalFGSynchronizer alloc] init];
    });
    return sShared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isEnabled = YES;
        _fovYDegrees = 75.0f; // Typical standard field-of-view for 3D games
        _debugTint = NO;
        _syncLock = OS_UNFAIR_LOCK_INIT;
        _lastNativeFrameTime = 0.0;
        _lastNativeOrientation = simd_quaternion(0.0f, 0.0f, 0.0f, 1.0f);
        _motionTracker = [MetalFGMotionTracker sharedTracker];
        _shouldStopThread = NO;
        _isBackgrounded = NO;
        _nativeFrameCount = 0;
        _syntheticFrameCount = 0;
        _lastStatsLogTime = CACurrentMediaTime();
        
        // Listen to app lifecycle events to avoid GPU crashes in background
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleAppDidEnterBackground)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleAppDidBecomeActive)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleAppDidEnterBackground {
    os_unfair_lock_lock(&_syncLock);
    _isBackgrounded = YES;
    if (_displayLink) {
        _displayLink.paused = YES;
    }
    os_unfair_lock_unlock(&_syncLock);
    
    [_motionTracker stopTracking];
    NSLog(@"[MetalFG] Application entered background. Suspended frame synchronizer.");
}

- (void)handleAppDidBecomeActive {
    os_unfair_lock_lock(&_syncLock);
    _isBackgrounded = NO;
    if (_displayLink) {
        _displayLink.paused = NO;
    }
    _lastNativeFrameTime = CACurrentMediaTime();
    os_unfair_lock_unlock(&_syncLock);
    
    [_motionTracker startTracking];
    [[MetalFGOverlay sharedOverlay] show];
    NSLog(@"[MetalFG] Application became active. Resumed frame synchronizer.");
}

- (void)startSynchronizerWithLayer:(CAMetalLayer *)layer
                            device:(id<MTLDevice>)device
                       pixelFormat:(MTLPixelFormat)pixelFormat {
    os_unfair_lock_lock(&_syncLock);
    
    _activeLayer = layer;
    
    // Recreate warper if device or pixelFormat changed
    if (!_warper || _warper.device != device || _warper.pixelFormat != pixelFormat) {
        _warper = [[MetalFGWarper alloc] initWithDevice:device pixelFormat:pixelFormat];
        _warper.debugTintEnabled = _debugTint;
    }
    
    [_motionTracker startTracking];
    
    if (!_syncThread || !_syncThread.isExecuting) {
        _shouldStopThread = NO;
        _syncThread = [[NSThread alloc] initWithTarget:self selector:@selector(syncThreadEntryPoint) object:nil];
        _syncThread.name = @"com.metalfg.synchronizer";
        _syncThread.qualityOfService = NSQualityOfServiceUserInteractive;
        [_syncThread start];
    }
    
    os_unfair_lock_unlock(&_syncLock);
    
    // Show on-screen status overlay
    [[MetalFGOverlay sharedOverlay] show];
    NSLog(@"[MetalFG] Synchronizer started on dedicated 120Hz display link thread.");
}

- (void)stopSynchronizer {
    os_unfair_lock_lock(&_syncLock);
    _shouldStopThread = YES;
    [_displayLink invalidate];
    _displayLink = nil;
    os_unfair_lock_unlock(&_syncLock);
    
    [_motionTracker stopTracking];
    NSLog(@"[MetalFG] Synchronizer stopped.");
}

- (void)syncThreadEntryPoint {
    @autoreleasepool {
        NSRunLoop *currentRunLoop = [NSRunLoop currentRunLoop];
        
        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onDisplayTick:)];
        
        // Target 120Hz ProMotion display refresh rate on iOS 15+
        if (@available(iOS 15.0, *)) {
            _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(120.0f, 120.0f, 120.0f);
        }
        
        [_displayLink addToRunLoop:currentRunLoop forMode:NSRunLoopCommonModes];
        
        while (!_shouldStopThread) {
            @autoreleasepool {
                [currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.010]];
            }
        }
    }
}

- (void)notifyNativeFramePresented:(id<MTLTexture>)texture
                       atTimestamp:(CFTimeInterval)timestamp
                       orientation:(simd_quatf)orientation {
    if (!_isEnabled || _isBackgrounded) return;
    
    // Ignore small HUD textures (e.g. CAPerfHud / MetalHUD: typically < 250x150)
    if (texture.width < 250 || texture.height < 150) {
        return;
    }
    
    os_unfair_lock_lock(&_syncLock);
    _lastNativeFrameTime = timestamp;
    _lastNativeOrientation = orientation;
    _nativeFrameCount++;
    MetalFGWarper *currentWarper = _warper;
    os_unfair_lock_unlock(&_syncLock);
    
    // Copy the rendered game frame into double-buffered cache
    if (currentWarper && texture) {
        [currentWarper captureBaseTexture:texture withTimestamp:timestamp orientation:orientation];
    }
}

- (void)onDisplayTick:(CADisplayLink *)link {
    @autoreleasepool {
        if (!_isEnabled || _isBackgrounded) return;
        
        os_unfair_lock_lock(&_syncLock);
        CFTimeInterval lastNative = _lastNativeFrameTime;
        simd_quatf baseQuat = _lastNativeOrientation;
        CAMetalLayer *layer = _activeLayer;
        MetalFGWarper *warper = _warper;
        os_unfair_lock_unlock(&_syncLock);
        
        if (!layer || !warper || !warper.isReady) return;
        
        // Ignore HUD/sub-layers smaller than 250x150
        CGSize drawableSize = layer.drawableSize;
        if (drawableSize.width < 250.0 || drawableSize.height < 150.0) {
            return;
        }
        
        // Application state check
        if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
            return;
        }
        
        // Use consistent monotonic time for physical elapsed calculation
        CFTimeInterval now = CACurrentMediaTime();
        CFTimeInterval elapsedSinceNative = now - lastNative;
        
        // ATW Pacing Logic:
        // On 120Hz ProMotion: refresh interval = ~8.33ms (0.00833s).
        // Native 60 FPS interval = ~16.67ms (0.01667s).
        //
        // Case 1: Native frame presented very recently (< 4.5ms ago).
        // That native frame is occupying the current hardware refresh cycle. Skip synthetic injection.
        if (elapsedSinceNative < 0.0045) {
            return;
        }
        
        // Case 2: Native frame has not arrived in > 150ms (game paused, loading screen, or static menu).
        // Suspend synthetic generation to conserve GPU power and prevent thermal throttle.
        if (elapsedSinceNative > 0.150) {
            return;
        }
        
        // Case 3: GPU Backpressure guard:
        // If GPU is currently busy drawing previous synthetic frame, drop this tick immediately.
        if ([warper isGpuBusy]) {
            return;
        }
        
        // Case 4: Intermediate VSYNC tick! (e.g. 4.5ms - 15.0ms since last native frame)
        // Safely acquire next drawable (allowsNextDrawableTimeout prevents deadlock)
        id<CAMetalDrawable> syntheticDrawable = [layer nextDrawable];
        if (!syntheticDrawable || !syntheticDrawable.texture) {
            return;
        }
        
        // Sample predicted device orientation at the upcoming presentation timestamp
        CFTimeInterval targetPresentationTime = link.targetTimestamp;
        simd_quatf targetQuat = [_motionTracker orientationAtTimestamp:targetPresentationTime];
        
        // Determine screen aspect ratio
        float aspect = (drawableSize.height > 0.0f) ? (float)(drawableSize.width / drawableSize.height) : (16.0f / 9.0f);
        
        // Detect UI orientation (default landscape for games)
        UIInterfaceOrientation uiOrient = (drawableSize.width >= drawableSize.height) ?
                                          UIInterfaceOrientationLandscapeRight : UIInterfaceOrientationPortrait;
        
        // Compute rotational delta homography
        simd_float3x3 H = [_motionTracker computeHomographyFromBase:baseQuat
                                                           toTarget:targetQuat
                                                        fovYDegrees:_fovYDegrees
                                                        aspectRatio:aspect
                                                        orientation:uiOrient];
        simd_float3x3 invH = [_motionTracker invertMatrix3x3:H];
        
        // Render and present the warped synthetic frame
        BOOL rendered = [warper renderSyntheticFrameToDrawable:syntheticDrawable
                                              homographyMatrix:H
                                           invHomographyMatrix:invH
                                                targetTimeHint:targetPresentationTime];
        
        if (rendered) {
            _syntheticFrameCount++;
        }
        
        // Periodic FPS logging & On-Screen Overlay update (every 1.0s)
        CFTimeInterval statsNow = CACurrentMediaTime();
        if (statsNow - _lastStatsLogTime >= 1.0) {
            double duration = statsNow - _lastStatsLogTime;
            double nativeFps = (double)_nativeFrameCount / duration;
            double syntheticFps = (double)_syntheticFrameCount / duration;
            
            // Update floating on-screen indicator
            [[MetalFGOverlay sharedOverlay] updateWithNativeFPS:nativeFps syntheticFPS:syntheticFps];
            
            NSLog(@"[MetalFG] Performance: Native: %.1f FPS | Synthetic: %.1f FPS | Total: %.1f FPS",
                  nativeFps, syntheticFps, nativeFps + syntheticFps);
            
            _nativeFrameCount = 0;
            _syntheticFrameCount = 0;
            _lastStatsLogTime = statsNow;
        }
    }
}

@end

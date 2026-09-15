#import "../Headers/MetalFGSynchronizer.h"
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
        _nativeFrameCount = 0;
        _syntheticFrameCount = 0;
        _lastStatsLogTime = CACurrentMediaTime();
    }
    return self;
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
    if (!_isEnabled) return;
    
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
    if (!_isEnabled) return;
    
    os_unfair_lock_lock(&_syncLock);
    CFTimeInterval lastNative = _lastNativeFrameTime;
    simd_quatf baseQuat = _lastNativeOrientation;
    CAMetalLayer *layer = _activeLayer;
    MetalFGWarper *warper = _warper;
    os_unfair_lock_unlock(&_syncLock);
    
    if (!layer || !warper || !warper.isReady) return;
    
    CFTimeInterval now = link.timestamp;
    CFTimeInterval elapsedSinceNative = now - lastNative;
    
    // ATW Scheduling Logic:
    // Display refresh interval at 120Hz = ~8.33ms (0.00833s).
    // Native 60 FPS frame interval = ~16.67ms (0.01667s).
    //
    // Case 1: Native frame presented recently (< 5.5ms ago).
    // -> That native frame is currently taking this display cycle. Do NOT generate synthetic frame.
    if (elapsedSinceNative < 0.0055) {
        return;
    }
    
    // Case 2: Native frame has not arrived in > 100ms (game paused, backgrounded, or static scene).
    // -> Suspend synthetic generation to conserve battery and GPU power.
    if (elapsedSinceNative > 0.100) {
        return;
    }
    
    // Case 3: GPU Backpressure guard:
    // If the GPU is saturated or previous synthetic frames are still queued, drop this frame.
    if ([warper isGpuBusy]) {
        return;
    }
    
    // Case 4: Intermediate VSYNC tick! (e.g. 5.5ms - 15.0ms since last native frame)
    // Acquire an extra drawable for synthetic injection
    id<CAMetalDrawable> syntheticDrawable = [layer nextDrawable];
    if (!syntheticDrawable) {
        // Swapchain full or acquisition throttled; drop synthetic frame safely
        return;
    }
    
    // Sample predicted device orientation at the exact upcoming display presentation timestamp
    CFTimeInterval targetPresentationTime = link.targetTimestamp;
    simd_quatf targetQuat = [_motionTracker orientationAtTimestamp:targetPresentationTime];
    
    // Determine screen aspect ratio and orientation
    CGSize drawableSize = layer.drawableSize;
    float aspect = (drawableSize.height > 0.0f) ? (float)(drawableSize.width / drawableSize.height) : (16.0f / 9.0f);
    
    // Detect UI orientation (default landscape if game width > height)
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
    
    // Periodic FPS logging
    CFTimeInterval statsNow = CACurrentMediaTime();
    if (statsNow - _lastStatsLogTime >= 3.0) {
        double duration = statsNow - _lastStatsLogTime;
        double nativeFps = (double)_nativeFrameCount / duration;
        double syntheticFps = (double)_syntheticFrameCount / duration;
        NSLog(@"[MetalFG] Performance: Native: %.1f FPS | Synthetic: %.1f FPS | Total: %.1f FPS",
              nativeFps, syntheticFps, nativeFps + syntheticFps);
        _nativeFrameCount = 0;
        _syntheticFrameCount = 0;
        _lastStatsLogTime = statsNow;
    }
}

@end

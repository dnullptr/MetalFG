#import "../Headers/MetalFGSynchronizer.h"
#import "../Headers/MetalFGOverlay.h"
#import "../Headers/TouchTracker.h"
#import <UIKit/UIKit.h>
#import <os/lock.h>

@interface MetalFGSynchronizer () {
    NSThread *_syncThread;
    CADisplayLink *_displayLink;
    BOOL _shouldStopThread;
    
    CFTimeInterval _lastNativeFrameTime;
    os_unfair_lock _syncLock;
    
    // Performance statistics
    uint64_t _nativeFrameCount;
    uint64_t _syntheticFrameCount;
    CFTimeInterval _lastStatsLogTime;
    
    BOOL _isBackgrounded;
    BOOL _hasInjectedForCurrentNativeFrame;
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
        _debugTint = NO;
        _syncLock = OS_UNFAIR_LOCK_INIT;
        _lastNativeFrameTime = 0.0;
        _shouldStopThread = NO;
        _isBackgrounded = NO;
        _hasInjectedForCurrentNativeFrame = NO;
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
    
    [[MetalFGTouchTracker sharedTracker] reset];
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
    
    [[MetalFGTouchTracker sharedTracker] reset];
    NSLog(@"[MetalFG] Synchronizer stopped.");
}

- (void)syncThreadEntryPoint {
    @autoreleasepool {
        NSRunLoop *currentRunLoop = [NSRunLoop currentRunLoop];
        
        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onDisplayTick:)];
        
        // Target 120Hz ProMotion display refresh rate on iOS 15+
        if (@available(iOS 15.0, *)) {
            _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(60.0f, 120.0f, 120.0f);
        }
        _displayLink.preferredFramesPerSecond = 120;
        
        [_displayLink addToRunLoop:currentRunLoop forMode:NSRunLoopCommonModes];
        
        while (!_shouldStopThread) {
            @autoreleasepool {
                [currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
            }
        }
    }
}

- (void)notifyNativeFramePresented:(id<MTLTexture>)texture
                       atTimestamp:(CFTimeInterval)timestamp
                       orientation:(simd_quatf)orientation {
    if (_isBackgrounded) return;
    
    // Ignore small HUD textures (e.g. CAPerfHud / MetalHUD: typically < 250x150)
    if (texture.width < 250 || texture.height < 150) {
        return;
    }
    
    os_unfair_lock_lock(&_syncLock);
    _lastNativeFrameTime = timestamp;
    _nativeFrameCount++;
    _hasInjectedForCurrentNativeFrame = NO;
    MetalFGWarper *currentWarper = _warper;
    BOOL enabled = _isEnabled;
    os_unfair_lock_unlock(&_syncLock);
    
    // Sample latest touch camera velocity prior
    simd_float2 touchVel = [[MetalFGTouchTracker sharedTracker] normalizedVelocityForScreenSize:CGSizeMake(texture.width, texture.height)];
    
    // Copy the rendered game frame into double-buffered cache and dispatch BME
    if (enabled && currentWarper && texture) {
        [currentWarper captureBaseTexture:texture withTimestamp:timestamp touchVelocity:touchVel];
    }
}

- (void)onDisplayTick:(CADisplayLink *)link {
    @autoreleasepool {
        if (_isBackgrounded) return;
        
        // Periodic FPS logging & On-Screen Overlay update (every 1.0s, evaluated on every tick)
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
        
        // If Frame Generation toggle is OFF, skip synthetic frame injection completely
        if (!_isEnabled) {
            return;
        }
        
        os_unfair_lock_lock(&_syncLock);
        CFTimeInterval lastNative = _lastNativeFrameTime;
        BOOL alreadyInjected = _hasInjectedForCurrentNativeFrame;
        CAMetalLayer *layer = _activeLayer;
        MetalFGWarper *warper = _warper;
        os_unfair_lock_unlock(&_syncLock);
        
        if (!layer || !warper || !warper.isReady) return;
        
        // STRICT 1:1 FRAME PACING:
        // Enforce exactly 1 synthetic frame per native frame.
        if (alreadyInjected) {
            return;
        }
        
        // Ignore HUD/sub-layers smaller than 250x150
        CGSize drawableSize = layer.drawableSize;
        if (drawableSize.width < 250.0 || drawableSize.height < 150.0) {
            return;
        }
        
        // Idle guard: if no native frame has arrived in > 150ms (game paused, loading screen, or static menu)
        CFTimeInterval now = CACurrentMediaTime();
        if (now - lastNative > 0.150) {
            return;
        }
        
        // GPU Backpressure guard:
        if ([warper isGpuBusy]) {
            return;
        }
        
        // Case 4: Intermediate VSYNC tick! (e.g. 4.0ms - 15.0ms since last native frame)
        id<CAMetalDrawable> syntheticDrawable = [layer nextDrawable];
        if (!syntheticDrawable || !syntheticDrawable.texture) {
            return;
        }
        
        // Sample predicted presentation timestamp
        CFTimeInterval targetPresentationTime = link.targetTimestamp;
        
        // Render and present the motion-interpolated synthetic frame
        BOOL rendered = [warper renderSyntheticFrameToDrawable:syntheticDrawable
                                                targetTimeHint:targetPresentationTime];
        
        if (rendered) {
            _syntheticFrameCount++;
            os_unfair_lock_lock(&_syncLock);
            _hasInjectedForCurrentNativeFrame = YES;
            os_unfair_lock_unlock(&_syncLock);
        }
    }
}

@end

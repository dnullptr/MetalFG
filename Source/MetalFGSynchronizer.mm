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

static NSString * const kRootlessPrefsPath = @"/var/jb/var/mobile/Library/Preferences/com.dnullptr.metalfg.plist";
static NSString * const kStandardPrefsPath = @"/var/mobile/Library/Preferences/com.dnullptr.metalfg.plist";

- (NSString *)preferencesFilePath {
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"]) {
        return kRootlessPrefsPath;
    }
    return kStandardPrefsPath;
}

- (void)loadPreferences {
    NSString *path = [self preferencesFilePath];
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
    if (dict) {
        if (dict[@"isEnabled"] != nil) {
            _isEnabled = [dict[@"isEnabled"] boolValue];
        } else {
            _isEnabled = YES;
        }
        if (dict[@"currentPreset"] != nil) {
            _currentPreset = [dict[@"currentPreset"] integerValue];
        } else {
            _currentPreset = 1; // Balanced
        }
        if (dict[@"motionScale"] != nil) {
            _motionScale = [dict[@"motionScale"] floatValue];
        } else {
            _motionScale = 0.50f;
        }
        if (dict[@"disocclusionThreshold"] != nil) {
            _disocclusionThreshold = [dict[@"disocclusionThreshold"] floatValue];
        } else {
            _disocclusionThreshold = 0.22f;
        }
        if (dict[@"uiSensitivity"] != nil) {
            _uiSensitivity = [dict[@"uiSensitivity"] floatValue];
        } else {
            _uiSensitivity = 0.035f;
        }
    } else {
        _isEnabled = YES;
        _currentPreset = 1;
        _motionScale = 0.50f;
        _disocclusionThreshold = 0.22f;
        _uiSensitivity = 0.035f;
    }
}

- (void)savePreferences {
    NSString *path = [self preferencesFilePath];
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"isEnabled"] = @(_isEnabled);
    dict[@"currentPreset"] = @(_currentPreset);
    dict[@"motionScale"] = @(_motionScale);
    dict[@"disocclusionThreshold"] = @(_disocclusionThreshold);
    dict[@"uiSensitivity"] = @(_uiSensitivity);
    [dict writeToFile:path atomically:YES];
}

- (void)applyPreset:(NSInteger)presetIndex {
    _currentPreset = presetIndex;
    switch (presetIndex) {
        case 0: // Clear (anti-ghosting focus)
            self.motionScale = 0.35f;
            self.disocclusionThreshold = 0.16f;
            self.uiSensitivity = 0.040f;
            break;
        case 1: // Balanced (default sweet spot)
            self.motionScale = 0.50f;
            self.disocclusionThreshold = 0.22f;
            self.uiSensitivity = 0.035f;
            break;
        case 2: // Fluid (maximum motion)
            self.motionScale = 0.50f;
            self.disocclusionThreshold = 0.28f;
            self.uiSensitivity = 0.025f;
            break;
        default:
            break;
    }
    [self savePreferences];
}

- (void)setMotionScale:(float)motionScale {
    _motionScale = motionScale;
    os_unfair_lock_lock(&_syncLock);
    if (_warper) {
        _warper.motionScale = motionScale;
    }
    os_unfair_lock_unlock(&_syncLock);
}

- (void)setDisocclusionThreshold:(float)disocclusionThreshold {
    _disocclusionThreshold = disocclusionThreshold;
    os_unfair_lock_lock(&_syncLock);
    if (_warper) {
        _warper.disocclusionThreshold = disocclusionThreshold;
    }
    os_unfair_lock_unlock(&_syncLock);
}

- (void)setUiSensitivity:(float)uiSensitivity {
    _uiSensitivity = uiSensitivity;
    os_unfair_lock_lock(&_syncLock);
    if (_warper) {
        _warper.uiSensitivity = uiSensitivity;
    }
    os_unfair_lock_unlock(&_syncLock);
}

- (void)setIsEnabled:(BOOL)isEnabled {
    _isEnabled = isEnabled;
    [self savePreferences];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _syncLock = OS_UNFAIR_LOCK_INIT;
        _lastNativeFrameTime = 0.0;
        _shouldStopThread = NO;
        _isBackgrounded = NO;
        _hasInjectedForCurrentNativeFrame = NO;
        _nativeFrameCount = 0;
        _syntheticFrameCount = 0;
        _lastStatsLogTime = CACurrentMediaTime();
        _debugTint = NO;
        
        [self loadPreferences];
        
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
        _warper.motionScale = _motionScale;
        _warper.disocclusionThreshold = _disocclusionThreshold;
        _warper.uiSensitivity = _uiSensitivity;
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
                             layer:(nullable CAMetalLayer *)layer
                       atTimestamp:(CFTimeInterval)timestamp {
    if (_isBackgrounded || !texture) return;
    
    // Ignore small HUD textures (e.g. CAPerfHud / MetalHUD: typically < 250x150)
    if (texture.width < 250 || texture.height < 150) {
        return;
    }
    
    os_unfair_lock_lock(&_syncLock);
    _lastNativeFrameTime = timestamp;
    _nativeFrameCount++;
    _hasInjectedForCurrentNativeFrame = NO;
    if (layer && layer != _activeLayer) {
        _activeLayer = layer;
    }
    MetalFGWarper *currentWarper = _warper;
    BOOL enabled = _isEnabled;
    os_unfair_lock_unlock(&_syncLock);
    
    if (enabled && currentWarper) {
        simd_float2 touchVel = [[MetalFGTouchTracker sharedTracker] normalizedVelocityForScreenSize:CGSizeMake(texture.width, texture.height)];
        [currentWarper captureBaseTexture:texture withTimestamp:timestamp touchVelocity:touchVel];
    }
}

- (void)notifyNativeFramePresented:(id<MTLTexture>)texture
                       atTimestamp:(CFTimeInterval)timestamp
                       orientation:(simd_quatf)orientation {
    [self notifyNativeFramePresented:texture layer:_activeLayer atTimestamp:timestamp];
}

- (void)onDisplayTick:(CADisplayLink *)link {
    @autoreleasepool {
        if (_isBackgrounded) return;
        
        // Periodic FPS logging & On-Screen Overlay update (every 1.0s, evaluated on display link tick)
        CFTimeInterval statsNow = CACurrentMediaTime();
        if (statsNow - _lastStatsLogTime >= 1.0) {
            double duration = statsNow - _lastStatsLogTime;
            
            os_unfair_lock_lock(&_syncLock);
            double nativeFps = (double)_nativeFrameCount / duration;
            double syntheticFps = (double)_syntheticFrameCount / duration;
            _nativeFrameCount = 0;
            _syntheticFrameCount = 0;
            _lastStatsLogTime = statsNow;
            os_unfair_lock_unlock(&_syncLock);
            
            // Update floating on-screen indicator
            [[MetalFGOverlay sharedOverlay] updateWithNativeFPS:nativeFps syntheticFPS:syntheticFps];
            
            NSLog(@"[MetalFG] Performance: Native: %.1f FPS | Synthetic: %.1f FPS | Total: %.1f FPS",
                  nativeFps, syntheticFps, nativeFps + syntheticFps);
        }
        
        if (!_isEnabled) return;
        
        os_unfair_lock_lock(&_syncLock);
        CFTimeInterval lastNative = _lastNativeFrameTime;
        BOOL alreadyInjected = _hasInjectedForCurrentNativeFrame;
        CAMetalLayer *layer = _activeLayer;
        MetalFGWarper *warper = _warper;
        os_unfair_lock_unlock(&_syncLock);
        
        if (!layer || !warper || !warper.isReady) return;
        
        // STRICT 1:1 FRAME PACING:
        // Enforce exactly 1 synthetic frame per native frame.
        if (alreadyInjected) return;
        
        // Ignore HUD/sub-layers smaller than 250x150
        CGSize drawableSize = layer.drawableSize;
        if (drawableSize.width < 250.0 || drawableSize.height < 150.0) return;
        
        CFTimeInterval now = CACurrentMediaTime();
        CFTimeInterval elapsed = now - lastNative;
        
        // Idle guard: if no native frame has arrived in > 150ms (paused, loading, static UI)
        if (elapsed > 0.150) {
            return;
        }
        
        // Backpressure guard
        if ([warper isGpuBusy]) return;
        
        id<CAMetalDrawable> syntheticDrawable = [layer nextDrawable];
        if (!syntheticDrawable || !syntheticDrawable.texture) return;
        
        CFTimeInterval targetPresentationTime = link.targetTimestamp;
        BOOL rendered = [warper renderSyntheticFrameToDrawable:syntheticDrawable
                                                targetTimeHint:targetPresentationTime];
        if (rendered) {
            os_unfair_lock_lock(&_syncLock);
            _syntheticFrameCount++;
            _hasInjectedForCurrentNativeFrame = YES;
            os_unfair_lock_unlock(&_syncLock);
        }
    }
}

@end

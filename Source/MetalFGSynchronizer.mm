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
    CFTimeInterval _smoothedNativeInterval;
    
    // Serial queue that presents Ground Truth Frame N right behind S_{N-0.5}
    dispatch_queue_t _presentQueue;
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
static NSString * const kCurrentPrefsSchema = @"2.3.0";

- (NSString *)preferencesFilePath {
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"]) {
        return kRootlessPrefsPath;
    }
    return kStandardPrefsPath;
}

- (void)loadPreferences {
    NSString *path = [self preferencesFilePath];
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
    NSString *savedSchema = dict ? dict[@"prefsVersion"] : nil;
    
    if (dict && [savedSchema isEqualToString:kCurrentPrefsSchema]) {
        _isEnabled = (dict[@"isEnabled"] != nil) ? [dict[@"isEnabled"] boolValue] : YES;
        _currentPreset = (dict[@"currentPreset"] != nil) ? [dict[@"currentPreset"] integerValue] : 1;
        _motionScale = (dict[@"motionScale"] != nil) ? [dict[@"motionScale"] floatValue] : 0.50f;
        _disocclusionThreshold = (dict[@"disocclusionThreshold"] != nil) ? [dict[@"disocclusionThreshold"] floatValue] : 0.18f;
        _uiSensitivity = (dict[@"uiSensitivity"] != nil) ? [dict[@"uiSensitivity"] floatValue] : 0.035f;
        _motionDeadzone = (dict[@"motionDeadzone"] != nil) ? [dict[@"motionDeadzone"] floatValue] : 0.0003f;
        _debugTint = (dict[@"debugTint"] != nil) ? [dict[@"debugTint"] boolValue] : NO;
    } else {
        // Initialize clean v2.3.0 defaults (True 50% Midpoint Interpolation)
        _isEnabled = (dict && dict[@"isEnabled"] != nil) ? [dict[@"isEnabled"] boolValue] : YES;
        _currentPreset = 1; // Balanced (True 50% Midpoint)
        _motionScale = 0.50f;
        _disocclusionThreshold = 0.18f;
        _uiSensitivity = 0.035f;
        _motionDeadzone = 0.0003f;
        _debugTint = (dict && dict[@"debugTint"] != nil) ? [dict[@"debugTint"] boolValue] : NO;
        [self savePreferences];
    }
}

- (void)savePreferences {
    NSString *path = [self preferencesFilePath];
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"prefsVersion"] = kCurrentPrefsSchema;
    dict[@"isEnabled"] = @(_isEnabled);
    dict[@"currentPreset"] = @(_currentPreset);
    dict[@"motionScale"] = @(_motionScale);
    dict[@"disocclusionThreshold"] = @(_disocclusionThreshold);
    dict[@"uiSensitivity"] = @(_uiSensitivity);
    dict[@"motionDeadzone"] = @(_motionDeadzone);
    dict[@"debugTint"] = @(_debugTint);
    [dict writeToFile:path atomically:YES];
}

- (void)applyPreset:(NSInteger)presetIndex {
    _currentPreset = presetIndex;
    switch (presetIndex) {
        case 0: // Crisp (True 50% Midpoint + tight disocclusion cutoff for zero ghosting)
            self.motionScale = 0.50f;
            self.disocclusionThreshold = 0.14f;
            self.uiSensitivity = 0.038f;
            self.motionDeadzone = 0.0004f;
            break;
        case 1: // Balanced (True 50% Midpoint + SMFG Round 53 head/silhouette occlusion guard)
            self.motionScale = 0.50f;
            self.disocclusionThreshold = 0.18f;
            self.uiSensitivity = 0.035f;
            self.motionDeadzone = 0.0003f;
            break;
        case 2: // Ultra Smooth (True 50% Midpoint + wide bilateral fluid blend)
            self.motionScale = 0.50f;
            self.disocclusionThreshold = 0.24f;
            self.uiSensitivity = 0.028f;
            self.motionDeadzone = 0.0002f;
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

- (void)setMotionDeadzone:(float)motionDeadzone {
    _motionDeadzone = motionDeadzone;
    os_unfair_lock_lock(&_syncLock);
    if (_warper) {
        _warper.motionDeadzone = motionDeadzone;
    }
    os_unfair_lock_unlock(&_syncLock);
}

- (void)setDebugTint:(BOOL)debugTint {
    _debugTint = debugTint;
    os_unfair_lock_lock(&_syncLock);
    if (_warper) {
        _warper.debugTintEnabled = debugTint;
    }
    os_unfair_lock_unlock(&_syncLock);
    [self savePreferences];
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
        _presentQueue = dispatch_queue_create("com.metalfg.nativePresent",
                                              dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        _smoothedNativeInterval = 1.0 / 60.0;
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
        _warper.motionDeadzone = _motionDeadzone;
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

- (void)notifyNativeFrameRendered:(id<CAMetalDrawable>)drawable {
    if (_isBackgrounded || !drawable) return;
    
    id<MTLTexture> texture = drawable.texture;
    if (!texture || texture.width < 250 || texture.height < 150) {
        return;
    }
    
    CFTimeInterval now = CACurrentMediaTime();
    
    os_unfair_lock_lock(&_syncLock);
    CFTimeInterval interval = now - _lastNativeFrameTime;
    BOOL isMajorStall = (interval > 0.125); // Only reset across true >125ms pauses/loading hitches
    if (interval > 0.005 && interval < 0.200) {
        CFTimeInterval irregularThreshold = MAX(2.5 * _smoothedNativeInterval, _smoothedNativeInterval + 0.025);
        if (_smoothedNativeInterval > 0.005 && interval > irregularThreshold) {
            // SMFG 1.3: Update EMA slowly on hitches/stutters (lf_fg_pace.inl)
            _smoothedNativeInterval = _smoothedNativeInterval * 0.96 + interval * 0.04;
        } else {
            _smoothedNativeInterval = _smoothedNativeInterval * 0.85 + interval * 0.15;
        }
    }
    _lastNativeFrameTime = now;
    _nativeFrameCount++;
    if (drawable.layer && drawable.layer != _activeLayer) {
        _activeLayer = drawable.layer;
    }
    MetalFGWarper *currentWarper = _warper;
    BOOL enabled = _isEnabled;
    os_unfair_lock_unlock(&_syncLock);
    
    if (enabled && currentWarper) {
        // SMFG 1.3 Major Stall Guard: Reset frame history only across true >125ms pauses/scene cuts
        // so normal 25-60 FPS gameplay never drops a single synthetic frame
        if (isMajorStall) {
            [currentWarper resetFrameHistory];
        }
        // Option 3: Full 1-Frame Latency True Interpolation Model (LSFG / DLSS 3)
        // 1. Warper saves Ground Truth Frame N into double-buffered cache.
        // 2. Warper computes coarse-to-fine motion field between Frame N-1 and Frame N.
        // 3. Warper synthesizes S_{N-0.5} into the native drawable and presents it with
        //    afterMinimumDuration:(1/120 - 0.0005).
        // 4. Ground Truth Frame N is presented immediately afterwards (no display-link polling);
        //    afterMinimumDuration keeps S_{N-0.5} on screen for a full 120Hz refresh first.
        uint64_t frameSerial = 0;
        BOOL didInterpolate = [currentWarper processAndInterpolateNativeDrawable:drawable frameSerial:&frameSerial];
        
        if (didInterpolate) {
            os_unfair_lock_lock(&_syncLock);
            _syntheticFrameCount++;
            os_unfair_lock_unlock(&_syncLock);
            
            dispatch_async(_presentQueue, ^{
                [self presentNativeFrameWithSerial:frameSerial warper:currentWarper];
            });
        }
    }
}

- (void)presentNativeFrameWithSerial:(uint64_t)serial warper:(MetalFGWarper *)warper {
    // nextDrawable returns an autoreleased drawable. GCD drains its pools at undefined times,
    // so without a local pool the drawable is never returned to the layer's 3-slot swapchain
    // and the game's own nextDrawable starves (1s allowsNextDrawableTimeout hangs).
    @autoreleasepool {
        if (_isBackgrounded || !_isEnabled) return;
        
        os_unfair_lock_lock(&_syncLock);
        CAMetalLayer *layer = _activeLayer;
        os_unfair_lock_unlock(&_syncLock);
        if (!layer) return;
        
        CGSize drawableSize = layer.drawableSize;
        if (drawableSize.width < 250.0 || drawableSize.height < 150.0) return;
        
        id<CAMetalDrawable> nativeDrawable = [layer nextDrawable];
        if (!nativeDrawable || !nativeDrawable.texture) return;
        
        // Returns NO if S_{N+0.5} was already committed while we waited for a drawable;
        // showing Frame N after it would step backwards, so it is skipped instead.
        [warper presentCachedNativeFrameWithSerial:serial toDrawable:nativeDrawable];
    }
}

- (void)notifyNativeFramePresented:(id<MTLTexture>)texture
                             layer:(nullable CAMetalLayer *)layer
                       atTimestamp:(CFTimeInterval)timestamp {
    if (_isBackgrounded || !texture) return;
    
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
        // Ground Truth Frame N is now presented from _presentQueue right after S_{N-0.5};
        // this tick only drives stats and keeps the 120Hz ProMotion range requested.
    }
}

@end

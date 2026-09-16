#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <stdlib.h>

#import "../Headers/ShaderTypes.h"
#import "../Headers/CoreMotionTracker.h"
#import "../Headers/MetalFGWarper.h"
#import "../Headers/MetalFGSynchronizer.h"
#import "../Headers/MetalFGOverlay.h"

// Minimum dimension threshold to filter out tiny HUDs/overlays (e.g. MetalHUD, CAPerfHud)
static const CGFloat kMinHUDDimension = 200.0;

// Global reference to the active game layer
static __weak CAMetalLayer *gActiveMetalLayer = nil;

// Helper: Determine if a layer is a candidate for the primary game rendering layer
static inline BOOL IsGameLayerCandidate(CAMetalLayer *layer) {
    if (!layer) return NO;
    
    // Ignore layers with names or classes indicating HUD/debug/metrics
    NSString *className = NSStringFromClass([layer class]);
    if ([className containsString:@"HUD"] ||
        [className containsString:@"Perf"] ||
        [className containsString:@"Debug"] ||
        [className containsString:@"Overlay"]) {
        return NO;
    }
    
    // If size is set, check that it's larger than tiny HUD overlays
    CGSize drawableSize = layer.drawableSize;
    if (drawableSize.width > 0 && drawableSize.height > 0) {
        if (drawableSize.width < 250.0 || drawableSize.height < 150.0) {
            return NO;
        }
    }
    
    return YES;
}

// ============================================================================
// Hook: Unlock 120Hz ProMotion on iOS 16 Devices
// ============================================================================
%hook UIScreen

- (NSInteger)maximumFramesPerSecond {
    return 120;
}

%end

// ============================================================================
// Hook: NSBundle to enable ProMotion 120Hz for any game
// (Bypasses iOS 16 ProMotion 60Hz throttle on games lacking this plist key)
// ============================================================================
%hook NSBundle

- (id)objectForInfoDictionaryKey:(NSString *)key {
    if ([key isEqualToString:@"CADisableMinimumFrameDurationOnPhone"]) {
        return @YES;
    }
    return %orig;
}

- (NSDictionary *)infoDictionary {
    NSDictionary *orig = %orig;
    if (orig && !orig[@"CADisableMinimumFrameDurationOnPhone"]) {
        NSMutableDictionary *dict = [orig mutableCopy];
        dict[@"CADisableMinimumFrameDurationOnPhone"] = @YES;
        return dict;
    }
    return orig;
}

%end

// ============================================================================
// Hook: CAMetalLayer Lifecycle & Swapchain Headroom
// ============================================================================
%hook CAMetalLayer

- (void)setDevice:(id<MTLDevice>)device {
    %orig(device);
    
    if (IsGameLayerCandidate(self)) {
        self.maximumDrawableCount = 3;
        if (@available(iOS 16.0, *)) {
            // Avoid driver deadlocks when GPU queue backpressure is high
            self.allowsNextDrawableTimeout = YES;
        }
        gActiveMetalLayer = self;
        [[MetalFGSynchronizer sharedSynchronizer] startSynchronizerWithLayer:self
                                                                    device:device
                                                               pixelFormat:self.pixelFormat];
    }
}

- (id<CAMetalDrawable>)nextDrawable {
    if (IsGameLayerCandidate(self)) {
        if (self.maximumDrawableCount < 3) {
            self.maximumDrawableCount = 3;
        }
        if (@available(iOS 16.0, *)) {
            self.allowsNextDrawableTimeout = YES;
        }
        
        gActiveMetalLayer = self;
        
        if ([MetalFGSynchronizer sharedSynchronizer].activeLayer != self) {
            [[MetalFGSynchronizer sharedSynchronizer] startSynchronizerWithLayer:self
                                                                        device:self.device
                                                                   pixelFormat:self.pixelFormat];
        }
    }
    return %orig;
}

%end

// ============================================================================
// Hook: CADisplayLink to unlock 120Hz refresh rates in games
// ============================================================================
%hook CADisplayLink

- (void)setPreferredFramesPerSecond:(NSInteger)fps {
    %orig(120);
}

- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    range.minimum = 60.0f;
    range.preferred = 120.0f;
    range.maximum = 120.0f;
    %orig(range);
}

- (void)setFrameInterval:(NSInteger)interval {
    %orig(1);
    if ([self respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
        self.preferredFramesPerSecond = 120;
    }
}

%end

// ============================================================================
// Helper: Process Native Frame Presentation
// ============================================================================
static char kMetalFGProcessedKey;

static inline void ProcessNativePresentation(id<CAMetalDrawable> drawable) {
    if (!drawable) return;
    
    // 1. Recursion guard: ignore our own synthetic warp frames
    NSNumber *isSynthetic = objc_getAssociatedObject(drawable, &kMetalFGIsSyntheticKey);
    if (isSynthetic && [isSynthetic boolValue]) {
        return;
    }
    
    // 2. Deduplication guard: do not process the same drawable twice in one frame
    if (objc_getAssociatedObject(drawable, &kMetalFGProcessedKey)) {
        return;
    }
    objc_setAssociatedObject(drawable, &kMetalFGProcessedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    id<MTLTexture> texture = drawable.texture;
    if (!texture) return;
    
    // 3. HUD / Overlay guard: ignore small textures (e.g. CAPerfHud / MetalHUD)
    if (texture.width < 250 || texture.height < 150) {
        return;
    }
    
    // 4. Bind active layer if not already bound
    CAMetalLayer *activeLayer = [MetalFGSynchronizer sharedSynchronizer].activeLayer;
    if (!activeLayer && drawable.layer) {
        activeLayer = drawable.layer;
        [[MetalFGSynchronizer sharedSynchronizer] startSynchronizerWithLayer:activeLayer
                                                                    device:activeLayer.device
                                                                pixelFormat:activeLayer.pixelFormat];
    }
    
    // 5. If layer is set, ensure this drawable belongs to the game layer
    if (activeLayer && drawable.layer && drawable.layer != activeLayer) {
        return;
    }
    
    CFTimeInterval now = CACurrentMediaTime();
    simd_quatf orientation = [[MetalFGMotionTracker sharedTracker] orientationAtTimestamp:now];
    
    [[MetalFGSynchronizer sharedSynchronizer] notifyNativeFramePresented:texture
                                                            atTimestamp:now
                                                            orientation:orientation];
}

// ============================================================================
// Hook: CAMetalDrawable Direct Presentations
// ============================================================================
%hook CAMetalDrawable

- (void)present {
    id<CAMetalDrawable> metalDrawable = (id<CAMetalDrawable>)self;
    if ([metalDrawable respondsToSelector:@selector(addPresentedHandler:)]) {
        [metalDrawable addPresentedHandler:^(id<MTLDrawable> d) {
            ProcessNativePresentation(metalDrawable);
        }];
    } else {
        ProcessNativePresentation(metalDrawable);
    }
    %orig;
}

- (void)presentAtTime:(CFTimeInterval)presentationTime {
    id<CAMetalDrawable> metalDrawable = (id<CAMetalDrawable>)self;
    if ([metalDrawable respondsToSelector:@selector(addPresentedHandler:)]) {
        [metalDrawable addPresentedHandler:^(id<MTLDrawable> d) {
            ProcessNativePresentation(metalDrawable);
        }];
    } else {
        ProcessNativePresentation(metalDrawable);
    }
    %orig(presentationTime);
}

- (void)presentAfterMinimumDuration:(CFTimeInterval)duration {
    id<CAMetalDrawable> metalDrawable = (id<CAMetalDrawable>)self;
    if ([metalDrawable respondsToSelector:@selector(addPresentedHandler:)]) {
        [metalDrawable addPresentedHandler:^(id<MTLDrawable> d) {
            ProcessNativePresentation(metalDrawable);
        }];
    } else {
        ProcessNativePresentation(metalDrawable);
    }
    // Uncap 60 FPS duration locks (~16.6ms) to 120 FPS duration (~8.33ms)
    CFTimeInterval uncapped = (duration >= 0.010) ? (1.0 / 120.0) : duration;
    %orig(uncapped);
}

%end

// ============================================================================
// Hook: MTLCommandBuffer Presentations
// ============================================================================
@interface _MTLCommandBuffer : NSObject <MTLCommandBuffer>
@end

%hook _MTLCommandBuffer

- (void)presentDrawable:(id<MTLDrawable>)drawable {
    if ([drawable conformsToProtocol:@protocol(CAMetalDrawable)]) {
        id<CAMetalDrawable> metalDrawable = (id<CAMetalDrawable>)drawable;
        [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> cb) {
            ProcessNativePresentation(metalDrawable);
        }];
    }
    %orig(drawable);
}

- (void)presentDrawable:(id<MTLDrawable>)drawable atTime:(CFTimeInterval)presentationTime {
    if ([drawable conformsToProtocol:@protocol(CAMetalDrawable)]) {
        id<CAMetalDrawable> metalDrawable = (id<CAMetalDrawable>)drawable;
        [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> cb) {
            ProcessNativePresentation(metalDrawable);
        }];
    }
    %orig(drawable, presentationTime);
}

- (void)presentDrawable:(id<MTLDrawable>)drawable afterMinimumDuration:(CFTimeInterval)duration {
    if ([drawable conformsToProtocol:@protocol(CAMetalDrawable)]) {
        id<CAMetalDrawable> metalDrawable = (id<CAMetalDrawable>)drawable;
        [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> cb) {
            ProcessNativePresentation(metalDrawable);
        }];
    }
    // Uncap 60 FPS duration locks (~16.6ms) to 120 FPS duration (~8.33ms)
    CFTimeInterval uncapped = (duration >= 0.010) ? (1.0 / 120.0) : duration;
    %orig(drawable, uncapped);
}

%end

// ============================================================================
// Hook: UIWindow makeKeyAndVisible to attach overlay when window becomes active
// ============================================================================
%hook UIWindow

- (void)makeKeyAndVisible {
    %orig;
    NSString *className = NSStringFromClass([self class]);
    if (![className containsString:@"MetalFGOverlay"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[MetalFGOverlay sharedOverlay] show];
        });
    }
}

%end

// ============================================================================
// Constructor & Safe Process Filtering
// ============================================================================
%ctor {
    @autoreleasepool {
        const char *progname = getprogname();
        if (!progname) return;
        
        // Strictly reject SpringBoard, system daemons, and launchd
        if (strcmp(progname, "SpringBoard") == 0 ||
            strcmp(progname, "backboardd") == 0 ||
            strcmp(progname, "launchd") == 0 ||
            strcmp(progname, "runningboardd") == 0 ||
            strcmp(progname, "containermanagerd") == 0 ||
            strcmp(progname, "wifid") == 0 ||
            strcmp(progname, "mediaserverd") == 0) {
            return;
        }
        
        // Reject jailbreak managers and package managers
        if (strcmp(progname, "Sileo") == 0 ||
            strcmp(progname, "Zebra") == 0 ||
            strcmp(progname, "Dopamine") == 0 ||
            strcmp(progname, "TrollStore") == 0 ||
            strcmp(progname, "Filza") == 0) {
            return;
        }
        
        // Verify executable path via dyld
        char execPath[1024];
        uint32_t size = sizeof(execPath);
        if (_NSGetExecutablePath(execPath, &size) != 0) {
            return;
        }
        
        // Strictly ensure this binary is inside an .app bundle
        if (strstr(execPath, ".app/") == NULL && strstr(execPath, ".app") == NULL) {
            return;
        }
        
        // Strictly reject binaries in system directories
        if (strncmp(execPath, "/System/", 8) == 0 ||
            strncmp(execPath, "/Library/", 9) == 0 ||
            strncmp(execPath, "/usr/", 5) == 0) {
            return;
        }
        
        // Check CFBundleIdentifier if available at constructor time
        CFBundleRef mainBundle = CFBundleGetMainBundle();
        if (mainBundle) {
            CFStringRef cfBundleId = CFBundleGetIdentifier(mainBundle);
            if (cfBundleId && CFStringHasPrefix(cfBundleId, CFSTR("com.apple."))) {
                return;
            }
        }
        
        NSLog(@"==================================================");
        NSLog(@"[MetalFG] Initializing MetalFG for target: %s (%s)", progname, execPath);
        NSLog(@"==================================================");
        
        // Initialize Logos hooks strictly for this game process
        %init;
        
        // Start high-frequency CoreMotion sensor fusion
        [[MetalFGMotionTracker sharedTracker] startTracking];
        
        // Immediately schedule HUD overlay display on the main queue
        dispatch_async(dispatch_get_main_queue(), ^{
            [[MetalFGOverlay sharedOverlay] show];
        });
        
        // Ensure overlay is shown when application becomes active or scene activates
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            [[MetalFGOverlay sharedOverlay] show];
        }];
        
        [[NSNotificationCenter defaultCenter] addObserverForName:UISceneDidActivateNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            [[MetalFGOverlay sharedOverlay] show];
        }];
        
        // Load preferences
        NSString *prefPath = @"/var/jb/var/mobile/Library/Preferences/com.dnullptr.metalfg.plist";
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:prefPath];
        if (!prefs) {
            prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/jb/var/mobile/Library/Preferences/com.metalfg.prefs.plist"];
        }
        if (prefs) {
            NSNumber *enabledNum = prefs[@"enabled"];
            if (enabledNum) {
                [MetalFGSynchronizer sharedSynchronizer].isEnabled = [enabledNum boolValue];
            }
            NSNumber *debugNum = prefs[@"debugTint"];
            if (debugNum) {
                [MetalFGSynchronizer sharedSynchronizer].debugTint = [debugNum boolValue];
            }
            NSNumber *fovNum = prefs[@"fovY"];
            if (fovNum) {
                [MetalFGSynchronizer sharedSynchronizer].fovYDegrees = [fovNum floatValue];
            }
        }
    }
}

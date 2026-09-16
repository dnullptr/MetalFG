#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>

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
        if (drawableSize.width < kMinHUDDimension && drawableSize.height < kMinHUDDimension) {
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
// Helper: Process Native Frame Presentation
// ============================================================================
static inline void ProcessNativePresentation(id<CAMetalDrawable> drawable) {
    if (!drawable) return;
    
    // 1. Recursion guard: ignore our own synthetic warp frames
    NSNumber *isSynthetic = objc_getAssociatedObject(drawable, &kMetalFGIsSyntheticKey);
    if (isSynthetic && [isSynthetic boolValue]) {
        return;
    }
    
    id<MTLTexture> texture = drawable.texture;
    if (!texture) return;
    
    // 2. HUD / Overlay guard: ignore small textures (e.g. CAPerfHud / MetalHUD)
    if (texture.width < kMinHUDDimension && texture.height < kMinHUDDimension) {
        return;
    }
    
    // 3. Bind active layer if not already bound
    CAMetalLayer *activeLayer = [MetalFGSynchronizer sharedSynchronizer].activeLayer;
    if (!activeLayer && drawable.layer) {
        activeLayer = drawable.layer;
        [[MetalFGSynchronizer sharedSynchronizer] startSynchronizerWithLayer:activeLayer
                                                                    device:activeLayer.device
                                                               pixelFormat:activeLayer.pixelFormat];
    }
    
    // 4. If layer is set, ensure this drawable belongs to the game layer
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
    ProcessNativePresentation((id<CAMetalDrawable>)self);
    %orig;
}

- (void)presentAtTime:(CFTimeInterval)presentationTime {
    ProcessNativePresentation((id<CAMetalDrawable>)self);
    %orig(presentationTime);
}

- (void)presentAfterMinimumDuration:(CFTimeInterval)duration {
    ProcessNativePresentation((id<CAMetalDrawable>)self);
    // Uncap 60 FPS duration locks (~16.6ms) to 120 FPS duration (~8.33ms)
    CFTimeInterval uncapped = (duration >= 0.010) ? (1.0 / 120.0) : duration;
    %orig(uncapped);
}

%end

// ============================================================================
// Hook: MTLCommandBuffer Presentations
// ============================================================================
%hook _MTLCommandBuffer

- (void)presentDrawable:(id<MTLDrawable>)drawable {
    if ([drawable conformsToProtocol:@protocol(CAMetalDrawable)]) {
        ProcessNativePresentation((id<CAMetalDrawable>)drawable);
    }
    %orig(drawable);
}

- (void)presentDrawable:(id<MTLDrawable>)drawable atTime:(CFTimeInterval)presentationTime {
    if ([drawable conformsToProtocol:@protocol(CAMetalDrawable)]) {
        ProcessNativePresentation((id<CAMetalDrawable>)drawable);
    }
    %orig(drawable, presentationTime);
}

- (void)presentDrawable:(id<MTLDrawable>)drawable afterMinimumDuration:(CFTimeInterval)duration {
    if ([drawable conformsToProtocol:@protocol(CAMetalDrawable)]) {
        ProcessNativePresentation((id<CAMetalDrawable>)drawable);
    }
    // Uncap 60 FPS duration locks (~16.6ms) to 120 FPS duration (~8.33ms)
    CFTimeInterval uncapped = (duration >= 0.010) ? (1.0 / 120.0) : duration;
    %orig(drawable, uncapped);
}

%end

// ============================================================================
// Constructor & Safe Process Filtering
// ============================================================================
%ctor {
    @autoreleasepool {
        NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
        if (!bundleID) return; // Daemons without bundle IDs
        
        // Strictly reject any Apple system apps, SpringBoard, and system daemons
        if ([bundleID hasPrefix:@"com.apple."]) {
            return;
        }
        
        // Reject jailbreak managers and package managers
        if ([bundleID isEqualToString:@"org.coolstar.SileoStore"] ||
            [bundleID isEqualToString:@"xyz.willy.Zebra"] ||
            [bundleID isEqualToString:@"com.opa334.Dopamine"] ||
            [bundleID isEqualToString:@"com.opa334.TrollStore"] ||
            [bundleID isEqualToString:@"com.tigisoftware.Filza"]) {
            return;
        }
        
        // Ensure this is an application bundle (.app)
        NSString *bundlePath = [NSBundle mainBundle].bundlePath;
        if (!bundlePath || ![bundlePath.pathExtension isEqualToString:@"app"]) {
            return;
        }
        
        // Strictly reject binaries in system directories
        if ([bundlePath hasPrefix:@"/System/"] || [bundlePath hasPrefix:@"/Library/"]) {
            return;
        }
        
        NSLog(@"==================================================");
        NSLog(@"[MetalFG] Initializing MetalFG for target game: %@", bundleID);
        NSLog(@"[MetalFG] Bundle path: %@", bundlePath);
        NSLog(@"==================================================");
        
        // Initialize Logos hooks strictly for this game process
        %init;
        
        // Start high-frequency CoreMotion sensor fusion
        [[MetalFGMotionTracker sharedTracker] startTracking];
        
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

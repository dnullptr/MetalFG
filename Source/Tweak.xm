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

// Minimum dimension threshold to distinguish full-screen game layers from HUD overlays (e.g. MetalHUD, CAPerfHud)
static const CGFloat kMinGameDimension = 600.0;

// Global reference to the active game layer
static __weak CAMetalLayer *gActiveMetalLayer = nil;

// Helper: Determine if a layer is the primary game rendering layer
static inline BOOL IsPrimaryGameLayer(CAMetalLayer *layer) {
    if (!layer) return NO;
    
    // Check layer size - ignore small overlays or HUDs
    CGSize drawableSize = layer.drawableSize;
    if (drawableSize.width < kMinGameDimension || drawableSize.height < kMinGameDimension) {
        return NO;
    }
    
    // Ignore layers with names or classes indicating HUD/debug/metrics
    NSString *className = NSStringFromClass([layer class]);
    if ([className containsString:@"HUD"] ||
        [className containsString:@"Perf"] ||
        [className containsString:@"Debug"] ||
        [className containsString:@"Overlay"]) {
        return NO;
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
// Hook: CAMetalLayer Lifecycle & Swapchain Headroom
// ============================================================================
%hook CAMetalLayer

- (void)setDevice:(id<MTLDevice>)device {
    %orig(device);
    
    if (IsPrimaryGameLayer(self)) {
        self.maximumDrawableCount = 3;
        if (@available(iOS 16.0, *)) {
            // Crucial: timeout instead of deadlocking when GPU backpressure is high
            self.allowsNextDrawableTimeout = YES;
        }
        gActiveMetalLayer = self;
        [[MetalFGSynchronizer sharedSynchronizer] startSynchronizerWithLayer:self
                                                                    device:device
                                                               pixelFormat:self.pixelFormat];
    }
}

- (id<CAMetalDrawable>)nextDrawable {
    if (IsPrimaryGameLayer(self)) {
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
    if (texture.width < kMinGameDimension || texture.height < kMinGameDimension) {
        return;
    }
    
    // 3. Layer guard: only process drawables from the active game layer
    CAMetalLayer *activeLayer = [MetalFGSynchronizer sharedSynchronizer].activeLayer;
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
    %orig(duration);
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
    %orig(drawable, duration);
}

%end

// ============================================================================
// Constructor & Process Filtering
// ============================================================================
%ctor {
    @autoreleasepool {
        // 1. Binary path check: ONLY inject into user applications
        NSString *executablePath = [NSProcessInfo processInfo].arguments.firstObject;
        if (!executablePath) return;
        
        // Strictly reject any system process or daemon
        if ([executablePath containsString:@"/System/"] ||
            [executablePath containsString:@"/usr/"] ||
            [executablePath containsString:@"/Library/"] ||
            [executablePath containsString:@"/Applications/"]) {
            return;
        }
        
        // Must reside in user application bundle container
        if (![executablePath containsString:@"/Containers/Bundle/Application/"]) {
            return;
        }
        
        // 2. Bundle ID check: strictly reject any Apple system bundles
        NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
        if (!bundleID || [bundleID hasPrefix:@"com.apple."]) {
            return;
        }
        
        // Blacklist package managers and jailbreak utilities
        if ([bundleID isEqualToString:@"org.coolstar.SileoStore"] ||
            [bundleID isEqualToString:@"xyz.willy.Zebra"] ||
            [bundleID isEqualToString:@"com.opa334.Dopamine"] ||
            [bundleID isEqualToString:@"com.opa334.TrollStore"] ||
            [bundleID isEqualToString:@"com.tigisoftware.Filza"]) {
            return;
        }
        
        NSLog(@"==================================================");
        NSLog(@"[MetalFG] Initializing MetalFG for target game: %@", bundleID);
        NSLog(@"[MetalFG] Path: %@", executablePath);
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

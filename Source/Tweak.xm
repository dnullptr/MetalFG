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

// Global reference to the active layer
static __weak CAMetalLayer *gActiveMetalLayer = nil;

// ============================================================================
// Hook: Unlock 120Hz ProMotion on iOS 16 Devices
// ============================================================================
%hook UIScreen

- (NSInteger)maximumFramesPerSecond {
    // Force 120Hz ProMotion headroom
    return 120;
}

%end

// ============================================================================
// Hook: CAMetalLayer Lifecycle & Swapchain Headroom
// ============================================================================
%hook CAMetalLayer

- (instancetype)init {
    self = %orig;
    if (self) {
        // Enforce triple-buffering to provide swapchain headroom for synthetic frames
        self.maximumDrawableCount = 3;
    }
    return self;
}

- (void)setDevice:(id<MTLDevice>)device {
    %orig(device);
    self.maximumDrawableCount = 3;
    
    // Initialize or bind the frame synchronizer with this layer and device
    [[MetalFGSynchronizer sharedSynchronizer] startSynchronizerWithLayer:self
                                                                device:device
                                                           pixelFormat:self.pixelFormat];
}

- (id<CAMetalDrawable>)nextDrawable {
    // Maintain triple buffering
    if (self.maximumDrawableCount < 3) {
        self.maximumDrawableCount = 3;
    }
    
    gActiveMetalLayer = self;
    
    // Ensure synchronizer is active
    if (![MetalFGSynchronizer sharedSynchronizer].activeLayer) {
        [[MetalFGSynchronizer sharedSynchronizer] startSynchronizerWithLayer:self
                                                                    device:self.device
                                                               pixelFormat:self.pixelFormat];
    }
    
    return %orig;
}

%end

// ============================================================================
// Helper: Process Native Frame Presentation
// ============================================================================
static inline void ProcessNativePresentation(id<CAMetalDrawable> drawable) {
    if (!drawable) return;
    
    // Check if this is one of our synthetic frames to prevent recursion
    NSNumber *isSynthetic = objc_getAssociatedObject(drawable, &kMetalFGIsSyntheticKey);
    if (isSynthetic && [isSynthetic boolValue]) {
        return;
    }
    
    CFTimeInterval now = CACurrentMediaTime();
    simd_quatf orientation = [[MetalFGMotionTracker sharedTracker] orientationAtTimestamp:now];
    
    id<MTLTexture> texture = drawable.texture;
    if (texture) {
        [[MetalFGSynchronizer sharedSynchronizer] notifyNativeFramePresented:texture
                                                                atTimestamp:now
                                                                orientation:orientation];
    }
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
// Constructor & Initialization
// ============================================================================
%ctor {
    @autoreleasepool {
        NSLog(@"==================================================");
        NSLog(@"[MetalFG] Initializing MetalFG (Asynchronous Timewarp Frame Generation)...");
        NSLog(@"[MetalFG] Target: iOS 16 Rootless / arm64e ProMotion");
        NSLog(@"==================================================");
        
        // Start high-frequency CoreMotion sensor fusion
        [[MetalFGMotionTracker sharedTracker] startTracking];
        
        // Check for debug preferences
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

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>
#import "MetalFGWarper.h"
#import "TouchTracker.h"

NS_ASSUME_NONNULL_BEGIN

@interface MetalFGSynchronizer : NSObject

// Singleton
+ (instancetype)sharedSynchronizer;

@property (nonatomic, assign) BOOL isEnabled;
@property (nonatomic, assign) BOOL debugTint;         // Visual tint for synthetic frames

// Dynamic Tuning Parameters
@property (nonatomic, assign) float motionScale;             // Default: 0.42 (Range: 0.10 - 0.80)
@property (nonatomic, assign) float disocclusionThreshold;   // Default: 0.22 (Range: 0.10 - 0.40)
@property (nonatomic, assign) float uiSensitivity;           // Default: 0.035 (Range: 0.01 - 0.08)
@property (nonatomic, assign) NSInteger currentPreset;       // 0: Clear, 1: Balanced, 2: Fluid, 3: Custom

- (void)applyPreset:(NSInteger)presetIndex;
- (void)savePreferences;
- (void)loadPreferences;

// Active Metal resources
@property (nonatomic, weak, nullable) CAMetalLayer *activeLayer;
@property (nonatomic, strong, nullable) MetalFGWarper *warper;

// Start/stop frame synchronizer
- (void)startSynchronizerWithLayer:(CAMetalLayer *)layer
                            device:(id<MTLDevice>)device
                       pixelFormat:(MTLPixelFormat)pixelFormat;
- (void)stopSynchronizer;

// Called by hooks whenever the game completes rendering a native frame (v2.0.0)
- (void)notifyNativeFrameRendered:(id<CAMetalDrawable>)drawable;

// Legacy presentation notification
- (void)notifyNativeFramePresented:(id<MTLTexture>)texture
                             layer:(nullable CAMetalLayer *)layer
                       atTimestamp:(CFTimeInterval)timestamp;

- (void)notifyNativeFramePresented:(id<MTLTexture>)texture
                       atTimestamp:(CFTimeInterval)timestamp
                       orientation:(simd_quatf)orientation;

@end

NS_ASSUME_NONNULL_END

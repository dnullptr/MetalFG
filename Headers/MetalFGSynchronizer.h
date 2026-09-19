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
@property (nonatomic, assign) float motionScale;             // Default: 0.45 (Range: 0.10 - 0.70)
@property (nonatomic, assign) float disocclusionThreshold;   // Default: 0.20 (Range: 0.08 - 0.35)
@property (nonatomic, assign) float uiSensitivity;           // Default: 0.035 (Range: 0.01 - 0.08)
@property (nonatomic, assign) float motionDeadzone;          // Default: 0.0004 (Range: 0.0001 - 0.0020)
@property (nonatomic, assign) NSInteger currentPreset;       // 0: Crisp, 1: Balanced, 2: Ultra Smooth, 3: Custom

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

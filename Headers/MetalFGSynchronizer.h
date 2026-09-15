#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>
#import "MetalFGWarper.h"
#import "CoreMotionTracker.h"

NS_ASSUME_NONNULL_BEGIN

@interface MetalFGSynchronizer : NSObject

// Singleton
+ (instancetype)sharedSynchronizer;

@property (nonatomic, assign) BOOL isEnabled;
@property (nonatomic, assign) float fovYDegrees;      // Camera vertical FOV (default 75.0)
@property (nonatomic, assign) BOOL debugTint;         // Visual tint for synthetic frames

// Active Metal resources
@property (nonatomic, weak, nullable) CAMetalLayer *activeLayer;
@property (nonatomic, strong, nullable) MetalFGWarper *warper;
@property (nonatomic, strong, nullable) MetalFGMotionTracker *motionTracker;

// Start/stop frame synchronizer
- (void)startSynchronizerWithLayer:(CAMetalLayer *)layer
                            device:(id<MTLDevice>)device
                       pixelFormat:(MTLPixelFormat)pixelFormat;
- (void)stopSynchronizer;

// Called by hooks whenever the game presents a native frame
- (void)notifyNativeFramePresented:(id<MTLTexture>)texture
                       atTimestamp:(CFTimeInterval)timestamp
                       orientation:(simd_quatf)orientation;

@end

NS_ASSUME_NONNULL_END


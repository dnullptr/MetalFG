#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <simd/simd.h>
#import "ShaderTypes.h"

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif
extern const char kMetalFGIsSyntheticKey;
#ifdef __cplusplus
}
#endif

@interface MetalFGWarper : NSObject

@property (nonatomic, readonly) id<MTLDevice> device;
@property (nonatomic, readonly) MTLPixelFormat pixelFormat;
@property (nonatomic, readonly) BOOL isReady;

// Dynamic tuning parameters
@property (nonatomic, assign) float motionScale;             // Default 0.42 (timeOffsetFactor)
@property (nonatomic, assign) float disocclusionThreshold;   // Default 0.22 (color distance cutoff)
@property (nonatomic, assign) float uiSensitivity;           // Default 0.035 (static UI threshold)
@property (nonatomic, assign) BOOL debugTintEnabled;

// Lifecycle
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                            pixelFormat:(MTLPixelFormat)pixelFormat;

// Capture the game's rendered frame into double-buffered cache and dispatch BME
- (void)captureBaseTexture:(id<MTLTexture>)sourceTexture
             withTimestamp:(CFTimeInterval)timestamp
             touchVelocity:(simd_float2)touchVelocity;

// Render and present synthetic motion-interpolated frame into target drawable
- (BOOL)renderSyntheticFrameToDrawable:(id<CAMetalDrawable>)targetDrawable
                        targetTimeHint:(CFTimeInterval)targetTimeHint;

// Check if a synthetic frame is currently processing on GPU
- (BOOL)isGpuBusy;

@end

NS_ASSUME_NONNULL_END

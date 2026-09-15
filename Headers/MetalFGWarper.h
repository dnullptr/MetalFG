#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <simd/simd.h>
#import "ShaderTypes.h"

NS_ASSUME_NONNULL_BEGIN

// Associated object key to identify synthetic frames and prevent recursive interception
extern const char kMetalFGIsSyntheticKey;

@interface MetalFGWarper : NSObject

@property (nonatomic, readonly) id<MTLDevice> device;
@property (nonatomic, readonly) MTLPixelFormat pixelFormat;
@property (nonatomic, readonly) BOOL isReady;

// Debug settings
@property (nonatomic, assign) BOOL debugTintEnabled;
@property (nonatomic, assign) float edgeFadeWidth; // Default 0.02

// Lifecycle
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                            pixelFormat:(MTLPixelFormat)pixelFormat;

// Capture the game's rendered frame into double-buffered cache
- (void)captureBaseTexture:(id<MTLTexture>)sourceTexture
             withTimestamp:(CFTimeInterval)timestamp
               orientation:(simd_quatf)orientation;

// Render and present synthetic warped frame into the target drawable
- (BOOL)renderSyntheticFrameToDrawable:(id<CAMetalDrawable>)targetDrawable
                     homographyMatrix:(simd_float3x3)homography
                  invHomographyMatrix:(simd_float3x3)invHomography
                        targetTimeHint:(CFTimeInterval)targetTimeHint;

// Check if a synthetic frame is currently processing on GPU
- (BOOL)isGpuBusy;

@end

NS_ASSUME_NONNULL_END

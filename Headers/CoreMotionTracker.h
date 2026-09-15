#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>
#import <UIKit/UIKit.h>
#import <simd/simd.h>
#import "ShaderTypes.h"

NS_ASSUME_NONNULL_BEGIN

// Struct holding a single timestamped motion sample
typedef struct {
    CFTimeInterval timestamp;
    simd_quatf orientation;      // Unit quaternion (x, y, z, w)
    simd_float3 angularVelocity; // Angular rate in rad/s (x, y, z)
} MetalFGMotionSample;

@interface MetalFGMotionTracker : NSObject

// Singleton accessor
+ (instancetype)sharedTracker;

// State management
@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, assign) NSTimeInterval updateInterval; // Default 1/120s (~8.33ms) or 1/200s (5ms)

// Start and stop high-frequency sensor capture
- (BOOL)startTracking;
- (void)stopTracking;

// Retrieve the interpolated/extrapolated orientation at an exact timestamp
- (simd_quatf)orientationAtTimestamp:(CFTimeInterval)timestamp;

// Compute 3x3 homography mapping target NDC to base frame NDC
- (simd_float3x3)computeHomographyFromBase:(simd_quatf)baseQuat
                                  toTarget:(simd_quatf)targetQuat
                               fovYDegrees:(float)fovYDegrees
                               aspectRatio:(float)aspectRatio
                               orientation:(UIInterfaceOrientation)interfaceOrientation;

// Helper to compute matrix inverse for 3x3 matrices
- (simd_float3x3)invertMatrix3x3:(simd_float3x3)m;

@end

NS_ASSUME_NONNULL_END


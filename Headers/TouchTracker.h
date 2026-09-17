#import <UIKit/UIKit.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

@interface MetalFGTouchTracker : NSObject

+ (instancetype)sharedTracker;

// Process touch events dispatched by UIWindow
- (void)processTouchEvent:(UIEvent *)event;

// Sample the current smoothed touch velocity in normalized UV coordinates per native frame
- (simd_float2)normalizedVelocityForScreenSize:(CGSize)screenSize;

// Reset velocity when touches end
- (void)reset;

@end

NS_ASSUME_NONNULL_END


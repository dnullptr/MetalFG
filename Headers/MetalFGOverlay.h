#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MetalFGOverlay : UIView

+ (instancetype)sharedOverlay;

// Display the floating badge on the active game window
- (void)show;

// Update real-time measured framerate stats
- (void)updateWithNativeFPS:(double)nativeFps
               syntheticFPS:(double)syntheticFps;

// Open/close the live tuning panel
- (void)toggleTuningPanel;

@end

NS_ASSUME_NONNULL_END


#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MetalFGOverlay : UIView

+ (instancetype)sharedOverlay;

// Display the floating badge on the active game window
- (void)show;

// Update real-time measured framerate stats
- (void)updateWithNativeFPS:(double)nativeFps
               syntheticFPS:(double)syntheticFps;

// Update per-second display pacing stats (on-screen holds of ~8.3ms vs any other duration)
- (void)updatePacingWithSyntheticOnTime:(unsigned)sOnTime
                          syntheticLate:(unsigned)sLate
                           nativeOnTime:(unsigned)nOnTime
                             nativeLate:(unsigned)nLate
                                dropped:(unsigned)dropped
                            orderBreaks:(unsigned)orderBreaks;

// Open/close the live tuning panel
- (void)toggleTuningPanel;

@end

NS_ASSUME_NONNULL_END


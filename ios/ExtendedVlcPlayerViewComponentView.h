#import <React/RCTViewComponentView.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Fabric view component for `ExtendedVlcPlayerView`. This is the
 * Obj-C++ entry point that React Native's New Architecture uses to mount
 * a native UIView.
 *
 * The actual UIView is a vanilla UIView that we set as the
 * `VLCMediaPlayer.drawable` so libVLC draws into it directly. We don't
 * subclass any specific VLC class because libVLC's drawable protocol is
 * `UIView` — any UIView works.
 */
@interface ExtendedVlcPlayerViewComponentView : RCTViewComponentView
@end

NS_ASSUME_NONNULL_END

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Routes libVLC's decoded video frames into pooled NV12 `CVPixelBuffer`s.
///
/// MobileVLCKit 3 renders through an OpenGL ES view that iOS stops drawing
/// in the background and that cannot back a Picture-in-Picture window. The
/// sink installs libVLC's `vmem` callbacks on the underlying
/// `libvlc_media_player_t` instead, so every frame reaches an
/// `AVSampleBufferDisplayLayer`, both inline and in PiP.
///
/// Callbacks run on libVLC's video output thread.
@interface EXVLCFrameSink : NSObject

/// Installs the callbacks on the given `VLCMediaPlayer`. Must be called
/// before the player's first `play`.
- (instancetype)initWithMediaPlayer:(id)mediaPlayer NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Called on the video output thread with each displayed frame.
@property (atomic, copy, nullable) void (^onFrame)(CVPixelBufferRef pixelBuffer);

/// Stops forwarding frames. libVLC may still request buffers until its
/// video output closes, so the sink keeps serving them.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END

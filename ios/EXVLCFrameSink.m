#import "EXVLCFrameSink.h"

#import <objc/runtime.h>
#import <os/lock.h>

// MobileVLCKit ships the libVLC C API inside its binary but keeps the
// headers out of its module map, so the few entry points we need are
// declared here with the exact libVLC 3 signatures.
typedef struct libvlc_media_player_t libvlc_media_player_t;
typedef void *(*exvlc_video_lock_cb)(void *opaque, void **planes);
typedef void (*exvlc_video_unlock_cb)(void *opaque, void *picture, void *const *planes);
typedef void (*exvlc_video_display_cb)(void *opaque, void *picture);
typedef unsigned (*exvlc_video_format_cb)(void **opaque, char *chroma, unsigned *width,
                                          unsigned *height, unsigned *pitches, unsigned *lines);
typedef void (*exvlc_video_cleanup_cb)(void *opaque);

extern void libvlc_video_set_callbacks(libvlc_media_player_t *mp, exvlc_video_lock_cb lock,
                                       exvlc_video_unlock_cb unlock,
                                       exvlc_video_display_cb display, void *opaque);
extern void libvlc_video_set_format_callbacks(libvlc_media_player_t *mp,
                                              exvlc_video_format_cb setup,
                                              exvlc_video_cleanup_cb cleanup);

// Private VLCMediaPlayer accessor present in every MobileVLCKit 3 release.
@interface NSObject (EXVLCMediaPlayerInternal)
- (void *)libVLCMediaPlayer;
@end

static const void *EXVLCFrameSinkAssociationKey = &EXVLCFrameSinkAssociationKey;

@implementation EXVLCFrameSink {
  os_unfair_lock _lock;
  CVPixelBufferPoolRef _pool;
  // Written only on libVLC's video output thread.
  CVPixelBufferRef _fallback;
  CVPixelBufferRef _pending;
  BOOL _invalidated;
}

- (instancetype)initWithMediaPlayer:(id)mediaPlayer
{
  if ((self = [super init])) {
    _lock = OS_UNFAIR_LOCK_INIT;
    libvlc_media_player_t *mp = NULL;
    if ([mediaPlayer respondsToSelector:@selector(libVLCMediaPlayer)]) {
      mp = (libvlc_media_player_t *)[mediaPlayer libVLCMediaPlayer];
    }
    if (mp == NULL) {
      NSLog(@"[ExtendedVlcPlayer] libVLC media player handle is unavailable; video output disabled");
      return self;
    }
    // libVLC keeps a raw pointer to the sink until the media player is
    // released, so the player owns the sink rather than the session.
    objc_setAssociatedObject(mediaPlayer, EXVLCFrameSinkAssociationKey, self,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    void *opaque = (__bridge void *)self;
    libvlc_video_set_format_callbacks(mp, EXVLCFormatSetup, EXVLCFormatCleanup);
    libvlc_video_set_callbacks(mp, EXVLCLock, EXVLCUnlock, EXVLCDisplay, opaque);
  }
  return self;
}

- (void)dealloc
{
  if (_pool != NULL) {
    CVPixelBufferPoolRelease(_pool);
  }
  if (_fallback != NULL) {
    CVPixelBufferRelease(_fallback);
  }
  if (_pending != NULL) {
    CVPixelBufferRelease(_pending);
  }
}

- (void)invalidate
{
  os_unfair_lock_lock(&_lock);
  _invalidated = YES;
  os_unfair_lock_unlock(&_lock);
  self.onFrame = nil;
}

#pragma mark - libVLC callbacks

- (unsigned)setupWithChroma:(char *)chroma
                      width:(unsigned *)width
                     height:(unsigned *)height
                    pitches:(unsigned *)pitches
                      lines:(unsigned *)lines
{
  // NV12 matches VideoToolbox's decoder output, so libVLC only copies
  // planes instead of converting colour spaces on the CPU.
  memcpy(chroma, "NV12", 4);

  NSDictionary *attributes = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
    (id)kCVPixelBufferWidthKey : @(*width),
    (id)kCVPixelBufferHeightKey : @(*height),
    (id)kCVPixelBufferBytesPerRowAlignmentKey : @64,
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };
  CVPixelBufferPoolRef pool = NULL;
  if (CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attributes,
                              &pool) != kCVReturnSuccess) {
    return 0;
  }

  // Every buffer from the pool shares one layout; read it from a sample so
  // libVLC writes rows with the stride CoreVideo actually allocated.
  CVPixelBufferRef sample = NULL;
  if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &sample) != kCVReturnSuccess) {
    CVPixelBufferPoolRelease(pool);
    return 0;
  }
  for (size_t plane = 0; plane < 2; plane++) {
    pitches[plane] = (unsigned)CVPixelBufferGetBytesPerRowOfPlane(sample, plane);
    lines[plane] = (unsigned)CVPixelBufferGetHeightOfPlane(sample, plane);
  }
  // libVLC copies into whatever planes `lock` returns, so keep one buffer
  // to hand out if the pool ever fails to vend a new one.
  if (_fallback != NULL) {
    CVPixelBufferRelease(_fallback);
  }
  _fallback = sample;

  os_unfair_lock_lock(&_lock);
  CVPixelBufferPoolRef previous = _pool;
  _pool = pool;
  os_unfair_lock_unlock(&_lock);
  if (previous != NULL) {
    CVPixelBufferPoolRelease(previous);
  }
  return 1;
}

- (void *)lockPlanes:(void **)planes
{
  os_unfair_lock_lock(&_lock);
  CVPixelBufferPoolRef pool = _pool != NULL ? CVPixelBufferPoolRetain(_pool) : NULL;
  os_unfair_lock_unlock(&_lock);
  if (pool == NULL) {
    return NULL;
  }

  CVPixelBufferRef buffer = NULL;
  CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer);
  CVPixelBufferPoolRelease(pool);
  if (buffer == NULL && _fallback != NULL) {
    buffer = CVPixelBufferRetain(_fallback);
  }
  if (buffer == NULL) {
    return NULL;
  }
  CVPixelBufferLockBaseAddress(buffer, 0);
  planes[0] = CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
  planes[1] = CVPixelBufferGetBaseAddressOfPlane(buffer, 1);

  // libVLC 3's vmem runs lock -> copy -> unlock -> display for each frame,
  // so the buffer must outlive `unlock`. Keep the +1 reference until the
  // frame is displayed, or until the next lock if libVLC skipped display.
  if (_pending != NULL) {
    CVPixelBufferRelease(_pending);
  }
  _pending = buffer;
  return buffer;
}

- (void)unlockPicture:(void *)picture
{
  if (picture != NULL) {
    CVPixelBufferUnlockBaseAddress((CVPixelBufferRef)picture, 0);
  }
}

- (void)displayPicture:(void *)picture
{
  if (picture == NULL || picture != _pending) {
    return;
  }
  CVPixelBufferRef buffer = _pending;
  _pending = NULL;

  os_unfair_lock_lock(&_lock);
  BOOL invalidated = _invalidated;
  os_unfair_lock_unlock(&_lock);
  void (^onFrame)(CVPixelBufferRef) = self.onFrame;
  if (!invalidated && onFrame != nil) {
    onFrame(buffer);
  }
  CVPixelBufferRelease(buffer);
}

static unsigned EXVLCFormatSetup(void **opaque, char *chroma, unsigned *width, unsigned *height,
                                 unsigned *pitches, unsigned *lines)
{
  EXVLCFrameSink *sink = (__bridge EXVLCFrameSink *)*opaque;
  return [sink setupWithChroma:chroma width:width height:height pitches:pitches lines:lines];
}

static void EXVLCFormatCleanup(void *opaque)
{
  // Pools are replaced on the next setup and released with the sink.
}

static void *EXVLCLock(void *opaque, void **planes)
{
  return [(__bridge EXVLCFrameSink *)opaque lockPlanes:planes];
}

static void EXVLCUnlock(void *opaque, void *picture, void *const *planes)
{
  [(__bridge EXVLCFrameSink *)opaque unlockPicture:picture];
}

static void EXVLCDisplay(void *opaque, void *picture)
{
  [(__bridge EXVLCFrameSink *)opaque displayPicture:picture];
}

@end

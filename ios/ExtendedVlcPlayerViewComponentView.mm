#import "ExtendedVlcPlayerViewComponentView.h"
// The Swift compatibility header is emitted into the pod framework's Headers
// directory for static framework pods. Import it through the module so this
// mixed Obj-C++ translation unit works with both CocoaPods and Xcode builds.
#import <ExtendedVlcPlayer/ExtendedVlcPlayer-Swift.h>

#import <React/RCTConversions.h>
#import <React/RCTComponent.h>
#import <React/RCTLog.h>
#import <React/RCTViewManager.h>

@interface ExtendedVlcPlayerViewComponentView () <ExtendedVlcPlayerViewEventReceiver>
@property (nonatomic, strong) NSNumber *playerId;
/// Strong refs to the event blocks the JS side passes via props. Keeping
/// strong references prevents them from being collected by the runtime.
@property (nonatomic, copy) RCTBubblingEventBlock onLoadBlock;
@property (nonatomic, copy) RCTBubblingEventBlock onProgressBlock;
@property (nonatomic, copy) RCTBubblingEventBlock onPlayingBlock;
@property (nonatomic, copy) RCTBubblingEventBlock onPausedBlock;
@property (nonatomic, copy) RCTBubblingEventBlock onEndedBlock;
@property (nonatomic, copy) RCTBubblingEventBlock onErrorBlock;
@property (nonatomic, copy) RCTBubblingEventBlock onBufferingBlock;
@property (nonatomic, copy) RCTBubblingEventBlock onPictureInPictureStartBlock;
@property (nonatomic, copy) RCTBubblingEventBlock onPictureInPictureStopBlock;
@end

@implementation ExtendedVlcPlayerViewComponentView

RCT_EXPORT_VIEW_PROPERTY(player, NSNumber)
RCT_EXPORT_VIEW_PROPERTY(contentFit, NSDictionary)
RCT_EXPORT_VIEW_PROPERTY(onLoad, RCTBubblingEventBlock)
RCT_EXPORT_VIEW_PROPERTY(onProgress, RCTBubblingEventBlock)
RCT_EXPORT_VIEW_PROPERTY(onPlaying, RCTBubblingEventBlock)
RCT_EXPORT_VIEW_PROPERTY(onPaused, RCTBubblingEventBlock)
RCT_EXPORT_VIEW_PROPERTY(onEnded, RCTBubblingEventBlock)
RCT_EXPORT_VIEW_PROPERTY(onError, RCTBubblingEventBlock)
RCT_EXPORT_VIEW_PROPERTY(onBuffering, RCTBubblingEventBlock)
RCT_EXPORT_VIEW_PROPERTY(onPictureInPictureStart, RCTBubblingEventBlock)
RCT_EXPORT_VIEW_PROPERTY(onPictureInPictureStop, RCTBubblingEventBlock)

- (void)setPlayer:(NSNumber *)player
{
  NSNumber *nextId = player ?: @0;
  if (self.playerId != nil && [self.playerId isEqualToNumber:nextId]) {
    [self attachSessionIfPossible];
    return;
  }

  [self detachSession];
  self.playerId = nextId;
  [self attachSessionIfPossible];
}

+ (ComponentDescriptorProvider)componentDescriptorProvider
{
  return [RCTViewComponentView new];
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if (self = [super initWithFrame:frame]) {
    self.contentView.backgroundColor = UIColor.blackColor;
  }
  return self;
}

- (void)didMoveToWindow
{
  [super didMoveToWindow];
  [self attachSessionIfPossible];
}

- (void)attachSessionIfPossible
{
  if (self.window == nil || self.playerId == nil || self.playerId.intValue == 0) {
    return;
  }

  NSValue *boxed = [EXVLCPlayerRegistryBridge sessionForId:self.playerId];
  PlayerSession *session = (PlayerSession *)[boxed nonretainedObjectValue];
  if (session == nil) {
    return;
  }

  if (session.drawable.superview != self.contentView) {
    session.drawable.frame = self.contentView.bounds;
    session.drawable.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.contentView addSubview:session.drawable];
  }
  [EXVLCPlayerRegistryBridge attachEventSinks:self.playerId view:self];
}

- (void)detachSession
{
  if (self.playerId == nil || self.playerId.intValue == 0) {
    return;
  }

  NSValue *boxed = [EXVLCPlayerRegistryBridge sessionForId:self.playerId];
  PlayerSession *session = (PlayerSession *)[boxed nonretainedObjectValue];
  if (session != nil && session.drawable.superview == self.contentView) {
    [session.drawable removeFromSuperview];
  }
  [EXVLCPlayerRegistryBridge detachEventSinks:self.playerId];
}

- (void)dealloc
{
  [self detachSession];
  if (self.playerId != nil && self.playerId.intValue != 0) {
    [EXVLCPlayerRegistryBridge destroySession:self.playerId];
  }
}

- (void)updateLayout
{
  [super updateLayout];
  if (self.playerId != nil) {
    NSValue *boxed = [EXVLCPlayerRegistryBridge sessionForId:self.playerId];
    PlayerSession *session = (PlayerSession *)[boxed nonretainedObjectValue];
    if (session != nil) {
      session.drawable.frame = self.contentView.bounds;
    }
  }
}

#pragma mark - ExtendedVlcPlayerViewEventReceiver

- (void)exvlcEmit:(NSString *)name :(NSDictionary *)payload
{
  NSDictionary *p = payload ?: @{};
  if ([name isEqualToString:@"onLoad"] && self.onLoadBlock) { self.onLoadBlock(p); return; }
  if ([name isEqualToString:@"onProgress"] && self.onProgressBlock) { self.onProgressBlock(p); return; }
  if ([name isEqualToString:@"onPlaying"] && self.onPlayingBlock) { self.onPlayingBlock(p); return; }
  if ([name isEqualToString:@"onPaused"] && self.onPausedBlock) { self.onPausedBlock(p); return; }
  if ([name isEqualToString:@"onEnded"] && self.onEndedBlock) { self.onEndedBlock(p); return; }
  if ([name isEqualToString:@"onError"] && self.onErrorBlock) { self.onErrorBlock(p); return; }
  if ([name isEqualToString:@"onBuffering"] && self.onBufferingBlock) { self.onBufferingBlock(p); return; }
  if ([name isEqualToString:@"onPictureInPictureStart"] && self.onPictureInPictureStartBlock) { self.onPictureInPictureStartBlock(p); return; }
  if ([name isEqualToString:@"onPictureInPictureStop"] && self.onPictureInPictureStopBlock) { self.onPictureInPictureStopBlock(p); return; }
}

@end

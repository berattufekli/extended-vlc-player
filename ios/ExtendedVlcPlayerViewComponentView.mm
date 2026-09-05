#import "ExtendedVlcPlayerViewComponentView.h"
#import "ExtendedVlcPlayer-Swift.h"

#import <React/RCTConversions.h>
#import <React/RCTLog.h>

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
  if (self.window != nil && self.playerId == nil) {
    NSNumber *newId = [EXVLCPlayerRegistryBridge createSession];
    self.playerId = newId;
    NSValue *boxed = [EXVLCPlayerRegistryBridge sessionForId:newId];
    PlayerSession *session = (PlayerSession *)[boxed nonretainedObjectValue];
    if (session != nil) {
      session.drawable.frame = self.contentView.bounds;
      session.drawable.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
      [self.contentView addSubview:session.drawable];
      [EXVLCPlayerRegistryBridge attachEventSinks:newId view:self];
    }
  }
}

- (void)dealloc
{
  if (self.playerId != nil) {
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

- (void)exvlcEmit:(NSString *)name payload:(NSDictionary *)payload
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

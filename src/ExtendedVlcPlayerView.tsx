import { requireNativeViewManager } from 'expo-modules-core';
import * as React from 'react';
import { Platform, type ViewStyle } from 'react-native';

import type { ExtendedVlcPlayerViewProps } from './types';

const NativeView = requireNativeViewManager('ExtendedVlcPlayerView');

/**
 * Drop-in replacement for `expo-video`'s `VideoView`. Renders the VLC-backed
 * native player and forwards events back to the JS callbacks.
 */
export const ExtendedVlcPlayerView = React.forwardRef<unknown, ExtendedVlcPlayerViewProps>(
  function ExtendedVlcPlayerView(props, ref) {
    const {
      player,
      style,
      contentFit = 'contain',
      onLoad,
      onProgress,
      onPlaying,
      onPaused,
      onEnded,
      onError,
      onBuffering,
      onPictureInPictureStart,
      onPictureInPictureStop,
    } = props;

    // The `player` object carries the nativeId internally (the hook bumps
    // it on first render). The native view reads it via a getter so we
    // don't have to thread the number through props.
    const nativeId = (player as unknown as { _nativeId?: number })._nativeId ?? 0;

    return (
      <NativeView
        ref={ref}
        style={style as ViewStyle}
        player={nativeId}
        contentFit={contentFit}
        // Standard Fabric "bubbling event" props. They are passed as
        // RCTBubblingEventBlock on the native side; the Swift
        // PlayerSession fires the corresponding closures which the
        // PlayerRegistryBridge forwards back to the view component,
        // which then invokes the right block.
        onLoad={onLoad}
        onProgress={onProgress}
        onPlaying={onPlaying}
        onPaused={onPaused}
        onEnded={onEnded}
        onError={onError}
        onBuffering={onBuffering}
        onPictureInPictureStart={onPictureInPictureStart}
        onPictureInPictureStop={onPictureInPictureStop}
      />
    );
  }
);

// Surface a helpful message on platforms where the view manager is not
// registered (e.g. web). The real native view manager is registered by
// the iOS / Android sides.
if (Platform.OS !== 'ios' && Platform.OS !== 'android') {
  // eslint-disable-next-line no-console
  console.warn(
    '[extended-vlc-player] ExtendedVlcPlayerView is only supported on iOS and Android.'
  );
}

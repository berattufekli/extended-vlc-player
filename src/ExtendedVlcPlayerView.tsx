import { requireNativeViewManager } from 'expo-modules-core';
import * as React from 'react';
import { Platform, type ViewStyle } from 'react-native';

import type { ExtendedVlcPlayerViewProps } from './types';

// Match the Swift view class name, just like Expo's native view modules do.
const NativeView = requireNativeViewManager('ExtendedVlcPlayer', 'ExtendedVlcPlayerView');

type NativeEvent<T> = { nativeEvent: T };

/**
 * Expo view events arrive wrapped as `{ nativeEvent }`. The public props
 * receive the payload itself, matching `expo-video`'s callback shape.
 */
function unwrap<T>(handler: ((payload: T) => void) | undefined) {
  if (!handler) return undefined;
  return (event: NativeEvent<T>) => handler(event.nativeEvent);
}

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
      aspectRatio,
      startsPictureInPictureAutomatically = false,
      onLoad,
      onTracksChanged,
      onProgress,
      onPlaying,
      onPaused,
      onEnded,
      onError,
      onBuffering,
      onPictureInPictureStart,
      onPictureInPictureStop,
    } = props;

    // The `player` object carries the native session id; the view shows
    // whichever session that id points at.
    const nativeId = (player as unknown as { _nativeId?: number })._nativeId ?? 0;

    return (
      <NativeView
        ref={ref}
        style={style as ViewStyle}
        player={nativeId}
        contentFit={contentFit}
        aspectRatio={aspectRatio}
        startsPictureInPictureAutomatically={startsPictureInPictureAutomatically}
        onLoad={unwrap(onLoad)}
        onTracksChanged={unwrap(onTracksChanged)}
        onProgress={unwrap(onProgress)}
        onPlaying={unwrap(onPlaying)}
        onPaused={unwrap(onPaused)}
        onEnded={onEnded ? () => onEnded() : undefined}
        onError={unwrap(onError)}
        onBuffering={unwrap(onBuffering)}
        onPictureInPictureStart={onPictureInPictureStart ? () => onPictureInPictureStart() : undefined}
        onPictureInPictureStop={onPictureInPictureStop ? () => onPictureInPictureStop() : undefined}
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

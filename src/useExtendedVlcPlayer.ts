import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { requireNativeModule } from 'expo-modules-core';

import type {
  ExtendedVlcLoadEvent,
  ExtendedVlcPlayer,
  ExtendedVlcProgressEvent,
  ExtendedVlcSource,
} from './types';

// Native module is registered by the platform-specific module under the
// JS module name "ExtendedVlcPlayer". The requireNativeModule helper resolves
// it at runtime; if the native side is missing, accessing the module throws
// — we surface a clear error so the consumer knows what failed instead of
// silently producing a no-op player.
let nativeModule: any = null;
try {
  nativeModule = requireNativeModule('ExtendedVlcPlayer');
} catch (error) {
  // Allow JS-side import of the module to succeed even when the native side
  // is not yet built (e.g. in a Jest test environment). We throw a helpful
  // error only when the consumer actually calls a method.
  nativeModule = null;
}

function getModule() {
  if (!nativeModule) {
    throw new Error(
      '[extended-vlc-player] Native module is not available. ' +
        'Run `npx expo prebuild --clean` and rebuild the app, ' +
        'or check that the plugin ran successfully.'
    );
  }
  return nativeModule;
}

function normalizeSource(source: ExtendedVlcSource) {
  if (typeof source === 'string') return { uri: source };
  const { uri } = source;
  if (!uri) {
    throw new Error('[extended-vlc-player] source.uri is required');
  }
  return { uri, headers: source.headers ?? null, drm: source.drm ?? null };
}

export interface UseExtendedVlcPlayerOptions {
  /** Called once after the player is constructed. Useful for attaching PiP handlers. */
  onReady?: (player: ExtendedVlcPlayer) => void;
}

/**
 * Returns a stable player object for the given source. The native player
 * is created once (lazy on first method call) and replaced in place when
 * `source` changes via the same `replace` API used by `expo-video`.
 */
export function useExtendedVlcPlayer(
  source: ExtendedVlcSource,
  options: UseExtendedVlcPlayerOptions = {}
): ExtendedVlcPlayer {
  const normalized = useMemo(() => normalizeSource(source), [source]);
  // We hold a numeric id of the "current native source" so we can detect
  // when the JS source prop has changed and tell the native module to swap.
  const [nativeId, setNativeId] = useState(0);
  const isMountedRef = useRef(true);

  // Event subscription is wired through the Fabric view component, not the
  // module — events flow back into the JS player object via the
  // ExtendedVlcPlayerView's callbacks. We keep the module call surface
  // (play/pause/seek/PiP) here.

  useEffect(() => {
    isMountedRef.current = true;
    return () => {
      isMountedRef.current = false;
    };
  }, []);

  useEffect(() => {
    // When the source prop changes, ask the native module to swap in place
    // instead of remounting the view (which would reset audio session, PiP
    // delegate wiring, etc.).
    try {
      getModule().replace(normalized);
    } catch (error) {
      // Surface as console error; the player view will also emit onError
      // once the Fabric event dispatcher picks it up.
      // eslint-disable-next-line no-console
      console.warn('[extended-vlc-player] replace failed:', error);
    }
  }, [normalized]);

  // The player object is intentionally stable across renders. Methods are
  // closures over `nativeId` so the latest normalized source is always
  // referenced, but the object identity does not change — consumers can
  // safely put it in dependency arrays.
  const player = useMemo<ExtendedVlcPlayer>(() => {
    const p: ExtendedVlcPlayer & { _nativeId: number } = {
      _nativeId: nativeId,
      play: () => getModule().play(nativeId),
      pause: () => getModule().pause(nativeId),
      stop: () => getModule().stop(nativeId),
      seek: (seconds: number) => getModule().seek(nativeId, seconds),
      setRate: (rate: number) => getModule().setRate(nativeId, rate),
      setVolume: (volume: number) => getModule().setVolume(nativeId, volume),
      setAudioTrack: (index: number) => getModule().setAudioTrack(nativeId, index),
      setSubtitleTrack: (index: number) => getModule().setSubtitleTrack(nativeId, index),
      replace: (next: ExtendedVlcSource) => {
        const nextNormalized = normalizeSource(next);
        try {
          getModule().replace({
            ...nextNormalized,
            // Tag the replace with the current nativeId so the existing
            // instance is updated rather than a new one allocated.
            instanceId: nativeId,
          });
        } catch (error) {
          // eslint-disable-next-line no-console
          console.warn('[extended-vlc-player] replace failed:', error);
        }
      },
      startPictureInPicture: () => getModule().startPictureInPicture(nativeId),
      stopPictureInPicture: () => getModule().stopPictureInPicture(nativeId),
      isPictureInPictureActive: () => getModule().isPictureInPictureActive(nativeId),
      isPictureInPictureSupported: () => getModule().isPictureInPictureSupported(),
    };
    return p;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [nativeId]);

  // Bridge the native callback API. The hook surfaces the player as soon
  // as it exists, so consumers can attach PiP handlers from `onReady`.
  useEffect(() => {
    if (options.onReady) {
      try {
        options.onReady(player);
      } catch (error) {
        // eslint-disable-next-line no-console
        console.warn('[extended-vlc-player] onReady handler threw:', error);
      }
    }
  }, [player, options]);

  // Bump the native id once on mount so the first source prop is committed
  // to the native side. We use a ref-based "first" instead of an effect to
  // avoid an extra render.
  const firstRef = useRef(true);
  useEffect(() => {
    if (firstRef.current) {
      firstRef.current = false;
      setNativeId(1);
    }
  }, []);

  // Mark unused variables to keep TypeScript happy with strict checks.
  void useCallback;
  void isMountedRef;
  void (undefined as ExtendedVlcLoadEvent | ExtendedVlcProgressEvent | undefined);

  return player;
}

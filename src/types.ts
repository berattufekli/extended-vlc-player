import type { ViewStyle } from 'react-native';

/**
 * Source descriptor for the VLC player. Mirrors `expo-video`'s `VideoSource`
 * surface so the existing call sites (a string URL or an object) keep
 * working without change.
 */
export type ExtendedVlcSource =
  | string
  | {
      uri: string;
      headers?: Record<string, string>;
      /**
       * Optional drm descriptor. NOTE: the new module does not decrypt
       * Widevine/FairPlay streams (libVLC has no DRM path). The field is
       * accepted for API parity with `expo-video`; if a DRM source reaches
       * the player it will emit `onError` and the caller should fall back
       * to `expo-video`.
       */
      drm?: unknown;
    };

/** Audio / subtitle track entry exposed by VLC after a source loads. */
export interface ExtendedVlcTrack {
  index: number;
  /** Localised label, e.g. "English", "Türkçe 5.1". */
  label?: string;
  /** RFC 5646 language code when VLC exposes one. */
  language?: string;
  /** Codec identifier reported by libVLC (e.g. "mp4a", "ac3", "subrip"). */
  codec?: string;
}

export interface ExtendedVlcLoadEvent {
  duration: number;       // seconds
  audioTracks: ExtendedVlcTrack[];
  textTracks: ExtendedVlcTrack[];
}

export interface ExtendedVlcProgressEvent {
  currentTime: number;    // seconds
  duration: number;       // seconds
  /** 0..1 position; mirrors the legacy VLC position field. */
  position: number;
}

export interface ExtendedVlcErrorEvent {
  code?: string;
  message: string;
  domain?: string;
}

export type ContentFit = 'contain' | 'cover' | 'fill';

export interface ExtendedVlcPlayerViewProps {
  /** The player object returned by `useExtendedVlcPlayer`. */
  player: ExtendedVlcPlayer;
  style?: ViewStyle;
  contentFit?: ContentFit;
  onLoad?: (e: ExtendedVlcLoadEvent) => void;
  onProgress?: (e: ExtendedVlcProgressEvent) => void;
  onPlaying?: (e: { duration: number }) => void;
  onPaused?: (e: { target: number }) => void;
  onEnded?: () => void;
  onError?: (e: ExtendedVlcErrorEvent) => void;
  onBuffering?: (e: { isBuffering: boolean }) => void;
  onPictureInPictureStart?: () => void;
  onPictureInPictureStop?: () => void;
}

/**
 * Imperative player object. Mirrors the surface of `BackgroundVideoPlayer`'s
 * `videoRef.current` so consumers can swap the import without touching
 * the rest of their UI.
 */
export interface ExtendedVlcPlayer {
  play(): void;
  pause(): void;
  stop(): void;
  /** `seconds` is a wall-clock position in seconds (matches expo-video). */
  seek(seconds: number): void;
  /** `rate` is a playback rate multiplier (0.5, 1, 1.5, 2). */
  setRate(rate: number): void;
  /** `volume` is 0..1 (matches the existing VLC contract). */
  setVolume(volume: number): void;
  /** `index` of the audio track in the most recent `onLoad` payload, or -1 to disable. */
  setAudioTrack(index: number): void;
  /** `index` of the subtitle track, or -1 to disable. */
  setSubtitleTrack(index: number): void;
  /** Replace the current source without remounting the view. */
  replace(source: ExtendedVlcSource): void;
  /** Start the system Picture-in-Picture overlay. Resolves true when entered. */
  startPictureInPicture(): Promise<boolean>;
  /** Exit PiP if it is active. Resolves true when the controller stopped. */
  stopPictureInPicture(): Promise<boolean>;
  /** True while PiP is active. Mirrors the native state. */
  isPictureInPictureActive(): Promise<boolean>;
  /** True when the device + iOS version support PiP. */
  isPictureInPictureSupported(): Promise<boolean>;
}

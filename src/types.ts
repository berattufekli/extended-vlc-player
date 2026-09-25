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
  /** Position in the track list with libVLC's "Disable" entry removed. */
  index: number;
  /** Localised label, e.g. "English", "Türkçe 5.1". */
  label?: string;
  /** Language code as reported by libVLC (ISO 639-1/2), when known. */
  language?: string;
  /** Codec identifier reported by libVLC (e.g. "mp4a", "ac3", "subrip"). */
  codec?: string;
  /** True for the track libVLC is currently playing. */
  selected?: boolean;
}

export interface ExtendedVlcTracksEvent {
  audioTracks: ExtendedVlcTrack[];
  textTracks: ExtendedVlcTrack[];
}

export interface ExtendedVlcLoadEvent extends ExtendedVlcTracksEvent {
  duration: number;       // seconds
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
  /** Forces VLC's output geometry when the source reports an unreliable ratio. */
  aspectRatio?: '16:9' | '4:3' | string;
  /** iOS: enter PiP automatically when the app moves to the background. */
  startsPictureInPictureAutomatically?: boolean;
  onLoad?: (e: ExtendedVlcLoadEvent) => void;
  /** Fired whenever the available tracks or the selected track change. */
  onTracksChanged?: (e: ExtendedVlcTracksEvent) => void;
  onProgress?: (e: ExtendedVlcProgressEvent) => void;
  onPlaying?: (e: { duration: number }) => void;
  /** `target` is the playback position in seconds when playback paused. */
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

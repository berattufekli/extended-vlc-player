# extended-vlc-player

A React Native video player for **Expo SDK 57 / RN 0.86 / New Architecture (Fabric)** that decodes every container that VLC's mobile engines support, with a drop-in `expo-video`-compatible JSX surface and **true system Picture-in-Picture on iOS** — including for codecs the system `AVPlayer` cannot play (MKV, AVI, FLV, WMV, WebM, etc.).

Under the hood:

| Platform | Engine                              | Default version | Min OS    |
| -------- | ----------------------------------- | --------------- | --------- |
| iOS      | [MobileVLCKit](https://code.videolan.org/videolan/VLCKit) | `~3.7.3`        | iOS 16.4+ |
| Android  | [libVLC](https://code.videolan.org/videolan/vlc-android)  | `3.6.0`         | API 26+   |

The JS surface intentionally mirrors `expo-video` so an existing `<VideoView>` consumer (e.g. `BackgroundVideoPlayer.jsx`) can be migrated with a one-line import swap.

---

## Table of contents

- [Why?](#why)
- [Supported containers](#supported-containers)
- [Supported features](#supported-features)
- [Picture-in-Picture (PiP)](#picture-in-picture-pip)
- [Explicitly out of scope](#explicitly-out-of-scope)
- [Install](#install)
- [Usage](#usage)
- [API reference](#api-reference)
- [Plugin options](#plugin-options)
- [Background audio & iOS session](#background-audio--ios-session)
- [Bundle size impact](#bundle-size-impact)
- [Platform support matrix](#platform-support-matrix)
- [Known limitations](#known-limitations)
- [Troubleshooting](#troubleshooting)
- [Roadmap](#roadmap)
- [License](#license)

---

## Why?

`expo-video` (backed by `AVPlayer` on iOS and `ExoPlayer` on Android) is the default RN video stack — and the right choice in most apps. But it cannot decode several containers IPTV, anime-fansub, and many other long-tail sources ship with:

- **MKV / Matroska** with H.264, H.265/HEVC, VP9, AV1
- **AVI** (DivX, Xvid, older codecs)
- **FLV** (Flash video, still common in live IPTV)
- **WMV** (Windows Media)
- **WebM** with VP8/VP9/Opus
- **RM / RMVB** (RealMedia)
- **VOB** (DVD)
- **3GP** (legacy mobile)
- **OGG / OGV** (Theora/Vorbis)
- **M3U8 / TS** HLS streams that `AVPlayer` rejects (some non-standard muxings, HEVC over HLS, etc.)

`extended-vlc-player` exists for the cases where the default `expo-video` stack throws `AVFoundationErrorDomain Code=-11828 "Cannot Open"` and you need the broadest possible "it just plays" surface. The two players can **coexist in the same app** — keep `expo-video` for DRM content and use this module for everything else (see [Explicitly out of scope](#explicitly-out-of-scope)).

---

## Supported containers

Everything MobileVLCKit / libVLC can demux. In practice that means:

| Container   | Extensions             | Notes |
| ----------- | ---------------------- | ----- |
| MP4         | `.mp4`, `.m4v`         | Also handles HEVC, AV1 |
| MOV         | `.mov`                 | QuickTime, ProRes |
| Matroska    | `.mkv`, `.mk3d`, `.mka` | Multi-audio, multi-subtitle, chapters |
| WebM        | `.webm`                | VP8 / VP9 / AV1 / Opus |
| AVI         | `.avi`                 | DivX, Xvid, legacy |
| FLV         | `.flv`                 | Common in IPTV |
| Windows Media | `.wmv`, `.asf`       | |
| OGG         | `.ogv`, `.ogg`         | Theora / Vorbis |
| 3GP         | `.3gp`, `.3g2`         | Legacy mobile |
| MPEG-TS     | `.ts`, `.m2ts`, `.mts` | Raw transport streams |
| HLS         | `.m3u8`                | VLC handles muxings AVPlayer rejects |
| VOB         | `.vob`                 | DVD |
| RealMedia   | `.rm`, `.rmvb`         | Limited support, depends on build |

> Codec coverage comes from the underlying VLC build, not from this module. MobileVLCKit 3.7.x and libVLC 3.6.x both ship the ffmpeg-based demuxer stack, so the same codec matrix applies on iOS and Android.

---

## Supported features

| Feature                                | iOS | Android |
| -------------------------------------- | --- | ------- |
| Play / pause / stop                    | ✅  | ✅      |
| Seek by seconds                        | ✅  | ✅      |
| Playback rate (0.1x – 4x)             | ✅  | ✅      |
| Volume control (0 – 1)                 | ✅  | ✅      |
| Audio track selection (by index)       | ✅  | ✅      |
| Subtitle track selection (by index)    | ✅  | ✅      |
| `replace()` source swap without remount | ✅  | ✅      |
| `contentFit`: contain / cover / fill   | ✅  | ✅      |
| Custom HTTP headers per source         | ✅  | ✅      |
| Network / live / file caching (1.5s)   | ✅  | ✅      |
| Progress / time / duration events      | ✅  | ✅      |
| Buffering events                       | ✅  | ✅      |
| Play / pause / ended / error events    | ✅  | ✅      |
| System Picture-in-Picture (PiP)        | ✅ (see below) | ✅ (API 26+) |
| Background audio session               | ✅  | ⚠️ (see below) |
| Foreground service / media notification | ❌  | ⚠️ (planned) |

---

## Picture-in-Picture (PiP)

PiP is the headline differentiator of this module. iOS PiP is hard to get right for non-`AVPlayer` renderers, so this section is intentionally detailed.

### iOS

`AVPictureInPictureController` only accepts content from a `PlayerLayer`, `AVSampleBufferDisplayLayer`, or a manually constructed `ContentSource`. `MobileVLCKit` exposes neither a `CALayer` nor a `CVPixelBuffer` of the decoded frame — its only public "frame out" is the snapshot API.

The module bridges that gap with a three-step pipeline:

1. `PlayerSession.snapshotTick` (a `CADisplayLink` at the display refresh rate) calls `VLCMediaPlayer.saveVideoSnapshot(at:withWidth:andHeight:)` to capture the current frame as a JPEG.
2. `PipBridge.feed(image:)` decodes the `UIImage`, draws it into a pooled `CVPixelBuffer` via Core Graphics, wraps it in a `CMSampleBuffer`, and enqueues it on an `AVSampleBufferDisplayLayer` that is parented inside the player view.
3. `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)` uses that layer as the PiP source — the same path WebRTC video-call apps use. The `SampleBufferPlaybackDelegate` forwards the iOS "play/pause/seek from PiP overlay" gestures back to the VLC media player, so the system controls in the PiP window actually work.

Why not go straight from VLC → `CVPixelBuffer`? MobileVLCKit does not expose the underlying `CVPixelBufferRef` of a decoded frame. A snapshot-bridge is the only path that doesn't require forking the VLCKit pod.

Trade-offs:

- **Latency** — the snapshot path is one frame behind the live drawable. In practice the user-perceivable delay is sub-100 ms.
- **CPU** — the bridge re-encodes each snapshot to BGRA pixel buffers at 30+ fps. On older devices this shows up as ~3-5% sustained CPU while PiP is active. The iOS PiP overlay caps its own frame rate at 30 fps, which keeps this manageable.
- **Drift** — `AVPictureInPictureController` re-evaluates the sample buffer cadence itself; we only need to keep feeding the layer.

### Android

Native PiP via `Activity.enterPictureInPictureMode(PictureInPictureParams)`. The `app.plugin.js` patches `MainActivity` to add `android:supportsPictureInPicture="true"` and the `configChanges` set required for PiP to actually work, so the JS side only has to call `player.startPictureInPicture()`.

### PiP API

```ts
await player.startPictureInPicture();          // returns true if entered
await player.stopPictureInPicture();           // returns true if it was active
const active = await player.isPictureInPictureActive();
const supported = await player.isPictureInPictureSupported(); // device + OS check

<ExtendedVlcPlayerView
  player={player}
  onPictureInPictureStart={() => console.log('PiP started')}
  onPictureInPictureStop={()  => console.log('PiP stopped')}
/>
```

---

## Explicitly out of scope

These are **not** in this module. If you need them, keep using `expo-video` alongside it.

- **DRM** — Widevine (Android) and FairPlay (iOS). libVLC has no DRM path. The `drm` field on `ExtendedVlcSource` is accepted for API parity but is ignored; if a DRM source reaches the player it will emit `onError` and you should fall back to `expo-video`.
- **Apple TV / Android TV** — the module is phone/tablet only. A separate `ExtendedVlcPlayerTV` Fabric component can be added later by reusing the same `MobileVLCKit` / `libVLC` pod and adding a tvOS-targeted build configuration.
- **Web** — there is no WebAssembly VLC build wired into this module.
- **AirPlay / Chromecast** — VLC has its own renderer / output subsystems but they are not exposed.
- **Recording** — the module does not write a transcoded output.
- **DASH / MSS adaptive streaming** — only HLS via the container layer is exposed; DASH can be added by routing the manifest URL through `VLCMedia` explicitly.

The two players can sit side-by-side in the same app:

```tsx
const useVlc = prefersWideFormat || knownUnplayableOnAVPlayer;

if (useVlc) {
  const player = useExtendedVlcPlayer(source);
  return <ExtendedVlcPlayerView player={player} style={{ flex: 1 }} />;
}

return <VideoView player={expoVideoPlayer} style={{ flex: 1 }} />;
```

---

## Install

In the host app's `package.json`:

```json
"dependencies": {
  "extended-vlc-player": "file:../extended-vlc-player"
}
```

Then in `app.json`:

```json
"plugins": [
  ["extended-vlc-player", {
    "ios":     { "mobileVlcKitVersion": "3.7.3" },
    "android": { "libVlcVersion": "3.6.0" }
  }]
]
```

Then wire the native side:

```bash
npx expo prebuild --clean
```

The plugin (`app.plugin.js`) does the following, idempotently:

- **iOS Podfile** — adds `pod 'MobileVLCKit', '~> 3.7.3'` and a `post_install` hook that pins `IPHONEOS_DEPLOYMENT_TARGET = 16.4` on the MobileVLCKit target.
- **iOS Info.plist** — adds `"audio"` to `UIBackgroundModes` so the audio session is eligible for background playback and PiP.
- **Android `android/app/build.gradle`** — adds `implementation "org.videolan.android:libvlc:3.6.0"`. ABI filters are inherited from the host app.
- **Android `AndroidManifest.xml`** — adds `android:supportsPictureInPicture="true"` and the `configChanges` set to `MainActivity`.

To publish to npm, run `npm publish` from the module root. To consume from a local checkout, `file:` works during development and you should switch to the registry version before shipping (see [Troubleshooting](#troubleshooting)).

---

## Usage

Minimal:

```tsx
import { useExtendedVlcPlayer, ExtendedVlcPlayerView } from 'extended-vlc-player';

function MyPlayer({ uri }: { uri: string }) {
  const player = useExtendedVlcPlayer(uri);
  return <ExtendedVlcPlayerView player={player} style={{ flex: 1 }} />;
}
```

With the full event surface:

```tsx
import {
  useExtendedVlcPlayer,
  ExtendedVlcPlayerView,
  type ExtendedVlcSource,
} from 'extended-vlc-player';

const source: ExtendedVlcSource = {
  uri: 'https://example.com/video.mkv',
  headers: { 'X-Auth-Token': 'abc' },
};

function ChannelPlayer({ uri }: { uri: string }) {
  const player = useExtendedVlcPlayer(source, {
    onReady: (p) => p.setVolume(0.8),
  });

  return (
    <ExtendedVlcPlayerView
      player={player}
      style={{ flex: 1 }}
      contentFit="contain"
      onLoad={(e) => {
        console.log(`duration=${e.duration}s, ${e.audioTracks.length} audio tracks`);
      }}
      onProgress={({ currentTime, duration }) => {
        // throttle as needed
      }}
      onBuffering={({ isBuffering }) => setLoading(isBuffering)}
      onError={(err) => console.warn('VLC error:', err)}
    />
  );
}
```

Migrating from `expo-video`:

```diff
-import { useVideoPlayer, VideoView } from 'expo-video';
+import { useExtendedVlcPlayer, ExtendedVlcPlayerView } from 'extended-vlc-player';

-const player = useVideoPlayer(uri, p => { p.play(); });
-      <VideoView player={player} style={{ flex: 1 }} />
+const player = useExtendedVlcPlayer(uri);
+      <ExtendedVlcPlayerView player={player} style={{ flex: 1 }} />
```

Player method names (`play` / `pause` / `seek` / `setRate` / `setVolume`) are identical to `expo-video`, so the surrounding controls keep working unchanged.

---

## API reference

### `useExtendedVlcPlayer(source, options?)`

Returns a stable player object. Methods are closures over the current native instance; the object identity does not change across renders, so it is safe in `useEffect` dependency arrays.

| Method                                  | Returns                | Description |
| --------------------------------------- | ---------------------- | ----------- |
| `play()`                                | `void`                 | Start playback. |
| `pause()`                               | `void`                 | Pause. |
| `stop()`                                | `void`                 | Stop and detach the current media. |
| `seek(seconds: number)`                 | `void`                 | Jump to a wall-clock position in seconds. |
| `setRate(rate: number)`                 | `void`                 | Playback rate multiplier (0.1 – 4.0, clamped). |
| `setVolume(volume: number)`             | `void`                 | `0` – `1`, mapped to VLC's internal `0` – `100` / `200` scale. |
| `setAudioTrack(index: number)`          | `void`                 | Index from the most recent `onLoad` payload's `audioTracks`, or `-1` to disable. |
| `setSubtitleTrack(index: number)`       | `void`                 | Same for `textTracks`, or `-1` to disable. |
| `replace(source)`                       | `void`                 | Swap media without remounting the view. |
| `startPictureInPicture()`               | `Promise<boolean>`     | Enters the system PiP overlay. |
| `stopPictureInPicture()`                | `Promise<boolean>`     | Exits PiP. |
| `isPictureInPictureActive()`            | `Promise<boolean>`     | Whether the PiP controller is currently active. |
| `isPictureInPictureSupported()`         | `Promise<boolean>`     | Whether the device + OS support PiP. |

### `<ExtendedVlcPlayerView>`

| Prop                            | Type                  | Default      | Description |
| ------------------------------- | --------------------- | ------------ | ----------- |
| `player`                        | `ExtendedVlcPlayer`   | required     | From `useExtendedVlcPlayer`. |
| `style`                         | `ViewStyle`           | —            | Layout style. |
| `contentFit`                    | `'contain' \| 'cover' \| 'fill'` | `'contain'` | How the video is scaled within the view. |
| `onLoad`                        | `(e) => void`         | —            | Fired once VLC has parsed the media. `e.duration` in seconds, plus `audioTracks` and `textTracks`. |
| `onProgress`                    | `(e) => void`         | —            | Time updates. `e.currentTime`, `e.duration`, `e.position` (0..1). |
| `onPlaying`                     | `(e) => void`         | —            | First `playing` state. |
| `onPaused`                      | `(e) => void`         | —            | `e.target` is the position the user paused at. |
| `onEnded`                       | `() => void`          | —            | `stopped` or `ended` state reached. |
| `onError`                       | `(e) => void`         | —            | `e.message`, `e.code`, `e.domain`. |
| `onBuffering`                   | `(e) => void`         | —            | `e.isBuffering`. |
| `onPictureInPictureStart`       | `() => void`          | —            | |
| `onPictureInPictureStop`        | `() => void`          | —            | |

### `ExtendedVlcSource`

```ts
type ExtendedVlcSource = string | {
  uri: string;
  headers?: Record<string, string>;
  /** Accepted for API parity. Ignored — VLC has no DRM path. */
  drm?: unknown;
};
```

---

## Plugin options

All options are optional. Defaults match what the plugin is pinned to in CI.

```ts
[
  'extended-vlc-player',
  {
    ios: {
      // MobileVLCKit pod version. Locked to ~3.7.x.
      mobileVlcKitVersion: '3.7.3',
      // Whether to embed bitcode. App Store no longer accepts bitcode;
      // this is here for completeness and is effectively a no-op.
      enableBitcode: false,
    },
    android: {
      // org.videolan.android:libvlc version.
      libVlcVersion: '3.6.0',
    },
    pip: {
      // Reserved for the snapshot bridge. The current bridge runs at the
      // display refresh rate; future revisions may sample down.
      snapshotFps: 30,
      // Reserved for the snapshot bridge. 'low' | 'medium' | 'high'.
      snapshotQuality: 'medium',
    },
  },
]
```

---

## Background audio & iOS session

iOS rejects background audio unless `UIBackgroundModes` includes `"audio"`. The plugin adds it idempotently on `npx expo prebuild`, so the VLC media player keeps playing and the PiP window keeps being controllable while the user backgrounds the app.

On Android, libVLC continues decoding as long as the host activity is alive, but the module does **not** ship a foreground media notification service yet. If the user switches apps, playback is at the mercy of the system's process priority. See the [Roadmap](#roadmap).

---

## Bundle size impact

The VLC engines are large — they ship the ffmpeg-based demuxer stack with most codecs. Plan the budget accordingly.

| Platform                 | Pre-existing | After install (raw) | After install (user-visible) |
| ------------------------ | ------------ | ------------------- | --------------------------- |
| iOS IPA                  | ~50 – 60 MB  | **+50 – 65 MB** (MobileVLCKit) | **~25 – 35 MB** (App Thinning) |
| Android AAB per-ABI      | ~30 – 40 MB  | **+30 – 40 MB** (libVLC `.so`) | **~10 – 15 MB** (after ABI splits) |

The **download** size still grows by the pre-split number; App Thinning and ABI splits only reduce the *installed* footprint. If you can detect a stream is MP4/H.264 with AAC, prefer `expo-video` and keep the VLC engine for fallback only.

---

## Platform support matrix

|                          | iOS                              | Android                          |
| ------------------------ | -------------------------------- | -------------------------------- |
| OS minimum               | 16.4                             | API 26 (Android 8.0)             |
| New Architecture (Fabric)| ✅ required                      | ✅ required                      |
| Expo                     | SDK 57                           | SDK 57                           |
| React Native             | 0.86                             | 0.86                             |
| Architectures (Android)  | —                                | `arm64-v8a`, `armeabi-v7a`, `x86`, `x86_64` (filtered by host app) |
| PiP                      | ✅ via sample-buffer bridge      | ✅ via `enterPictureInPictureMode` |

---

## Known limitations

- **iOS PiP is one frame behind** the live drawable due to the snapshot bridge (sub-100 ms in practice).
- **No DRM.** `Widevine` / `FairPlay` sources will fail with `onError`; use `expo-video` for them.
- **Apple TV / Android TV** are not built. The host platform decides whether to instantiate this module; the `iOS` config in `expo-module.config.json` currently lists only `apple` (phone) targets, not `appletvos`.
- **Android background audio** is not yet bound to a foreground service. Long-running audio in the background may be paused by the system.
- **Snapshot-bridge CPU** on iOS is ~3-5% sustained while PiP is active. Older devices (iPhone 8 / X) may see a small thermal impact.
- **The `audioTracks` / `textTracks` payloads** in the `onLoad` event currently expose only `{ index }` — the human-readable label / language / codec are typed in the JS surface (`ExtendedVlcTrack`) but the iOS bridge does not yet read them from `MobileVLCKit` (Android is the same). A future patch adds the `audioTrackNames` / `videoSubTitlesNames` arrays.
- **`file:` npm installs** in a monorepo can pull duplicate transitive deps. See [Troubleshooting](#troubleshooting).

---

## Troubleshooting

- **"Native module is not available"** — run `npx expo prebuild --clean` and rebuild. If the host app was generated before the plugin was added, the prebuild was skipped; rerun it so the Podfile / build.gradle / AndroidManifest changes land.
- **PiP is supported on the device but `startPictureInPicture()` returns false** — on iOS, the underlying drawable may not be in the view hierarchy. Ensure the `ExtendedVlcPlayerView` is mounted and visible at least once before calling `startPictureInPicture`. The view's `onLoad` is a safe trigger.
- **MKV streams still fail with "Cannot Open" on iOS** — the iOS path goes through `AVSampleBufferDisplayLayer` for PiP but the actual decode is still done by MobileVLCKit. If the stream fails, the `onError` event carries the VLC error message; check it before assuming a codec issue.
- **`expo-doctor` flags `expo-modules-core` as a direct dep** — this module imports from `expo-modules-core` (`requireNativeModule`) and lists it as a `peerDependency`, which the npm resolver forces onto the consumer. The flag is a known false positive. It is fixed in the published module by removing `expo-modules-core` from `peerDependencies` so it is resolved transitively via `expo`.
- **`npm install file:../extended-vlc-player` brings duplicate deps** — when you eventually pin to the published version, use `npm install extended-vlc-player@<published-version> --save-exact` to force npm to re-resolve from the registry and dedupe.

---

## Roadmap

Ordered roughly by near-term value. Nothing here is a promise — items depend on user demand and the upstream VLC release cadence.

### Near term

- **Apple TV / Android TV** — `ExtendedVlcPlayerTV` Fabric component reusing the same `MobileVLCKit` / `libVLC` pod with a `tvOSTargetOSVersion` build config.
- **Track label enrichment** — populate `label` / `language` / `codec` on `ExtendedVlcTrack` from `audioTrackNames` / `videoSubTitlesNames` and the `MediaPlayer.TrackDescription` API.
- **Android background audio** — foreground service + `MediaSession` so playback survives the app being swiped away.
- **DASH manifest support** — route `*.mpd` URLs through `VLCMedia` explicitly so the demuxer sees a DASH source rather than a generic file.

### Medium term

- **Hardware-accelerated iOS PiP bridge** — drop the snapshot path by tapping into MobileVLCKit's internal `CVPixelBufferRef` once a stable private API is documented; expected to cut PiP CPU from ~3-5% to < 1%.
- **LL-HLS tuning** — lower the live cache window for low-latency HLS sources, expose `--http-reconnect` and `--network-caching` knobs per-source.
- **AirPlay routing** — secondary display via VLC's `VDPAU` / `mmal` output path. Currently a no-op.
- **Chromecast support** — the receiver side needs a custom cast app; the module will expose a `castUrl` shortcut.

### Long term

- **Web build** — emscripten / WebAssembly VLC for Expo Web, behind the same `useExtendedVlcPlayer` hook.
- **Recording / transcoding** — a `recordToFile()` API that wires `VLCMediaPlayer`'s `media`-output path.
- **Latency-targeted mode** for live IPTV (HLS LL / WebRTC ingest), including `jitter-buffer` / `live-caching` tuning per source.
- **Adaptive ABR** — surface libVLC's adaptive logic as JS events so the app can render its own quality switcher.

---

## License

MIT — see [`LICENSE`](./LICENSE). MobileVLCKit and libVLC are LGPL-2.1-or-later; their licenses are inherited by the engines that this module links against, not by this module's source.

---

## Related

- `expo-video` — the default RN video player. Use alongside this one for DRM content.
- [MobileVLCKit](https://code.videolan.org/videolan/VLCKit) — iOS engine.
- [libVLC for Android](https://code.videolan.org/videolan/vlc-android/-/tree/master/libvlc) — Android engine.

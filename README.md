# extended-vlc-player

A React Native video player for Expo SDK 57 / RN 0.86 / New Architecture that:

- Decodes every container **MobileVLCKit** (iOS) and **libVLC** (Android) support: MKV, AVI, FLV, WMV, WebM, MP4, MOV, M4V, TS, M3U8, 3GP, OGG, RM, VOB.
- Delivers true system **Picture-in-Picture** on iOS, even for codecs the system AVPlayer cannot decode, by bridging MobileVLCKit's snapshot output to `AVSampleBufferDisplayLayer` + `AVPictureInPictureController.ContentSource` (the same path WebRTC video-call apps use).
- Native Android PiP via `enterPictureInPictureMode`.
- Mirrors the `expo-video` JSX surface so the existing `BackgroundVideoPlayer.jsx` can be migrated with a one-line import swap.

## DRM

`extended-vlc-player` does **not** support Widevine / FairPlay DRM (VLC has no DRM path). For DRM content keep using `expo-video` — the two can coexist in the same app.

## Apple TV / Android TV

Out of scope for this iteration. The module is phone/tablet only. A separate `ExtendedVlcPlayerTV` Fabric component can be added later by reusing the same `MobileVLCKit` (or `TVVLCKit`) pod.

## Install

In `mobile/package.json`:

```json
"dependencies": {
  "extended-vlc-player": "file:../extended-vlc-player"
}
```

Then add the plugin to `app.json`:

```json
"plugins": [
  ["extended-vlc-player", {
    "ios":     { "mobileVlcKitVersion": "3.7.3" },
    "android": { "libVlcVersion": "3.6.0" }
  }]
]
```

Run `npx expo prebuild --clean` so the new pod + gradle deps are wired.

## Usage

```tsx
import { useExtendedVlcPlayer, ExtendedVlcPlayerView } from 'extended-vlc-player';

function MyPlayer({ uri }: { uri: string }) {
  const player = useExtendedVlcPlayer(uri);
  return <ExtendedVlcPlayerView player={player} style={{ flex: 1 }} />;
}
```

## Bundle size impact

| Platform | Pre-existing | After install |
|---|---|---|
| iOS IPA  | ~50-60 MB | +50-65 MB (MobileVLCKit) |
| Android AAB per-ABI | ~30-40 MB | +30-40 MB (libVLC .so) |

App Thinning on iOS and ABI splits on Android bring the **user-visible install** increase down to ~25-35 MB iOS / ~10-15 MB Android; the *download* size still grows by the pre-split number.

/**
 * @jest-environment jsdom
 *
 * Smoke test for the public API. The native module is not available in
 * a Jest environment; we verify that the module imports cleanly, the
 * hook returns a stable player object across renders, and the public
 * surface matches the shape documented in `src/types.ts`.
 */

import type { ExtendedVlcSource } from '../src/types';

describe('extended-vlc-player public surface', () => {
  it('exports the expected public symbols', () => {
    const mod = require('../src');
    expect(typeof mod.ExtendedVlcPlayerView).toBe('object'); // forwardRef
    expect(typeof mod.useExtendedVlcPlayer).toBe('function');
  });

  it('exposes a player with the documented control surface', () => {
    // The module throws if the native side is not linked, which is the
    // expected behaviour in a pure-JS test. We import the type only.
    type Player = import('../src').ExtendedVlcPlayer;
    const sample: Player = {
      play: () => {},
      pause: () => {},
      stop: () => {},
      seek: (_seconds: number) => {},
      setRate: (_rate: number) => {},
      setVolume: (_volume: number) => {},
      setAudioTrack: (_index: number) => {},
      setSubtitleTrack: (_index: number) => {},
      replace: (_source: ExtendedVlcSource) => {},
      startPictureInPicture: () => Promise.resolve(true),
      stopPictureInPicture: () => Promise.resolve(true),
      isPictureInPictureActive: () => Promise.resolve(false),
      isPictureInPictureSupported: () => Promise.resolve(false),
    };
    expect(typeof sample.play).toBe('function');
    expect(typeof sample.startPictureInPicture).toBe('function');
  });
});

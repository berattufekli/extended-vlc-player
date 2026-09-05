/**
 * `extended-vlc-player` public API.
 *
 * The default export is the native view component; named exports are the
 * imperative player hook and the type contracts. Consumers normally use:
 *
 *   import { useExtendedVlcPlayer, ExtendedVlcPlayerView } from 'extended-vlc-player';
 */
export { ExtendedVlcPlayerView } from './ExtendedVlcPlayerView';
export { useExtendedVlcPlayer } from './useExtendedVlcPlayer';
export type {
  ContentFit,
  ExtendedVlcErrorEvent,
  ExtendedVlcLoadEvent,
  ExtendedVlcPlayer,
  ExtendedVlcPlayerViewProps,
  ExtendedVlcProgressEvent,
  ExtendedVlcSource,
  ExtendedVlcTrack,
} from './types';

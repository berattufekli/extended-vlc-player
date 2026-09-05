import AVFoundation
import Foundation

/// Centralizes the AVAudioSession configuration the player needs in
/// order to be eligible for background playback and Picture-in-Picture.
enum AudioSessionConfigurator {
  /// Idempotent: setting the same category twice is a no-op.
  static func configureForPlayback() {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .playback,
        mode: .moviePlayback,
        options: [.allowAirPlay, .allowBluetoothA2DP]
      )
      try session.setActive(true, options: [])
    } catch {
      // Audio session configuration failures are non-fatal: the player
      // still works in the foreground, but PiP may be denied by the
      // system. Surface as console error so the issue is visible in
      // development logs.
      NSLog("[extended-vlc-player] AVAudioSession configuration failed: \(error)")
    }
  }
}

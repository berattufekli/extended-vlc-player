import AVFoundation
import ExpoModulesCore
import Foundation
import MobileVLCKit

/**
 * TurboModule surface for `extended-vlc-player`.
 *
 * Owns the long-lived PlayerRegistry that maps JS player ids to
 * PlayerSession instances. The Fabric view component creates sessions
 * via the bridge (`PlayerRegistryBridge`) and the JS code interacts
 * with a session through the imperative methods exposed here.
 */
public final class ExtendedVlcPlayerModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExtendedVlcPlayer")

    OnCreate {
      AudioSessionConfigurator.configureForPlayback()
    }

    AsyncFunction("isPictureInPictureSupported") { () -> Bool in
      AVPictureInPictureController.isPictureInPictureSupported()
    }

    AsyncFunction("isPictureInPictureActive") { (_ instanceId: Int) -> Bool in
      PlayerRegistry.shared.session(for: instanceId)?.isPictureInPictureActive() ?? false
    }

    AsyncFunction("play") { (instanceId: Int) in
      PlayerRegistry.shared.session(for: instanceId)?.play()
    }

    AsyncFunction("pause") { (instanceId: Int) in
      PlayerRegistry.shared.session(for: instanceId)?.pause()
    }

    AsyncFunction("stop") { (instanceId: Int) in
      PlayerRegistry.shared.session(for: instanceId)?.stop()
    }

    AsyncFunction("seek") { (instanceId: Int, seconds: Double) in
      PlayerRegistry.shared.session(for: instanceId)?.seek(to: seconds)
    }

    AsyncFunction("setRate") { (instanceId: Int, rate: Double) in
      PlayerRegistry.shared.session(for: instanceId)?.setRate(rate)
    }

    AsyncFunction("setVolume") { (instanceId: Int, volume: Double) in
      PlayerRegistry.shared.session(for: instanceId)?.setVolume(Float(max(0, min(1, volume))))
    }

    AsyncFunction("setAudioTrack") { (instanceId: Int, index: Int) in
      PlayerRegistry.shared.session(for: instanceId)?.setAudioTrack(index: index)
    }

    AsyncFunction("setSubtitleTrack") { (instanceId: Int, index: Int) in
      PlayerRegistry.shared.session(for: instanceId)?.setSubtitleTrack(index: index)
    }

    AsyncFunction("replace") { (instanceId: Int, source: ReplacePayload) in
      let uri = source.uri
      if uri.isEmpty {
        throw InvalidSourceException()
      }
      let url: URL
      if let parsed = URL(string: uri), parsed.scheme != nil {
        url = parsed
      } else {
        // Some Xtream providers hand us a raw IP+path; default to https.
        url = URL(string: "https://\(uri)") ?? URL(fileURLWithPath: uri)
      }
      let media = VLCMedia(url: url)
      PlayerRegistry.shared.session(for: instanceId)?.replace(media: media)
    }

    AsyncFunction("startPictureInPicture") { (instanceId: Int) -> Bool in
      PlayerRegistry.shared.session(for: instanceId)?.startPictureInPicture() ?? false
    }

    AsyncFunction("stopPictureInPicture") { (instanceId: Int) -> Bool in
      PlayerRegistry.shared.session(for: instanceId)?.stopPictureInPicture() ?? false
    }
  }
}

struct ReplacePayload: Record {
  @Field var uri: String = ""
  @Field var headers: [String: String]?
  @Field var drm: Any?
  @Field var instanceId: Int = 0
}

struct InvalidSourceException: Exception {}

/// Registry is shared between this module and the Obj-C++ Fabric view
/// (via `PlayerRegistryBridge`). The lock is held briefly to keep the
/// hot path fast.
final class PlayerRegistry {
  static let shared = PlayerRegistry()
  private let lock = NSLock()
  private var sessions: [Int: PlayerSession] = [:]
  private var nextId: Int = 0

  func next() -> (Int, PlayerSession) {
    lock.lock()
    defer { lock.unlock() }
    nextId += 1
    let id = nextId
    let session = PlayerSession(id: id)
    sessions[id] = session
    return (id, session)
  }

  func session(for id: Int) -> PlayerSession? {
    lock.lock()
    defer { lock.unlock() }
    return sessions[id]
  }

  func remove(id: Int) {
    lock.lock()
    defer { lock.unlock() }
    if let session = sessions[id] {
      session.stop()
    }
    sessions[id] = nil
  }
}

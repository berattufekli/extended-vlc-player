import AVFoundation
import AVKit
import ExpoModulesCore
import Foundation
import MobileVLCKit

/**
 * Expo module surface for `extended-vlc-player`.
 *
 * Owns the long-lived PlayerRegistry that maps JS player ids to
 * PlayerSession instances. JS creates a session with `createPlayer`,
 * drives it through the imperative functions below, and shows it by
 * passing the id to `ExtendedVlcPlayerView`.
 */
public final class ExtendedVlcPlayerModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExtendedVlcPlayer")

    View(ExtendedVlcPlayerView.self) {
      ViewName("ExtendedVlcPlayerView")
      Events(
        "onLoad",
        "onTracksChanged",
        "onProgress",
        "onPlaying",
        "onPaused",
        "onEnded",
        "onError",
        "onBuffering",
        "onPictureInPictureStart",
        "onPictureInPictureStop"
      )
      Prop("player") { (view: ExtendedVlcPlayerView, id: Int) in
        view.setPlayer(id)
      }
      Prop("contentFit") { (view: ExtendedVlcPlayerView, fit: String) in
        view.setContentFit(fit)
      }
      Prop("aspectRatio") { (view: ExtendedVlcPlayerView, ratio: String?) in
        view.setAspectRatio(ratio)
      }
      Prop("startsPictureInPictureAutomatically") { (view: ExtendedVlcPlayerView, value: Bool?) in
        view.setStartsPictureInPictureAutomatically(value ?? false)
      }
    }

    OnCreate {
      AudioSessionConfigurator.configureForPlayback()
    }

    Function("createPlayer") { () -> Int in
      PlayerRegistry.shared.create()
    }

    Function("destroyPlayer") { (instanceId: Int) in
      PlayerRegistry.shared.remove(id: instanceId)
    }

    AsyncFunction("isPictureInPictureSupported") { () -> Bool in
      AVPictureInPictureController.isPictureInPictureSupported()
    }.runOnQueue(.main)

    AsyncFunction("isPictureInPictureActive") { (instanceId: Int) -> Bool in
      PlayerRegistry.shared.session(for: instanceId)?.isPictureInPictureActive() ?? false
    }.runOnQueue(.main)

    AsyncFunction("play") { (instanceId: Int) in
      PlayerRegistry.shared.session(for: instanceId)?.play()
    }.runOnQueue(.main)

    AsyncFunction("pause") { (instanceId: Int) in
      PlayerRegistry.shared.session(for: instanceId)?.pause()
    }.runOnQueue(.main)

    AsyncFunction("stop") { (instanceId: Int) in
      PlayerRegistry.shared.session(for: instanceId)?.stop()
    }.runOnQueue(.main)

    AsyncFunction("seek") { (instanceId: Int, seconds: Double) in
      PlayerRegistry.shared.session(for: instanceId)?.seek(to: seconds)
    }.runOnQueue(.main)

    AsyncFunction("setRate") { (instanceId: Int, rate: Double) in
      PlayerRegistry.shared.session(for: instanceId)?.setRate(rate)
    }.runOnQueue(.main)

    AsyncFunction("setVolume") { (instanceId: Int, volume: Double) in
      PlayerRegistry.shared.session(for: instanceId)?.setVolume(Float(volume))
    }.runOnQueue(.main)

    AsyncFunction("setAudioTrack") { (instanceId: Int, index: Int) in
      PlayerRegistry.shared.session(for: instanceId)?.setAudioTrack(index: index)
    }.runOnQueue(.main)

    AsyncFunction("setSubtitleTrack") { (instanceId: Int, index: Int) in
      PlayerRegistry.shared.session(for: instanceId)?.setSubtitleTrack(index: index)
    }.runOnQueue(.main)

    AsyncFunction("replace") { (instanceId: Int, source: ReplacePayload) in
      let uri = source.uri.trimmingCharacters(in: .whitespacesAndNewlines)
      if uri.isEmpty {
        throw InvalidSourceException()
      }
      let url: URL
      if let parsed = URL(string: uri), parsed.scheme != nil {
        url = parsed
      } else if let encoded = uri.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
                let parsed = URL(string: encoded), parsed.scheme != nil {
        url = parsed
      } else {
        // Some Xtream providers hand us a raw host+path; default to http.
        url = URL(string: "http://\(uri)") ?? URL(fileURLWithPath: uri)
      }
      let media = VLCMedia(url: url)
      if let headers = source.headers {
        // libVLC's HTTP access reads these per-media options.
        for (name, value) in headers {
          switch name.lowercased() {
          case "user-agent":
            media.addOption(":http-user-agent=\(value)")
          case "referer", "referrer":
            media.addOption(":http-referrer=\(value)")
          default:
            break
          }
        }
      }
      PlayerRegistry.shared.session(for: instanceId)?.replace(media: media)
    }.runOnQueue(.main)

    AsyncFunction("startPictureInPicture") { (instanceId: Int, promise: Promise) in
      guard let session = PlayerRegistry.shared.session(for: instanceId) else {
        promise.resolve(false)
        return
      }
      session.startPictureInPicture { started in
        promise.resolve(started)
      }
    }.runOnQueue(.main)

    AsyncFunction("stopPictureInPicture") { (instanceId: Int) -> Bool in
      PlayerRegistry.shared.session(for: instanceId)?.stopPictureInPicture() ?? false
    }.runOnQueue(.main)
  }
}

struct ReplacePayload: Record {
  @Field var uri: String = ""
  @Field var headers: [String: String]?
}

final class InvalidSourceException: Exception, @unchecked Sendable {
  override var reason: String { "A non-empty media source URI is required." }
}

/// Maps JS player ids to their sessions. Ids are created on the JS thread;
/// sessions are torn down on the main thread because they own UIKit views.
final class PlayerRegistry {
  static let shared = PlayerRegistry()
  private let lock = NSLock()
  private var sessions: [Int: PlayerSession] = [:]
  private var nextId: Int = 0

  func create() -> Int {
    lock.lock()
    defer { lock.unlock() }
    nextId += 1
    let id = nextId
    sessions[id] = PlayerSession(id: id)
    return id
  }

  func session(for id: Int) -> PlayerSession? {
    lock.lock()
    defer { lock.unlock() }
    return sessions[id]
  }

  func remove(id: Int) {
    lock.lock()
    let session = sessions.removeValue(forKey: id)
    lock.unlock()
    guard let session else { return }
    DispatchQueue.main.async {
      session.destroy()
    }
  }
}

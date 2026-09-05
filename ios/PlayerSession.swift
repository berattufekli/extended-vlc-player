import AVFoundation
import Foundation
import MobileVLCKit
import UIKit

/// Owns the runtime state of a single VLC media player plus the
/// PiP-related infrastructure. There is one instance per JS player.
///
/// Thread-safety: all UIKit/VLC work happens on the main thread.
final class PlayerSession: NSObject {
  let id: Int
  let mediaPlayer = VLCMediaPlayer(options: [
    "network-caching": 1500,
    "live-caching": 1500,
    "file-caching": 1500,
  ])

  /// The UIView that hosts the `VLCMediaPlayer.drawable`. Created on demand
  /// so a session that is only used for headless PiP does not allocate a
  /// drawable. The Fabric component view owns and retains it.
  lazy var drawable: UIView = {
    let view = UIView()
    view.backgroundColor = .black
    view.translatesAutoresizingMaskIntoConstraints = false
    mediaPlayer.drawable = view
    return view
  }()

  /// Off-screen layer that backs the PiP overlay.
  private lazy var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer = {
    let layer = AVSampleBufferDisplayLayer()
    layer.videoGravity = .resizeAspect
    layer.backgroundColor = UIColor.black.cgColor
    return layer
  }()

  private lazy var pipBridge: PipBridge = PipBridge(displayLayer: sampleBufferDisplayLayer)
  private var _pipController: AVPictureInPictureController?
  private var pipController: AVPictureInPictureController? {
    get { _pipController }
    set {
      _pipController?.removeObserver(self, forKeyPath: "pictureInPictureActive", context: nil)
      _pipController = newValue
      _pipController?.addObserver(self, forKeyPath: "pictureInPictureActive", options: [.new], context: nil)
    }
  }

  private lazy var pipSampleBufferDelegate: SampleBufferPlaybackDelegate = {
    SampleBufferPlaybackDelegate(session: self)
  }()

  private var displayLink: CADisplayLink?
  private var snapshotCounter: UInt64 = 0

  /// Closure-based event sinks. The Fabric component view sets these when
  /// the session is attached; the session calls them on player events.
  var onLoad: (([String: Any]) -> Void)?
  var onProgress: (([String: Any]) -> Void)?
  var onPlaying: (([String: Any]) -> Void)?
  var onPaused: (([String: Any]) -> Void)?
  var onEnded: (() -> Void)?
  var onError: (([String: Any]) -> Void)?
  var onBuffering: (([String: Any]) -> Void)?
  var onPictureInPictureStart: (() -> Void)?
  var onPictureInPictureStop: (() -> Void)?

  init(id: Int) {
    self.id = id
    super.init()
    mediaPlayer.delegate = self
  }

  deinit {
    displayLink?.invalidate()
    mediaPlayer.stop()
  }

  // MARK: - Player control

  func play() { mediaPlayer.play() }
  func pause() { mediaPlayer.pause() }
  func stop() { mediaPlayer.stop() }

  func seek(to seconds: Double) {
    let vt = max(0, seconds)
    mediaPlayer.time = VLCTime(int: Int32(vt * 1000))
  }

  func setRate(_ rate: Double) {
    mediaPlayer.rate = Float(max(0.1, rate))
  }

  func setVolume(_ volume: Float) {
    mediaPlayer.volume = Int32(volume * 200)
  }

  func setAudioTrack(index: Int) {
    if index < 0 {
      mediaPlayer.currentAudioTrackIndex = -1
    } else {
      let tracks = mediaPlayer.audioTrackIndexes as? [Int32] ?? []
      if index < tracks.count {
        mediaPlayer.currentAudioTrackIndex = tracks[index]
      }
    }
  }

  func setSubtitleTrack(index: Int) {
    if index < 0 {
      mediaPlayer.currentVideoSubTitleIndex = -1
    } else {
      let tracks = mediaPlayer.videoSubTitlesIndexes as? [Int32] ?? []
      if index < tracks.count {
        mediaPlayer.currentVideoSubTitleIndex = tracks[index]
      }
    }
  }

  func replace(media: VLCMedia) {
    mediaPlayer.media = media
    mediaPlayer.play()
  }

  // MARK: - Picture-in-Picture

  @discardableResult
  func startPictureInPicture() -> Bool {
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return false }
    guard let drawable = mediaPlayer.drawable else { return false }

    if pipController != nil {
      pipController?.startPictureInPicture()
      startSnapshotBridge()
      return true
    }

    if sampleBufferDisplayLayer.superlayer == nil {
      drawable.layer.addSublayer(sampleBufferDisplayLayer)
      sampleBufferDisplayLayer.frame = .zero
    }

    let contentSource = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: sampleBufferDisplayLayer,
      playbackDelegate: pipSampleBufferDelegate
    )
    let controller = AVPictureInPictureController(contentSource: contentSource)
    controller.delegate = self
    controller.canStartPictureInPictureAutomaticallyFromInline = false
    pipController = controller

    startSnapshotBridge()
    controller.startPictureInPicture()
    return true
  }

  @discardableResult
  func stopPictureInPicture() -> Bool {
    let wasActive = pipController?.isPictureInPictureActive ?? false
    pipController?.stopPictureInPicture()
    stopSnapshotBridge()
    return wasActive
  }

  // MARK: - Snapshot bridge

  private func startSnapshotBridge() {
    stopSnapshotBridge()
    let link = CADisplayLink(target: self, selector: #selector(snapshotTick))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  private func stopSnapshotBridge() {
    displayLink?.invalidate()
    displayLink = nil
  }

  @objc private func snapshotTick() {
    snapshotCounter &+= 1
    let tempDir = NSTemporaryDirectory()
    let path = (tempDir as NSString).appendingPathComponent("exvlc-\(id)-\(snapshotCounter).jpg")
    mediaPlayer.saveVideoSnapshot(at: path, withWidth: 0, andHeight: 0)
    DispatchQueue.main.async { [weak self] in
      self?.consumeSnapshot(at: path)
    }
  }

  private func consumeSnapshot(at path: String) {
    guard FileManager.default.fileExists(atPath: path) else { return }
    defer { try? FileManager.default.removeItem(atPath: path) }
    guard let image = UIImage(contentsOfFile: path) else { return }
    pipBridge.feed(image: image)
  }
}

// MARK: - VLCMediaPlayerDelegate

extension PlayerSession: VLCMediaPlayerDelegate {
  func mediaPlayerStateChanged(_ aNotification: Notification!) {
    switch mediaPlayer.state {
    case .opening:
      onLoad?([
        "duration": Double(mediaPlayer.length.intValue) / 1000.0,
        "audioTracks": audioTracksPayload(),
        "textTracks": textTracksPayload(),
      ])
    case .playing:
      onPlaying?(["duration": Double(mediaPlayer.length.intValue) / 1000.0])
    case .paused:
      onPaused?([:])
    case .stopped:
      onEnded?()
    case .ended:
      onEnded?()
    case .error:
      onError?([
        "message": "VLCMediaPlayer reported error state",
        "code": "VLC_ERROR",
        "domain": "MobileVLCKit",
      ])
    case .buffering:
      onBuffering?(["isBuffering": true])
    @unknown default:
      break
    }
  }

  func mediaPlayerTimeChanged(_ aNotification: Notification!) {
    let current = Double(mediaPlayer.time.intValue) / 1000.0
    let total = Double(mediaPlayer.length.intValue) / 1000.0
    let position = total > 0 ? current / total : 0
    onProgress?([
      "currentTime": current,
      "duration": total,
      "position": position,
    ])
  }

  private func audioTracksPayload() -> [[String: Any]] {
    let indexes = (mediaPlayer.audioTrackIndexes as? [Int32]) ?? []
    return indexes.enumerated().map { (i, _) -> [String: Any] in
      ["index": i]
    }
  }

  private func textTracksPayload() -> [[String: Any]] {
    let indexes = (mediaPlayer.videoSubTitlesIndexes as? [Int32]) ?? []
    return indexes.enumerated().map { (i, _) -> [String: Any] in
      ["index": i]
    }
  }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PlayerSession: AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {}

  func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    onPictureInPictureStart?()
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    stopSnapshotBridge()
    onPictureInPictureStop?()
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    stopSnapshotBridge()
    onError?([
      "message": "Picture-in-Picture failed to start: \(error.localizedDescription)",
      "code": "PIP_FAILED",
      "domain": "AVKit",
    ])
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }

  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
    if keyPath == "pictureInPictureActive" {
      if let active = change?[.newKey] as? Bool, !active {
        stopSnapshotBridge()
      }
    } else {
      super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
    }
  }
}

// MARK: - SampleBufferPlaybackDelegate

final class SampleBufferPlaybackDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
  weak var session: PlayerSession?

  init(session: PlayerSession) {
    self.session = session
    super.init()
  }

  func setPlaying(_ playing: Bool) {}
  func setPlaybackRate(_ playbackRate: Float) { session?.mediaPlayer.rate = playbackRate }
  func playbackTimeRange() -> CMTimeRange {
    let start = session?.mediaPlayer.time ?? VLCTime(int: 0)
    let length = session?.mediaPlayer.length ?? VLCTime(int: 0)
    let startSec = Double(start.intValue) / 1000.0
    let lengthSec = Double(length.intValue) / 1000.0
    if lengthSec <= 0 { return .invalid }
    return CMTimeRange(
      start: CMTime(seconds: startSec, preferredTimescale: 600),
      duration: CMTime(seconds: lengthSec, preferredTimescale: 600)
    )
  }
  func isPlaybackPaused() -> Bool { return !(session?.mediaPlayer.isPlaying ?? false) }
  func isPlaybackBufferEmpty() -> Bool { return !(session?.mediaPlayer.isPlaying ?? false) }
  func isPlaybackLikelyToKeepUp() -> Bool { return session?.mediaPlayer.isPlaying ?? false }
  func didPlayToEnd() -> Bool { return session?.mediaPlayer.state == .ended }
  func currentTime() -> CMTime {
    let t = session?.mediaPlayer.time ?? VLCTime(int: 0)
    return CMTime(seconds: Double(t.intValue) / 1000.0, preferredTimescale: 600)
  }
  func seek(to time: CMTime, completionHandler: @escaping (Bool) -> Void) {
    let secs = CMTimeGetSeconds(time)
    session?.seek(to: secs)
    completionHandler(true)
  }
  func recommendedPlaybackRate() -> Float { return session?.mediaPlayer.rate ?? 1.0 }
}

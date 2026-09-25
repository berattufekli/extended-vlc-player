import AVFoundation
import AVKit
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
    "--network-caching=1500",
    "--live-caching=1500",
    "--file-caching=1500",
  ] as [Any])

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
  private var contentFit = "contain"

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

  func setContentFit(_ value: String) {
    contentFit = value
    switch value {
    case "fill":
      drawable.contentMode = .scaleToFill
    case "cover":
      drawable.contentMode = .scaleAspectFill
    default:
      drawable.contentMode = .scaleAspectFit
    }
    drawable.clipsToBounds = true
    updatePictureInPictureLayerFrame()
  }

  func setAspectRatio(_ value: String?) {
    if let ratio = value, ratio == "16:9" || ratio == "4:3" {
      ratio.withCString { cString in
        mediaPlayer.videoAspectRatio = UnsafeMutablePointer(mutating: cString)
      }
    } else {
      mediaPlayer.videoAspectRatio = nil
    }
  }

  func setVolume(_ volume: Float) {
    mediaPlayer.audio?.volume = Int32(volume * 200)
  }

  func isPictureInPictureActive() -> Bool {
    pipController?.isPictureInPictureActive ?? false
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
    if !Thread.isMainThread {
      var result = false
      DispatchQueue.main.sync {
        result = self.startPictureInPicture()
      }
      return result
    }

    guard AVPictureInPictureController.isPictureInPictureSupported() else { return false }
    guard let drawable = mediaPlayer.drawable as? UIView else { return false }

    if pipController != nil {
      pipController?.startPictureInPicture()
      startSnapshotBridge()
      return true
    }

    if sampleBufferDisplayLayer.superlayer == nil {
      drawable.layer.addSublayer(sampleBufferDisplayLayer)
    }
    updatePictureInPictureLayerFrame()

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

  private func updatePictureInPictureLayerFrame() {
    guard sampleBufferDisplayLayer.superlayer != nil else { return }
    sampleBufferDisplayLayer.frame = drawable.bounds
  }

  @discardableResult
  func stopPictureInPicture() -> Bool {
    if !Thread.isMainThread {
      var result = false
      DispatchQueue.main.sync {
        result = self.stopPictureInPicture()
      }
      return result
    }

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
  func mediaPlayerStateChanged(_ aNotification: Notification) {
    let duration = Double(mediaPlayer.media?.length.intValue ?? 0) / 1000.0
    switch mediaPlayer.state {
    case .opening:
      onLoad?([
        "duration": duration,
        "audioTracks": audioTracksPayload(),
        "textTracks": textTracksPayload(),
      ])
    case .playing:
      onPlaying?(["duration": duration])
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
    case .esAdded:
      // Track metadata becomes available after the elementary streams are
      // announced; the next opening/playing callback carries the payload.
      break
    @unknown default:
      break
    }
  }

  func mediaPlayerTimeChanged(_ aNotification: Notification) {
    let current = Double(mediaPlayer.time.intValue) / 1000.0
    let total = Double(mediaPlayer.media?.length.intValue ?? 0) / 1000.0
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

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    if playing {
      session?.play()
    } else {
      session?.pause()
    }
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    let start = session?.mediaPlayer.time ?? VLCTime(int: 0)
    let length = session?.mediaPlayer.media?.length ?? VLCTime(int: 0)
    let startSec = Double(start.intValue) / 1000.0
    let lengthSec = Double(length.intValue) / 1000.0
    if lengthSec <= 0 { return .invalid }
    return CMTimeRange(
      start: CMTime(seconds: startSec, preferredTimescale: 600),
      duration: CMTime(seconds: lengthSec, preferredTimescale: 600)
    )
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    !(session?.mediaPlayer.isPlaying ?? false)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping @Sendable () -> Void
  ) {
    let current = Double(session?.mediaPlayer.time.intValue ?? 0) / 1000.0
    let offset = CMTimeGetSeconds(skipInterval)
    session?.seek(to: current + (offset.isFinite ? offset : 0))
    completionHandler()
  }
}

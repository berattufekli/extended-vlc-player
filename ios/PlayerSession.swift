import AVFoundation
import AVKit
import CoreMedia
import Foundation
import MobileVLCKit
import UIKit

/// Owns the runtime state of a single VLC media player plus its
/// Picture-in-Picture controller. There is one instance per JS player.
///
/// Video never goes through MobileVLCKit's OpenGL drawable. `EXVLCFrameSink`
/// hands every decoded frame to `displayLayer`, an `AVSampleBufferDisplayLayer`
/// that renders inline and doubles as the PiP content source, so PiP keeps
/// receiving frames while the app is in the background.
///
/// Thread-safety: all state except the frame path is touched on the main
/// thread. Frames arrive on libVLC's video output thread and only touch
/// `displayLayer` and `frameFormat`.
final class PlayerSession: NSObject {
  let id: Int
  let mediaPlayer = VLCMediaPlayer(options: [
    "--network-caching=1500",
    "--live-caching=1500",
    "--file-caching=1500",
  ] as [Any])

  let displayLayer = AVSampleBufferDisplayLayer()
  private lazy var frameSink = EXVLCFrameSink(mediaPlayer: mediaPlayer)
  private var frameFormat: CMVideoFormatDescription?

  /// Drives the PiP window's scrubber. Frames are flagged "display
  /// immediately", so the timebase never delays rendering.
  private let timebase: CMTimebase

  /// Created on the main thread when a view first shows the session.
  private(set) lazy var surface: PlayerSurfaceView = PlayerSurfaceView(displayLayer: displayLayer)

  private var pipController: AVPictureInPictureController?
  private var pipObservations: [NSKeyValueObservation] = []
  private var pipStartWaiters: [(Bool) -> Void] = []
  var startsPictureInPictureAutomatically = false {
    didSet {
      pipController?.canStartPictureInPictureAutomaticallyFromInline = startsPictureInPictureAutomatically
    }
  }

  private var durationSeconds = 0.0
  private var didEmitLoad = false
  private var didEmitLoadWithDuration = false
  private var pendingSeekSeconds: Double?
  private var isBuffering = false
  private var lastProgressEmit: CFTimeInterval = 0
  private var lastTracksSignature = ""
  private var lastTracksCheck: CFTimeInterval = 0
  private var isDestroyed = false

  /// Closure-based event sinks. The view sets these while it shows the
  /// session; the session calls them on the main thread.
  var onLoad: (([String: Any]) -> Void)?
  var onTracksChanged: (([String: Any]) -> Void)?
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
    var timebase: CMTimebase?
    CMTimebaseCreateWithSourceClock(
      allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(),
      timebaseOut: &timebase
    )
    self.timebase = timebase!
    CMTimebaseSetRate(self.timebase, rate: 0)
    CMTimebaseSetTime(self.timebase, time: .zero)
    super.init()

    displayLayer.videoGravity = .resizeAspect
    displayLayer.backgroundColor = UIColor.black.cgColor
    displayLayer.controlTimebase = self.timebase

    mediaPlayer.delegate = self
    frameSink.onFrame = { [weak self] pixelBuffer in
      self?.enqueue(pixelBuffer)
    }
  }

  deinit {
    frameSink.invalidate()
    mediaPlayer.delegate = nil
    mediaPlayer.stop()
  }

  /// Tears the session down; called when JS releases the player.
  func destroy() {
    isDestroyed = true
    frameSink.invalidate()
    clearEventSinks()
    resolvePictureInPictureWaiters(false)
    pipObservations.removeAll()
    pipController?.stopPictureInPicture()
    pipController?.delegate = nil
    pipController = nil
    mediaPlayer.delegate = nil
    mediaPlayer.stop()
    surface.removeFromSuperview()
  }

  func clearEventSinks() {
    onLoad = nil
    onTracksChanged = nil
    onProgress = nil
    onPlaying = nil
    onPaused = nil
    onEnded = nil
    onError = nil
    onBuffering = nil
    onPictureInPictureStart = nil
    onPictureInPictureStop = nil
  }

  // MARK: - Player control

  func play() {
    mediaPlayer.play()
  }

  func pause() {
    if mediaPlayer.canPause {
      mediaPlayer.pause()
    }
  }

  func stop() {
    mediaPlayer.stop()
  }

  func seek(to seconds: Double) {
    let target = max(0, seconds.isFinite ? seconds : 0)
    NSLog("[EXVLCDBG] seek request=%f state=%d seekable=%d", target, mediaPlayer.state.rawValue, mediaPlayer.isSeekable ? 1 : 0)
    // libVLC ignores a time assignment while it is still opening the media,
    // so keep the request and apply it from the first seekable state.
    pendingSeekSeconds = durationSeconds > 0 ? min(target, durationSeconds) : target
    applyPendingSeekIfReady()
  }

  func setRate(_ rate: Double) {
    mediaPlayer.rate = Float(max(0.1, rate))
    updateTimebaseRate()
  }

  func setVolume(_ volume: Float) {
    // libVLC treats 100 as unity gain; anything above amplifies.
    mediaPlayer.audio?.volume = Int32((max(0, min(1, volume)) * 100).rounded())
  }

  func setContentFit(_ value: String) {
    surface.contentFit = value
  }

  func setAspectRatio(_ value: String?) {
    surface.forcedAspectRatio = value
  }

  func setAudioTrack(index: Int) {
    let tracks = audioTracks()
    if index < 0 {
      mediaPlayer.currentAudioTrackIndex = -1
    } else if index < tracks.count {
      mediaPlayer.currentAudioTrackIndex = tracks[index].vlcIndex
    }
    emitTracksIfChanged()
  }

  func setSubtitleTrack(index: Int) {
    let tracks = subtitleTracks()
    if index < 0 {
      mediaPlayer.currentVideoSubTitleIndex = -1
    } else if index < tracks.count {
      mediaPlayer.currentVideoSubTitleIndex = tracks[index].vlcIndex
    }
    emitTracksIfChanged()
  }

  func replace(media: VLCMedia) {
    durationSeconds = 0
    didEmitLoad = false
    didEmitLoadWithDuration = false
    pendingSeekSeconds = nil
    isBuffering = false
    lastProgressEmit = 0
    lastTracksSignature = ""
    lastTracksCheck = 0
    CMTimebaseSetRate(timebase, rate: 0)
    CMTimebaseSetTime(timebase, time: .zero)
    displayLayer.flushAndRemoveImage()

    mediaPlayer.media = media
    mediaPlayer.play()
    pipController?.invalidatePlaybackState()
  }

  // MARK: - Frames

  private func enqueue(_ pixelBuffer: CVPixelBuffer) {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    if let format = frameFormat,
       CMVideoFormatDescriptionGetDimensions(format).width != Int32(width)
        || CMVideoFormatDescriptionGetDimensions(format).height != Int32(height) {
      frameFormat = nil
    }
    if frameFormat == nil {
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &frameFormat
      )
    }
    guard let format = frameFormat else { return }

    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMTimebaseGetTime(timebase),
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescription: format,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer
    )
    guard let sampleBuffer else { return }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
       CFArrayGetCount(attachments) > 0 {
      let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        dictionary,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
      )
    }

    // The layer stops decoding when the app is backgrounded without PiP;
    // it must be flushed before it accepts frames again.
    if displayLayer.status == .failed || displayLayer.requiresFlushToResumeDecoding {
      displayLayer.flush()
    }
    displayLayer.enqueue(sampleBuffer)
  }

  // MARK: - Time, duration and seeking

  private func currentSeconds() -> Double {
    Double(mediaPlayer.time.intValue) / 1000.0
  }

  private func refreshDuration() {
    let length = Double(mediaPlayer.media?.length.intValue ?? 0) / 1000.0
    if length > 0, abs(length - durationSeconds) > 0.5 {
      durationSeconds = length
      pipController?.invalidatePlaybackState()
    }
  }

  private func applyPendingSeekIfReady() {
    guard let target = pendingSeekSeconds, mediaPlayer.media != nil else { return }
    switch mediaPlayer.state {
    case .playing, .paused, .buffering, .esAdded:
      break
    default:
      return
    }
    guard mediaPlayer.isSeekable else { return }

    pendingSeekSeconds = nil
    mediaPlayer.time = VLCTime(int: Int32(clamping: Int((target * 1000).rounded())))
    CMTimebaseSetTime(timebase, time: CMTime(seconds: target, preferredTimescale: 600))
    emitProgress(currentTime: target, force: true)
  }

  private func updateTimebaseRate() {
    let rate = mediaPlayer.isPlaying && mediaPlayer.state != .paused ? Double(mediaPlayer.rate) : 0
    CMTimebaseSetRate(timebase, rate: rate)
  }

  private func syncTimebase(to seconds: Double) {
    let timebaseSeconds = CMTimebaseGetTime(timebase).seconds
    if !timebaseSeconds.isFinite || abs(timebaseSeconds - seconds) > 0.75 {
      CMTimebaseSetTime(timebase, time: CMTime(seconds: seconds, preferredTimescale: 600))
    }
  }

  // MARK: - Events

  private func emitLoadIfNeeded() {
    // Emit once when playback starts, then once more if the duration was
    // unknown at that point, so resume logic keyed on `onLoad` still runs.
    let hasDuration = durationSeconds > 0
    if didEmitLoad && (didEmitLoadWithDuration || !hasDuration) { return }
    didEmitLoad = true
    didEmitLoadWithDuration = hasDuration
    var payload = tracksPayload()
    payload["duration"] = durationSeconds
    onLoad?(payload)
  }

  private func emitProgress(currentTime: Double, force: Bool = false) {
    let now = CACurrentMediaTime()
    guard force || now - lastProgressEmit >= 0.25 else { return }
    lastProgressEmit = now
    onProgress?([
      "currentTime": currentTime,
      "duration": durationSeconds,
      "position": durationSeconds > 0 ? min(1, currentTime / durationSeconds) : 0,
    ])
  }

  private func setBuffering(_ buffering: Bool) {
    guard isBuffering != buffering else { return }
    isBuffering = buffering
    onBuffering?(["isBuffering": buffering])
  }

  private func tracksPayload() -> [String: Any] {
    let languages = trackLanguages()
    let audio = audioTracks().enumerated().map { offset, track in
      trackEntry(index: offset, track: track, language: languages[track.vlcIndex],
                 selected: track.vlcIndex == mediaPlayer.currentAudioTrackIndex)
    }
    let text = subtitleTracks().enumerated().map { offset, track in
      trackEntry(index: offset, track: track, language: languages[track.vlcIndex],
                 selected: track.vlcIndex == mediaPlayer.currentVideoSubTitleIndex)
    }
    return ["audioTracks": audio, "textTracks": text]
  }

  private func trackEntry(index: Int, track: (vlcIndex: Int32, name: String), language: String?, selected: Bool) -> [String: Any] {
    var entry: [String: Any] = ["index": index, "label": track.name, "selected": selected]
    if let language, !language.isEmpty { entry["language"] = language }
    return entry
  }

  /// libVLC elementary-stream id → language code from the media's track info.
  private func trackLanguages() -> [Int32: String] {
    guard let info = mediaPlayer.media?.tracksInformation as? [[String: Any]] else { return [:] }
    var result: [Int32: String] = [:]
    for track in info {
      guard let id = (track[VLCMediaTracksInformationId] as? NSNumber)?.int32Value,
            let language = track[VLCMediaTracksInformationLanguage] as? String,
            !language.isEmpty else { continue }
      result[id] = language
    }
    return result
  }

  /// Emits `onTracksChanged` when the track lists or selections changed.
  private func emitTracksIfChanged() {
    let audio = audioTracks()
    let text = subtitleTracks()
    let signature = audio.map { "\($0.vlcIndex):\($0.name)" }.joined(separator: ",")
      + "|\(mediaPlayer.currentAudioTrackIndex)|"
      + text.map { "\($0.vlcIndex):\($0.name)" }.joined(separator: ",")
      + "|\(mediaPlayer.currentVideoSubTitleIndex)"
    guard signature != lastTracksSignature else { return }
    lastTracksSignature = signature
    onTracksChanged?(tracksPayload())
  }

  /// Tracks without libVLC's synthetic "Disable" entry (index -1).
  private func audioTracks() -> [(vlcIndex: Int32, name: String)] {
    zipTracks(indexes: mediaPlayer.audioTrackIndexes, names: mediaPlayer.audioTrackNames)
  }

  private func subtitleTracks() -> [(vlcIndex: Int32, name: String)] {
    zipTracks(indexes: mediaPlayer.videoSubTitlesIndexes, names: mediaPlayer.videoSubTitlesNames)
  }

  private func zipTracks(indexes: [Any]?, names: [Any]?) -> [(vlcIndex: Int32, name: String)] {
    let indexes = (indexes ?? []).compactMap { ($0 as? NSNumber)?.int32Value }
    let names = (names ?? []).map { "\($0)" }
    return indexes.enumerated().compactMap { offset, vlcIndex in
      guard vlcIndex >= 0 else { return nil }
      return (vlcIndex, offset < names.count ? names[offset] : "Track \(offset)")
    }
  }

  // MARK: - Picture-in-Picture

  /// Builds the PiP controller as soon as the layer is on screen. AVKit only
  /// reports `isPictureInPicturePossible` after the controller has observed
  /// the layer for a moment, so creating it lazily on the button tap makes
  /// the first start fail.
  func preparePictureInPicture() {
    guard pipController == nil, !isDestroyed,
          AVPictureInPictureController.isPictureInPictureSupported() else { return }

    let contentSource = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: displayLayer,
      playbackDelegate: self
    )
    let controller = AVPictureInPictureController(contentSource: contentSource)
    controller.delegate = self
    controller.canStartPictureInPictureAutomaticallyFromInline = startsPictureInPictureAutomatically
    pipObservations = [
      controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] controller, _ in
        DispatchQueue.main.async {
          guard let self, controller.isPictureInPicturePossible, !self.pipStartWaiters.isEmpty else { return }
          controller.startPictureInPicture()
        }
      },
    ]
    pipController = controller
  }

  func isPictureInPictureActive() -> Bool {
    pipController?.isPictureInPictureActive ?? false
  }

  /// Resolves `true` once PiP is on screen, `false` if it cannot start.
  func startPictureInPicture(completion: @escaping (Bool) -> Void) {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      completion(false)
      return
    }
    preparePictureInPicture()
    guard let controller = pipController else {
      completion(false)
      return
    }
    if controller.isPictureInPictureActive {
      completion(true)
      return
    }

    pipStartWaiters.append(completion)
    if controller.isPictureInPicturePossible {
      controller.startPictureInPicture()
    }
    // The KVO observer above starts PiP once it becomes possible; give up
    // if the system never allows it (e.g. no frame has been rendered yet).
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
      self?.resolvePictureInPictureWaiters(false)
    }
  }

  func stopPictureInPicture() -> Bool {
    guard let controller = pipController, controller.isPictureInPictureActive else { return false }
    controller.stopPictureInPicture()
    return true
  }

  private func resolvePictureInPictureWaiters(_ started: Bool) {
    let waiters = pipStartWaiters
    pipStartWaiters.removeAll()
    waiters.forEach { $0(started) }
  }
}

// MARK: - VLCMediaPlayerDelegate

extension PlayerSession: VLCMediaPlayerDelegate {
  func mediaPlayerStateChanged(_ aNotification: Notification) {
    guard !isDestroyed else { return }
    refreshDuration()
    updateTimebaseRate()
    NSLog("[EXVLCDBG] state=%d duration=%f seekable=%d sinks=%d", mediaPlayer.state.rawValue, durationSeconds, mediaPlayer.isSeekable ? 1 : 0, onProgress == nil ? 0 : 1)

    switch mediaPlayer.state {
    case .opening:
      setBuffering(true)
    case .buffering:
      // libVLC reports buffering repeatedly while it plays; the next time
      // update clears it.
      setBuffering(true)
      applyPendingSeekIfReady()
    case .playing:
      emitLoadIfNeeded()
      emitTracksIfChanged()
      applyPendingSeekIfReady()
      onPlaying?(["duration": durationSeconds])
    case .paused:
      applyPendingSeekIfReady()
      setBuffering(false)
      onPaused?(["target": currentSeconds()])
    case .ended:
      setBuffering(false)
      onEnded?()
    case .error:
      setBuffering(false)
      onError?([
        "message": "The media could not be played.",
        "code": "VLC_ERROR",
        "domain": "MobileVLCKit",
      ])
    case .esAdded:
      emitTracksIfChanged()
    case .stopped:
      break
    @unknown default:
      break
    }
    pipController?.invalidatePlaybackState()
  }

  func mediaPlayerTimeChanged(_ aNotification: Notification) {
    guard !isDestroyed else { return }
    refreshDuration()
    emitLoadIfNeeded()
    applyPendingSeekIfReady()
    let now = CACurrentMediaTime()
    if now - lastTracksCheck >= 1 {
      lastTracksCheck = now
      emitTracksIfChanged()
    }
    setBuffering(false)

    let current = currentSeconds()
    NSLog("[EXVLCDBG] time=%f duration=%f sinks=%d", current, durationSeconds, onProgress == nil ? 0 : 1)
    syncTimebase(to: current)
    updateTimebaseRate()
    emitProgress(currentTime: current)
  }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PlayerSession: AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    resolvePictureInPictureWaiters(true)
    onPictureInPictureStart?()
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    onPictureInPictureStop?()
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    resolvePictureInPictureWaiters(false)
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
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension PlayerSession: AVPictureInPictureSampleBufferPlaybackDelegate {
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
    if playing {
      play()
    } else {
      pause()
    }
  }

  func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
    // Live streams have no seekable range; an infinite range makes PiP
    // show its live UI instead of a scrubber.
    guard durationSeconds > 0 else {
      return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    return CMTimeRange(start: .zero, duration: CMTime(seconds: durationSeconds, preferredTimescale: 600))
  }

  func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
    !mediaPlayer.isPlaying || mediaPlayer.state == .paused
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    let offset = CMTimeGetSeconds(skipInterval)
    seek(to: currentSeconds() + (offset.isFinite ? offset : 0))
    completionHandler()
  }
}

// MARK: - Surface

/// Hosts the session's display layer inside the React view and applies
/// `contentFit` / forced aspect ratios to it.
final class PlayerSurfaceView: UIView {
  private let displayLayer: AVSampleBufferDisplayLayer

  var contentFit = "contain" {
    didSet { setNeedsLayout() }
  }

  var forcedAspectRatio: String? {
    didSet { setNeedsLayout() }
  }

  init(displayLayer: AVSampleBufferDisplayLayer) {
    self.displayLayer = displayLayer
    super.init(frame: .zero)
    backgroundColor = .black
    clipsToBounds = true
    layer.addSublayer(displayLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if let ratio = parsedAspectRatio() {
      // A forced ratio stretches the picture into a centred box of that
      // shape, matching libVLC's `--aspect-ratio` behaviour.
      let width = min(bounds.width, bounds.height * ratio)
      let height = width / ratio
      displayLayer.frame = CGRect(
        x: (bounds.width - width) / 2,
        y: (bounds.height - height) / 2,
        width: width,
        height: height
      )
      displayLayer.videoGravity = .resize
    } else {
      displayLayer.frame = bounds
      switch contentFit {
      case "cover":
        displayLayer.videoGravity = .resizeAspectFill
      case "fill":
        displayLayer.videoGravity = .resize
      default:
        displayLayer.videoGravity = .resizeAspect
      }
    }
    CATransaction.commit()
  }

  private func parsedAspectRatio() -> CGFloat? {
    guard let value = forcedAspectRatio else { return nil }
    let parts = value.split(separator: ":").compactMap { Double($0) }
    guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
    return CGFloat(parts[0] / parts[1])
  }
}

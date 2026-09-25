import ExpoModulesCore
import UIKit

/// Expo 57/Fabric view that shows the video surface of one VLC session.
///
/// The session itself is deliberately kept outside the view so replacing a
/// source, rotating the device, or temporarily detaching the React view does
/// not recreate the VLC decoder or lose PiP state.
public final class ExtendedVlcPlayerView: ExpoView {
  private var playerId = 0
  private var contentFit = "contain"
  private var aspectRatio: String?
  private var startsPictureInPictureAutomatically = false

  let onLoad = EventDispatcher()
  let onTracksChanged = EventDispatcher()
  let onProgress = EventDispatcher()
  let onPlaying = EventDispatcher()
  let onPaused = EventDispatcher()
  let onEnded = EventDispatcher()
  let onError = EventDispatcher()
  let onBuffering = EventDispatcher()
  let onPictureInPictureStart = EventDispatcher()
  let onPictureInPictureStop = EventDispatcher()

  public required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    backgroundColor = .black
    clipsToBounds = true
  }

  func setPlayer(_ id: Int) {
    guard playerId != id else {
      attachSessionIfPossible()
      return
    }

    detachSession()
    playerId = id
    attachSessionIfPossible()
  }

  func setContentFit(_ value: String) {
    contentFit = value
    PlayerRegistry.shared.session(for: playerId)?.setContentFit(value)
  }

  func setAspectRatio(_ value: String?) {
    aspectRatio = value
    PlayerRegistry.shared.session(for: playerId)?.setAspectRatio(value)
  }

  func setStartsPictureInPictureAutomatically(_ value: Bool) {
    startsPictureInPictureAutomatically = value
    PlayerRegistry.shared.session(for: playerId)?.startsPictureInPictureAutomatically = value
  }

  public override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      detachSession()
    } else {
      attachSessionIfPossible()
    }
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    guard let session = PlayerRegistry.shared.session(for: playerId),
          session.surface.superview === self else { return }
    session.surface.frame = bounds
  }

  private func attachSessionIfPossible() {
    guard playerId != 0, window != nil,
          let session = PlayerRegistry.shared.session(for: playerId) else { return }

    let surface = session.surface
    if surface.superview !== self {
      surface.frame = bounds
      surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      addSubview(surface)
    }
    session.setContentFit(contentFit)
    session.setAspectRatio(aspectRatio)
    session.startsPictureInPictureAutomatically = startsPictureInPictureAutomatically
    session.preparePictureInPicture()

    session.onLoad = { [weak self] payload in self?.onLoad(payload) }
    session.onTracksChanged = { [weak self] payload in self?.onTracksChanged(payload) }
    session.onProgress = { [weak self] payload in self?.onProgress(payload) }
    session.onPlaying = { [weak self] payload in self?.onPlaying(payload) }
    session.onPaused = { [weak self] payload in self?.onPaused(payload) }
    session.onEnded = { [weak self] in self?.onEnded() }
    session.onError = { [weak self] payload in self?.onError(payload) }
    session.onBuffering = { [weak self] payload in self?.onBuffering(payload) }
    session.onPictureInPictureStart = { [weak self] in self?.onPictureInPictureStart() }
    session.onPictureInPictureStop = { [weak self] in self?.onPictureInPictureStop() }
  }

  private func detachSession() {
    guard playerId != 0, let session = PlayerRegistry.shared.session(for: playerId) else {
      return
    }
    // The PiP window renders from the session's layer; keep it in the
    // hierarchy while PiP is showing so the window does not go blank.
    if session.isPictureInPictureActive() {
      return
    }
    if session.surface.superview === self {
      session.surface.removeFromSuperview()
    }
    session.clearEventSinks()
  }
}

import ExpoModulesCore
import UIKit

/// Expo 57/Fabric view that owns the drawable UIView for one VLC session.
///
/// The session itself is deliberately kept outside the view so replacing a
/// source, rotating the device, or temporarily detaching the React view does
/// not recreate the VLC decoder or lose PiP state.
public final class ExtendedVlcPlayerView: ExpoView {
  private var playerId = 0
  private var contentFit = "contain"
  private var aspectRatio: String?

  let onLoad = EventDispatcher()
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
    configureView()
  }

  private func configureView() {
    backgroundColor = .black
    clipsToBounds = true
  }

  public func setPlayer(_ id: Int) {
    guard playerId != id else {
      attachSessionIfPossible()
      return
    }

    detachSession()
    playerId = id
    attachSessionIfPossible()
  }

  public func setContentFit(_ value: String) {
    contentFit = value
    PlayerRegistry.shared.session(for: playerId)?.setContentFit(value)
  }

  public func setAspectRatio(_ value: String?) {
    aspectRatio = value
    PlayerRegistry.shared.session(for: playerId)?.setAspectRatio(value)
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
    guard let session = PlayerRegistry.shared.session(for: playerId) else { return }
    session.drawable.frame = bounds
    session.setContentFit(contentFit)
    session.setAspectRatio(aspectRatio)
  }

  private func attachSessionIfPossible() {
    guard playerId != 0, window != nil,
          let session = PlayerRegistry.shared.session(for: playerId) else { return }

    let drawable = session.drawable
    if drawable.superview !== self {
      drawable.frame = bounds
      drawable.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      addSubview(drawable)
    }
    session.setContentFit(contentFit)

    session.onLoad = { [weak self] payload in self?.onLoad(payload) }
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

    if session.drawable.superview === self {
      session.drawable.removeFromSuperview()
    }
    session.onLoad = nil
    session.onProgress = nil
    session.onPlaying = nil
    session.onPaused = nil
    session.onEnded = nil
    session.onError = nil
    session.onBuffering = nil
    session.onPictureInPictureStart = nil
    session.onPictureInPictureStop = nil
  }
}

package expo.modules.extendedvlcplayer

import android.content.Context
import android.view.View
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.viewevent.EventDispatcher
import expo.modules.kotlin.views.ExpoView

/**
 * Fabric view component for `ExtendedVlcPlayerView` on Android.
 *
 * Mirrors the iOS bridge: owns the libVLC session for this player
 * instance and forwards VLC events back to JS through the standard
 * Expo Modules event dispatcher.
 */
class ExtendedVlcPlayerViewComponentView(context: Context, appContext: AppContext) :
  ExpoView(context, appContext) {

  private var playerId: Int = 0

  val onLoad by EventDispatcher<Map<String, Any>>()
  val onProgress by EventDispatcher<Map<String, Any>>()
  val onPlaying by EventDispatcher<Map<String, Any>>()
  val onPaused by EventDispatcher<Map<String, Any>>()
  val onEnded by EventDispatcher<Unit>()
  val onError by EventDispatcher<Map<String, Any>>()
  val onBuffering by EventDispatcher<Map<String, Any>>()
  val onPictureInPictureStart by EventDispatcher<Unit>()
  val onPictureInPictureStop by EventDispatcher<Unit>()

  fun setPlayer(id: Int) {
    if (playerId == id) return
    // If we were attached to a previous session, detach.
    detachFromSession()
    playerId = id
    val session = PlayerRegistry.session(id) ?: return
    val drawable = session.drawable
    drawable.layoutParams = android.view.ViewGroup.LayoutParams(
      android.view.ViewGroup.LayoutParams.MATCH_PARENT,
      android.view.ViewGroup.LayoutParams.MATCH_PARENT
    )
    this.addView(drawable)
    PlayerRegistry.attachView(this, id)
    // Wire event sinks to forward to the JS dispatcher.
    session.onLoad = { payload -> onLoad(payload) }
    session.onProgress = { payload -> onProgress(payload) }
    session.onPlaying = { payload -> onPlaying(payload) }
    session.onPaused = { payload -> onPaused(payload) }
    session.onEnded = { onEnded(Unit) }
    session.onError = { payload -> onError(payload) }
    session.onBuffering = { payload -> onBuffering(payload) }
    session.onPictureInPictureStart = { onPictureInPictureStart(Unit) }
    session.onPictureInPictureStop = { onPictureInPictureStop(Unit) }
  }

  fun createPlayer(): Int {
    val (id, _) = PlayerRegistry.create(context)
    playerId = id
    return id
  }

  private fun detachFromSession() {
    if (playerId == 0) return
    val session = PlayerRegistry.session(playerId) ?: return
    this.removeView(session.drawable)
    session.onLoad = null
    session.onProgress = null
    session.onPlaying = null
    session.onPaused = null
    session.onEnded = null
    session.onError = null
    session.onBuffering = null
    session.onPictureInPictureStart = null
    session.onPictureInPictureStop = null
    PlayerRegistry.detachView(this)
  }

  override fun onDetachedFromWindow() {
    super.onDetachedFromWindow()
    detachFromSession()
  }
}

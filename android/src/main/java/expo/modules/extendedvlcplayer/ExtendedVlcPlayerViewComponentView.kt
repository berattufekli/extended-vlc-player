package expo.modules.extendedvlcplayer

import android.app.Activity
import android.content.Context
import java.lang.reflect.Proxy
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
  private var contentFit: String = "contain"
  private var autoEnterPiP = false
  private var pipActivity: Activity? = null
  private var pipListener: Any? = null

  val onLoad by EventDispatcher<Map<String, Any>>()
  val onTracksChanged by EventDispatcher<Map<String, Any>>()
  val onProgress by EventDispatcher<Map<String, Any>>()
  val onPlaying by EventDispatcher<Map<String, Any>>()
  val onPaused by EventDispatcher<Map<String, Any>>()
  val onEnded by EventDispatcher<Unit>()
  val onError by EventDispatcher<Map<String, Any>>()
  val onBuffering by EventDispatcher<Map<String, Any>>()
  val onPictureInPictureStart by EventDispatcher<Unit>()
  val onPictureInPictureStop by EventDispatcher<Unit>()
  fun setAutoEnterPiP(enabled: Boolean) {
    autoEnterPiP = enabled
    if (playerId != 0) PlayerRegistry.session(playerId)?.autoEnterPiP = enabled
  }

  /**
   * Subscribes to the activity's PiP mode changes. ComponentActivity exposes
   * `addOnPictureInPictureModeChangedListener(Consumer)`, but this library
   * compiles against an old androidx.core (pinned by libVLC), so the
   * listener is wired through reflection rather than the typed API.
   */
  private fun registerPiPListener() {
    if (pipListener != null) return
    val activity = appContext.currentActivity
    android.util.Log.i("ExtendedVlcPlayer", "registerPiPListener activity=$activity playerId=$playerId")
    if (activity == null) return
    val add = activity.javaClass.methods.firstOrNull {
      it.name == "addOnPictureInPictureModeChangedListener" && it.parameterTypes.size == 1
    } ?: return
    val consumerType = add.parameterTypes[0]
    val listener = Proxy.newProxyInstance(consumerType.classLoader, arrayOf(consumerType)) { proxy, method, args ->
      when (method.name) {
        "accept" -> {
          android.util.Log.i("ExtendedVlcPlayer", "pip mode changed -> ${activity.isInPictureInPictureMode} playerId=$playerId")
          PlayerRegistry.session(playerId)?.setInPiP(activity.isInPictureInPictureMode)
          null
        }
        "equals" -> proxy === args?.getOrNull(0)
        "hashCode" -> System.identityHashCode(proxy)
        else -> null
      }
    }
    add.invoke(activity, listener)
    pipActivity = activity
    pipListener = listener
  }

  private fun unregisterPiPListener() {
    val activity = pipActivity
    val listener = pipListener
    pipActivity = null
    pipListener = null
    if (activity == null || listener == null) return
    activity.javaClass.methods.firstOrNull {
      it.name == "removeOnPictureInPictureModeChangedListener" && it.parameterTypes.size == 1
    }?.invoke(activity, listener)
  }

  fun setPlayer(id: Int) {
    if (playerId == id) {
      attachToSession()
      return
    }
    detachFromSession()
    playerId = id
    attachToSession()
  }

  fun setContentFit(value: String) {
    contentFit = value
    PlayerRegistry.session(playerId)?.setContentFit(value)
  }

  private fun attachToSession() {
    if (playerId == 0) return
    val session = PlayerRegistry.session(playerId) ?: return
    if (session.drawable.parent === this) return
    val drawable = session.drawable
    drawable.layoutParams = android.view.ViewGroup.LayoutParams(
      android.view.ViewGroup.LayoutParams.MATCH_PARENT,
      android.view.ViewGroup.LayoutParams.MATCH_PARENT
    )
    this.addView(drawable)
    if (width > 0 && height > 0) {
      drawable.measure(
        MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY),
        MeasureSpec.makeMeasureSpec(height, MeasureSpec.EXACTLY)
      )
      drawable.layout(0, 0, width, height)
    }
    PlayerRegistry.attachView(this, id)
    session.setContentFit(contentFit)
    post { session.attachSurfaceIfReady() }
    // Wire event sinks to forward to the JS dispatcher.
    session.onLoad = { payload -> onLoad(payload) }
    session.onTracksChanged = { payload -> onTracksChanged(payload) }
    session.onProgress = { payload -> onProgress(payload) }
    session.onPlaying = { payload -> onPlaying(payload) }
    session.onPaused = { payload -> onPaused(payload) }
    session.onEnded = { onEnded(Unit) }
    session.onError = { payload -> onError(payload) }
    session.onBuffering = { payload -> onBuffering(payload) }
    session.onPictureInPictureStart = { onPictureInPictureStart(Unit) }
    session.onPictureInPictureStop = { onPictureInPictureStop(Unit) }
    session.activityProvider = { appContext.currentActivity }
    registerPiPListener()
    session.autoEnterPiP = autoEnterPiP
    // A remounted JS component (the PiP resize can remount the screen) missed
    // the original event; replay the current state so it can hide its UI.
    if (session.isInPiP()) post { if (session.isInPiP()) onPictureInPictureStart(Unit) }
  }

  private fun detachFromSession() {
    if (playerId == 0) return
    val session = PlayerRegistry.session(playerId) ?: return
    this.removeView(session.drawable)
    // Disarm auto-enter first so leaving the player screen can't open PiP.
    session.autoEnterPiP = false
    unregisterPiPListener()
    session.activityProvider = null
    session.onLoad = null
    session.onTracksChanged = null
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
    detachFromSession()
    super.onDetachedFromWindow()
  }

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    attachToSession()
    registerPiPListener()
    post { PlayerRegistry.session(playerId)?.attachSurfaceIfReady() }
  }

  /**
   * React Native only lays out its own shadow-tree children; the native
   * SurfaceView we add ourselves would stay 0x0 (no surface, so audio plays
   * over a black screen) until some unrelated relayout. Size it explicitly.
   */
  override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
    val width = right - left
    val height = bottom - top
    for (i in 0 until childCount) {
      val child = getChildAt(i)
      child.measure(
        MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY),
        MeasureSpec.makeMeasureSpec(height, MeasureSpec.EXACTLY)
      )
      child.layout(0, 0, width, height)
    }
  }

  override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) {
    super.onSizeChanged(width, height, oldWidth, oldHeight)
    PlayerRegistry.session(playerId)?.updateVideoLayout(width, height)
    // Safety net: PiP is a window resize, so reconcile the flag here in case
    // the activity callback was missed (e.g. listener not registered yet).
    val inPiP = appContext.currentActivity?.isInPictureInPictureMode ?: return
    PlayerRegistry.session(playerId)?.setInPiP(inPiP)
  }
}

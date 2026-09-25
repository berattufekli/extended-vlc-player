package expo.modules.extendedvlcplayer

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.Context
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Rational
import android.view.SurfaceHolder
import android.view.SurfaceView
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.interfaces.IVLCVout

/**
 * One session per JS player. Owns the libVLC `MediaPlayer` and a
 * `SurfaceView` that the `ExtendedVlcPlayerView` adopts into its
 * view hierarchy.
 */
class PlayerSession(
  val id: Int,
  private val context: Context
) {
  private companion object {
    const val TAG = "ExtendedVlcPlayer"
  }

  private val surfaceView = SurfaceView(context)
  val drawable: SurfaceView get() = surfaceView

  // LibVLC appends its default audio/video options to this list while it
  // initializes. A Kotlin `listOf` is immutable and causes
  // UnsupportedOperationException inside LibVLC's constructor.
  private val libVlc = LibVLC(context, mutableListOf("--no-osd", "--no-stats"))
  val mediaPlayer = MediaPlayer(libVlc)

  // Event sinks. Wired up by the Fabric view component when the view
  // mounts; the player fires them on the main thread via `mediaPlayer.EventListener`.
  var onLoad: ((Map<String, Any>) -> Unit)? = null
  var onProgress: ((Map<String, Any>) -> Unit)? = null
  var onPlaying: ((Map<String, Any>) -> Unit)? = null
  var onPaused: ((Map<String, Any>) -> Unit)? = null
  var onEnded: (() -> Unit)? = null
  var onError: ((Map<String, Any>) -> Unit)? = null
  var onBuffering: ((Map<String, Any>) -> Unit)? = null
  var onPictureInPictureStart: (() -> Unit)? = null
  var onPictureInPictureStop: (() -> Unit)? = null

  private var currentMedia: Media? = null
  private var isAttached = false
  private var isInPiP = false
  private var contentFit = "contain"
  private val mainHandler = Handler(Looper.getMainLooper())
  private var durationSecondsCache = 0.0
  private var durationPollAttempts = 0
  private var pendingSeekSeconds: Double? = null
  private var didEmitDurationLoad = false
  private val durationPollRunnable = object : Runnable {
    override fun run() {
      val duration = readDurationSeconds()
      if (duration > 0) {
        durationSecondsCache = duration
        applyPendingSeekIfReady()
        emitDurationLoadIfReady()
        emitProgress()
        durationPollAttempts = 0
        return
      }

      durationPollAttempts += 1
      if (durationPollAttempts < 40) {
        mainHandler.postDelayed(this, 250L)
      } else {
        durationPollAttempts = 0
      }
    }
  }

  init {
    surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
      override fun surfaceCreated(holder: SurfaceHolder) {
        Log.i(TAG, "surfaceCreated id=$id")
        attachSurfaceIfReady()
      }

      override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

      override fun surfaceDestroyed(holder: SurfaceHolder) {
        Log.i(TAG, "surfaceDestroyed id=$id")
        val vout = mediaPlayer.getVLCVout()
        if (vout.areViewsAttached()) {
          vout.detachViews()
        }
        isAttached = false
      }
    })

    mediaPlayer.setEventListener { event ->
      when (event.type) {
        MediaPlayer.Event.Playing -> {
          Log.i(
            TAG,
            "event Playing id=$id length=${mediaPlayer.getLength()} videoTracks=${mediaPlayer.getVideoTracksCount()} audioTracks=${mediaPlayer.getAudioTracksCount()}"
          )
          durationSecondsCache = readDurationSeconds()
          applyPendingSeekIfReady()
          emitDurationLoadIfReady()
          onPlaying?.invoke(mapOf("duration" to durationSecondsCache))
          if (durationSecondsCache > 0) emitProgress() else scheduleDurationPolling()
        }
        MediaPlayer.Event.Paused -> onPaused?.invoke(emptyMap())
        MediaPlayer.Event.Stopped -> onEnded?.invoke()
        MediaPlayer.Event.EndReached -> onEnded?.invoke()
        MediaPlayer.Event.EncounteredError -> {
          Log.e(TAG, "event EncounteredError id=$id")
          onError?.invoke(
            mapOf(
              "message" to "libVLC error",
              "code" to "VLC_ERROR",
              "domain" to "libVLC"
            )
          )
        }
        MediaPlayer.Event.Buffering -> onBuffering?.invoke(mapOf("isBuffering" to (event.getBuffering() < 100.0f)))
        MediaPlayer.Event.Opening -> {
          Log.i(TAG, "event Opening id=$id")
          onLoad?.invoke(
            mapOf(
              "duration" to readDurationSeconds(),
              "audioTracks" to emptyList<Map<String, Any>>(),
              "textTracks" to emptyList<Map<String, Any>>()
            )
          )
          scheduleDurationPolling()
        }
        MediaPlayer.Event.TimeChanged -> {
          val duration = readDurationSeconds()
          if (duration > 0) {
            durationSecondsCache = duration
            emitDurationLoadIfReady()
          } else {
            scheduleDurationPolling()
          }
          applyPendingSeekIfReady()
          emitProgress()
        }
      }
    }
  }

  fun replace(uri: String) {
    Log.i(TAG, "replace id=$id scheme=${Uri.parse(uri).scheme} host=${Uri.parse(uri).host}")
    currentMedia?.release()
    val media = Media(libVlc, Uri.parse(uri))
    // IPTV HTTP/TS feeds are sensitive to short network jitter. Keep a
    // bounded live buffer and allow the HTTP access module to reconnect
    // without rebuilding the native player session.
    media.addOption(":network-caching=3000")
    media.addOption(":live-caching=3000")
    media.addOption(":http-reconnect=true")
    currentMedia = media
    mainHandler.removeCallbacks(durationPollRunnable)
    durationSecondsCache = 0.0
    durationPollAttempts = 0
    pendingSeekSeconds = null
    didEmitDurationLoad = false
    mediaPlayer.media = media
    mediaPlayer.play()
  }

  fun setContentFit(value: String) {
    contentFit = value
    mediaPlayer.setVideoScale(
      when (value) {
        "cover" -> MediaPlayer.ScaleType.SURFACE_FILL
        "fill" -> MediaPlayer.ScaleType.SURFACE_FIT_SCREEN
        else -> MediaPlayer.ScaleType.SURFACE_BEST_FIT
      }
    )
  }

  fun updateVideoLayout(width: Int, height: Int) {
    if (width <= 0 || height <= 0) return
    val vout = mediaPlayer.getVLCVout()
    if (vout.areViewsAttached()) {
      vout.setWindowSize(width, height)
    }
    if (surfaceView.holder.surface.isValid) {
      surfaceView.holder.setFixedSize(width, height)
    }
  }

  /**
   * Attaches the actual Android surface when it is available.
   *
   * SurfaceView callbacks can be delivered before or after the Fabric view
   * is adopted into the hierarchy, so callers also invoke this after adding
   * the child view. Keeping this operation idempotent prevents repeated VLC
   * output recreation during layout passes.
   */
  fun attachSurfaceIfReady() {
    val holder = surfaceView.holder
    if (!holder.surface.isValid || isAttached) {
      updateVideoLayout(surfaceView.width, surfaceView.height)
      return
    }

    val vout = mediaPlayer.getVLCVout()
    // Bind the holder's actual Surface directly. This avoids the LibVLC
    // window bridge path, which can fail under Expo/Fabric with
    // "request 1 not implemented" and leave audio playing over a black
    // video surface.
    vout.setVideoSurface(holder.surface, holder)
    vout.attachViews()
    isAttached = true
    updateVideoLayout(surfaceView.width, surfaceView.height)
  }

  private fun readDurationSeconds(): Double {
    val duration = mediaPlayer.getLength() / 1000.0
    return if (duration > 0) duration else durationSecondsCache
  }

  private fun emitDurationLoadIfReady() {
    if (durationSecondsCache <= 0 || didEmitDurationLoad) return
    didEmitDurationLoad = true
    onLoad?.invoke(
      mapOf(
        "duration" to durationSecondsCache,
        "audioTracks" to emptyList<Map<String, Any>>(),
        "textTracks" to emptyList<Map<String, Any>>()
      )
    )
  }

  private fun emitProgress() {
    val current = mediaPlayer.time / 1000.0
    val total = durationSecondsCache
    onProgress?.invoke(
      mapOf(
        "currentTime" to current,
        "duration" to total,
        "position" to (if (total > 0) current / total else 0.0)
      )
    )
  }

  private fun scheduleDurationPolling() {
    if (durationSecondsCache > 0 || durationPollAttempts > 0) return
    durationPollAttempts = 0
    mainHandler.post(durationPollRunnable)
  }

  private fun applyPendingSeekIfReady() {
    val target = pendingSeekSeconds ?: return
    if (mediaPlayer.getLength() <= 0 && !mediaPlayer.isPlaying) return
    mediaPlayer.time = (target * 1000).toLong()
    pendingSeekSeconds = null
  }

  fun play() = mediaPlayer.play()
  fun pause() = mediaPlayer.pause()
  fun stop() = mediaPlayer.stop()

  fun seekTo(seconds: Double) {
    val target = seconds.coerceAtLeast(0.0)
    pendingSeekSeconds = target
    applyPendingSeekIfReady()
  }

  fun setRate(rate: Float) {
    mediaPlayer.rate = rate.coerceIn(0.1f, 4.0f)
  }

  fun setVolume(volume: Float) {
    mediaPlayer.volume = (volume * 100).toInt() // libVLC volume is 0..100
  }

  fun setAudioTrack(index: Int) {
    val tracks = mediaPlayer.audioTracks ?: return
    if (index in tracks.indices) {
      val track = tracks[index]
      mediaPlayer.audioTrack = track.id
    } else if (index < 0) {
      mediaPlayer.audioTrack = -1
    }
  }

  fun setSubtitleTrack(index: Int) {
    val tracks = mediaPlayer.spuTracks ?: return
    if (index in tracks.indices) {
      val track = tracks[index]
      mediaPlayer.spuTrack = track.id
    } else if (index < 0) {
      mediaPlayer.spuTrack = -1
    }
  }

  fun isInPiP(): Boolean = isInPiP

  fun setInPiP(value: Boolean) {
    isInPiP = value
    if (value) onPictureInPictureStart?.invoke() else onPictureInPictureStop?.invoke()
  }

  fun requestExitPiP() {
    val activity = PlayerRegistry.currentActivity ?: return
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && activity.isInPictureInPictureMode) {
      val params = PictureInPictureParams.Builder()
        .setAspectRatio(Rational(16, 9))
        .build()
      activity.setPictureInPictureParams(params)
      activity.moveTaskToBack(false)
    }
  }

  fun release() {
    mainHandler.removeCallbacks(durationPollRunnable)
    val vout = mediaPlayer.getVLCVout()
    if (vout.areViewsAttached()) {
      vout.detachViews()
    }
    mediaPlayer.stop()
    currentMedia?.release()
    libVlc.release()
  }

}

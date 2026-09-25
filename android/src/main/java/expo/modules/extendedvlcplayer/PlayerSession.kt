package expo.modules.extendedvlcplayer

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.Context
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
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
          onPlaying?.invoke(mapOf("duration" to durationSeconds()))
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
              "duration" to durationSeconds(),
              "audioTracks" to emptyList<Map<String, Any>>(),
              "textTracks" to emptyList<Map<String, Any>>()
            )
          )
        }
        MediaPlayer.Event.TimeChanged -> onProgress?.invoke(
          mapOf(
            "currentTime" to (event.getTimeChanged() / 1000.0),
            "duration" to durationSeconds(),
            "position" to (if (mediaPlayer.getLength() > 0) event.getTimeChanged().toDouble() / mediaPlayer.getLength() else 0.0)
          )
        )
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

  private fun durationSeconds(): Double = mediaPlayer.getLength() / 1000.0

  fun play() = mediaPlayer.play()
  fun pause() = mediaPlayer.pause()
  fun stop() = mediaPlayer.stop()

  fun seekTo(seconds: Double) {
    mediaPlayer.time = (seconds * 1000).toLong()
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
    val vout = mediaPlayer.getVLCVout()
    if (vout.areViewsAttached()) {
      vout.detachViews()
    }
    mediaPlayer.stop()
    currentMedia?.release()
    libVlc.release()
  }

}

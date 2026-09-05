package expo.modules.extendedvlcplayer

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.Context
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
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
  private val surfaceView = SurfaceView(context)
  val drawable: SurfaceView get() = surfaceView

  private val libVlc: LibVLC = LibVLC(context, listOf("--no-osd", "--no-stats"))
  val mediaPlayer: MediaPlayer = MediaPlayer(libVlc)

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

  init {
    surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
      override fun surfaceCreated(holder: SurfaceHolder) {
        mediaPlayer.vout.setVideoSurface(holder.surface, surfaceView.holder)
        if (!isAttached) {
          mediaPlayer.attachViews(arrayOf<Any>(surfaceView).toJavaArray())
          isAttached = true
        }
        mediaPlayer.play()
      }

      override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

      override fun surfaceDestroyed(holder: SurfaceHolder) {
        mediaPlayer.vout.setVideoSurface(null, null)
      }
    })

    mediaPlayer.setEventListener { event ->
      when (event.type) {
        MediaPlayer.Event.Playing -> onPlaying?.invoke(mapOf("duration" to (event.durationMs / 1000.0)))
        MediaPlayer.Event.Paused -> onPaused?.invoke(emptyMap())
        MediaPlayer.Event.Stopped -> onEnded?.invoke()
        MediaPlayer.Event.EndReached -> onEnded?.invoke()
        MediaPlayer.Event.EncounteredError -> onError?.invoke(
          mapOf(
            "message" to (event.escapedVlcError ?: "libVLC error"),
            "code" to "VLC_ERROR",
            "domain" to "libVLC"
          )
        )
        MediaPlayer.Event.Buffering -> onBuffering?.invoke(mapOf("isBuffering" to event.buffering.toDouble() < 100.0))
        MediaPlayer.Event.Opening -> onLoad?.invoke(
          mapOf(
            "duration" to (event.durationMs / 1000.0),
            "audioTracks" to emptyList<Map<String, Any>>(),
            "textTracks" to emptyList<Map<String, Any>>()
          )
        )
        MediaPlayer.Event.TimeChanged -> onProgress?.invoke(
          mapOf(
            "currentTime" to (event.timeChanged / 1000.0),
            "duration" to (event.durationMs / 1000.0),
            "position" to (if (event.durationMs > 0) event.timeChanged.toDouble() / event.durationMs else 0.0)
          )
        )
      }
    }
  }

  fun replace(uri: String) {
    currentMedia?.release()
    val media = Media(libVlc, Uri.parse(uri))
    currentMedia = media
    mediaPlayer.media = media
  }

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
    mediaPlayer.stop()
    currentMedia?.release()
    libVlc.release()
  }
}

// Helper to convert Kotlin Array to Java Array (libVLC's attachViews is Java).
private inline fun <reified T> Array<out T>.toJavaArray(): Array<T> = this as Array<T>

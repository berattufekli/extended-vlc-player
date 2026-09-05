package expo.modules.extendedvlcplayer

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

/**
 * TurboModule for `extended-vlc-player` on Android.
 *
 * Note: VLC playback itself happens inside the `ExtendedVlcPlayerView`
 * (which hosts libVLC's `SurfaceView`). This module just exposes the
 * TurboModule methods that the JS side calls; picture-in-picture
 * activation goes through the host activity because Android requires
 * the activity to be in resumed state to enter PiP.
 */
class ExtendedVlcPlayerModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("ExtendedVlcPlayer")

    AsyncFunction("isPictureInPictureSupported") {
      Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
        appContext.activity?.application?.packageManager?.hasSystemFeature(
          android.content.pm.PackageManager.FEATURE_PICTURE_IN_PICTURE
        ) == true
    }

    AsyncFunction("isPictureInPictureActive") { instanceId: Int ->
      PlayerRegistry.session(instanceId)?.isInPiP() ?: false
    }

    AsyncFunction("play") { instanceId: Int ->
      PlayerRegistry.session(instanceId)?.play()
    }

    AsyncFunction("pause") { instanceId: Int ->
      PlayerRegistry.session(instanceId)?.pause()
    }

    AsyncFunction("stop") { instanceId: Int ->
      PlayerRegistry.session(instanceId)?.stop()
    }

    AsyncFunction("seek") { instanceId: Int, seconds: Double ->
      PlayerRegistry.session(instanceId)?.seekTo(seconds)
    }

    AsyncFunction("setRate") { instanceId: Int, rate: Double ->
      PlayerRegistry.session(instanceId)?.setRate(rate.toFloat())
    }

    AsyncFunction("setVolume") { instanceId: Int, volume: Double ->
      PlayerRegistry.session(instanceId)?.setVolume(volume.toFloat().coerceIn(0f, 1f))
    }

    AsyncFunction("setAudioTrack") { instanceId: Int, index: Int ->
      PlayerRegistry.session(instanceId)?.setAudioTrack(index)
    }

    AsyncFunction("setSubtitleTrack") { instanceId: Int, index: Int ->
      PlayerRegistry.session(instanceId)?.setSubtitleTrack(index)
    }

    AsyncFunction("replace") { instanceId: Int, payload: ReplacePayload ->
      val session = PlayerRegistry.session(instanceId) ?: return@AsyncFunction
      val url = if (payload.uri.startsWith("http://") || payload.uri.startsWith("https://") || payload.uri.startsWith("file://")) {
        payload.uri
      } else {
        "https://${payload.uri}"
      }
      session.replace(url)
    }

    AsyncFunction("startPictureInPicture") { instanceId: Int ->
      val activity = appContext.activity ?: return@AsyncFunction false
      val session = PlayerRegistry.session(instanceId) ?: return@AsyncFunction false
      if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return@AsyncFunction false
      val params = PictureInPictureParams.Builder()
        .setAspectRatio(Rational(16, 9))
        .build()
      return@AsyncFunction activity.enterPictureInPictureMode(params)
    }

    AsyncFunction("stopPictureInPicture") { instanceId: Int ->
      val session = PlayerRegistry.session(instanceId) ?: return@AsyncFunction false
      session.requestExitPiP()
      return@AsyncFunction true
    }
  }
}

class ReplacePayload(
  val uri: String,
  val instanceId: Int = 0
)

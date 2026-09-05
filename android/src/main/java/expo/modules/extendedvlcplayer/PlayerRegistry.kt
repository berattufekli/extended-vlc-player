package expo.modules.extendedvlcplayer

import android.app.Activity
import android.content.Context
import android.content.pm.ActivityInfo
import android.content.res.Configuration

/**
 * Process-wide registry of active player sessions, keyed by the integer
 * id allocated by the JS hook.
 */
object PlayerRegistry {
  private val sessions = mutableMapOf<Int, PlayerSession>()
  private val sessionIdsByView = mutableMapOf<android.view.View, Int>()
  @Volatile var currentActivity: Activity? = null

  @Synchronized
  fun create(context: Context): Pair<Int, PlayerSession> {
    val id = (sessions.keys.maxOrNull() ?: 0) + 1
    val session = PlayerSession(id, context.applicationContext)
    sessions[id] = session
    return id to session
  }

  @Synchronized
  fun get(id: Int): PlayerSession? = sessions[id]

  @Synchronized
  fun destroy(id: Int) {
    val session = sessions.remove(id) ?: return
    val view = sessionIdsByView.entries.firstOrNull { it.value == id }?.key
    if (view != null) sessionIdsByView.remove(view)
    session.release()
  }

  @Synchronized
  fun attachView(view: android.view.View, id: Int) {
    sessionIdsByView[view] = id
  }

  @Synchronized
  fun detachView(view: android.view.View) {
    sessionIdsByView.remove(view)
  }

  fun session(id: Int): PlayerSession? = get(id)
}

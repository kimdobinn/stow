package dev.stow.android.remote

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import androidx.core.app.NotificationCompat
import dev.stow.android.MainActivity
import dev.stow.android.R
import dev.stow.android.StowApplication
import dev.stow.android.data.AlarmPush
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONObject

/** The lock-screen notification while the Mac's alarm plays: I'm awake, pause/play, volume. */
object AlarmNotification {
    const val CHANNEL = "alarm-remote"
    private const val ID = 48261

    /** Silent (the Mac is the alarm), but high importance so it shows on the lock screen. */
    fun createChannel(context: Context) {
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "Alarm remote", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Controls for the Mac's morning alarm while it plays"
                setSound(null, null)
                enableVibration(false)
                lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
            })
    }

    /** Posts or refreshes it; [state] (when known) fills in the video and the pause/play label. */
    fun show(context: Context, macName: String, state: AlarmState? = null, note: String? = null) {
        val title = "Alarm playing on $macName"
        val text = note ?: when {
            state?.phase == AlarmPhase.ALARM_SOUND -> "Alarm sound playing"
            state?.phase == AlarmPhase.PREPARING -> "Getting ready…"
            state?.video != null -> state.video.title
            else -> "Tap for the remote"
        }
        val playerControls = state == null || state.phase.hasPlayer
        val views = RemoteViews(context.packageName, R.layout.notification_alarm).apply {
            setTextViewText(R.id.title, title)
            setTextViewText(R.id.text, text)
            setTextViewText(R.id.toggle, if (state?.isPaused == true) "Play" else "Pause")
            setViewVisibility(R.id.toggle, if (playerControls) View.VISIBLE else View.GONE)
            setOnClickPendingIntent(R.id.stop, action(context, AlarmActionReceiver.STOP))
            setOnClickPendingIntent(R.id.toggle, action(context, AlarmActionReceiver.TOGGLE))
            setOnClickPendingIntent(R.id.volume_down, action(context, AlarmActionReceiver.VOLUME_DOWN))
            setOnClickPendingIntent(R.id.volume_up, action(context, AlarmActionReceiver.VOLUME_UP))
        }
        // Its own action and request code: the player's notification has a MainActivity intent too,
        // and PendingIntents that only differ in extras would be the same one.
        val open = PendingIntent.getActivity(context, ID,
            Intent(context, MainActivity::class.java).setAction(MainActivity.ACTION_OPEN_REMOTE)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_stow)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.DecoratedCustomViewStyle())
            .setCustomBigContentView(views)
            .setContentIntent(open)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            // Pushes are best effort: if "ended" never comes, it still goes away.
            .setTimeoutAfter(AlarmPush.MAX_AGE_MS)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .build()
        runCatching { context.getSystemService(NotificationManager::class.java).notify(ID, notification) }
            .onFailure { Log.w("Stow", "Alarm notification not shown", it) }
    }

    fun cancel(context: Context) {
        context.getSystemService(NotificationManager::class.java).cancel(ID)
    }

    /**
     * The Mac's "alarm" push: "playing" shows the remote, "ended" takes it away. [sentAt] is
     * FCM's send time (0 when unknown); a "playing" sent before the last "ended" is ignored.
     */
    fun onPush(context: Context, data: Map<String, String>, sentAt: Long) {
        val prefs = (context.applicationContext as StowApplication).repository.prefs
        when (data["state"]) {
            "playing" -> {
                if (sentAt in 1..prefs.alarmEndedSentAt) return
                val alarm = AlarmPush(
                    hosts = data["hosts"].orEmpty().split(",").map { it.trim() }.filter { it.isNotEmpty() },
                    port = data["port"]?.toIntOrNull() ?: AlarmPush.DEFAULT_PORT,
                    macName = data["macName"]?.takeIf { it.isNotBlank() } ?: "the Mac",
                    at = System.currentTimeMillis(),
                )
                prefs.saveAlarm(alarm)
                show(context, alarm.macName)
            }
            "ended" -> {
                val endedAt = sentAt.takeIf { it > 0 } ?: System.currentTimeMillis()
                prefs.alarmEndedSentAt = maxOf(prefs.alarmEndedSentAt, endedAt)
                prefs.clearAlarm()
                cancel(context)
            }
        }
    }

    private fun action(context: Context, name: String): PendingIntent = PendingIntent.getBroadcast(
        context, name.hashCode(), Intent(context, AlarmActionReceiver::class.java).setAction(name),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
}

/** The notification's buttons, sent to the Mac without opening the app. */
class AlarmActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext as StowApplication
        val action = intent.action ?: return
        val pending = goAsync()
        scope.launch {
            // A broadcast gets about ten seconds; the client starts no attempt it can't finish by then.
            val deadline = SystemClock.elapsedRealtime() + 9_000
            try {
                perform(app, action, deadline)
            } catch (e: RemoteException.Rejected) {
                failed(app, e.message)
            } catch (e: Exception) {
                Log.i("Stow", "Alarm action $action failed: ${e.message}")
                failed(app, "Couldn't reach the Mac. Phone and Mac must be on the same Wi-Fi.")
            } finally {
                pending.finish()
            }
        }
    }

    /** Shows why, unless the run ended meanwhile (its "ended" push already took the notification away). */
    private fun failed(app: StowApplication, note: String?) {
        val alarm = app.repository.prefs.alarm.value?.takeIf { it.isRecent() }
        if (alarm != null) AlarmNotification.show(app, alarm.macName, note = note) else AlarmNotification.cancel(app)
    }

    private suspend fun perform(app: StowApplication, action: String, deadline: Long) {
        val client = app.remoteClient
        val after = when (action) {
            STOP -> client.act(JSONObject().put("action", "stop"), deadline)
            TOGGLE -> {
                val now = client.state(deadline)
                client.act(JSONObject().put("action", "setPaused").put("paused", !now.isPaused), deadline)
            }
            VOLUME_DOWN, VOLUME_UP -> {
                val now = client.state(deadline)
                val volume = now.volume ?: throw RemoteException.Rejected(409, "The Mac can't read its speaker's volume.")
                val step = if (action == VOLUME_UP) RemoteModel.VOLUME_STEP else -RemoteModel.VOLUME_STEP
                client.act(JSONObject().put("action", "setVolume").put("volume", (volume + step).coerceIn(0, 100)), deadline)
            }
            else -> return
        }
        if (action == STOP || after.finished) {
            app.repository.prefs.clearAlarm()
            AlarmNotification.cancel(app)
        } else {
            val note = if (action == TOGGLE) null else after.volume?.let { "Volume $it" }
            AlarmNotification.show(app, after.macName, after, note)
        }
    }

    companion object {
        const val STOP = "dev.stow.android.alarm.STOP"
        const val TOGGLE = "dev.stow.android.alarm.TOGGLE"
        const val VOLUME_DOWN = "dev.stow.android.alarm.VOLUME_DOWN"
        const val VOLUME_UP = "dev.stow.android.alarm.VOLUME_UP"
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    }
}

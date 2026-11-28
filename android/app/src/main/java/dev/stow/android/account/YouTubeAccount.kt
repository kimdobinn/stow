package dev.stow.android.account

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import dev.stow.android.MainActivity
import dev.stow.android.R

/**
 * The phone's own YouTube sign-in (standalone mode). Its state machine (signed out, signed in,
 * signed out by YouTube) lives in the engine (standalone/Standalone) and standalone.json; the
 * cookies in [CookieVault]. This is the Android side: the notification when YouTube signs you out.
 */
object AccountNotification {
    const val CHANNEL = "account"
    private const val ID = 0x5701

    fun createChannel(context: Context) {
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "YouTube sign-in", NotificationManager.IMPORTANCE_DEFAULT))
    }

    /** Once per expiry: tapping it opens Settings. */
    fun show(context: Context) {
        val open = PendingIntent.getActivity(context, ID,
            Intent(context, MainActivity::class.java).setAction(MainActivity.ACTION_OPEN_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_stow)
            .setContentTitle("YouTube signed you out of Stow")
            .setContentText("Sign in again in Settings for Home, Subscriptions and members-only videos.")
            .setStyle(NotificationCompat.BigTextStyle().bigText("Sign in again in Settings for Home, Subscriptions and members-only videos."))
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        runCatching { context.getSystemService(NotificationManager::class.java).notify(ID, notification) }
    }

    fun cancel(context: Context) {
        runCatching { context.getSystemService(NotificationManager::class.java).cancel(ID) }
    }
}

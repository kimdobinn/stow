package dev.stow.android.update

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import dev.stow.android.StowApplication

/** The package installer's answers about an update session (confirm screen, done, failed). */
class InstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) return
        (context.applicationContext as StowApplication).updater.onInstallStatus(intent)
    }

    companion object {
        const val ACTION = "dev.stow.android.UPDATE_STATUS"
    }
}

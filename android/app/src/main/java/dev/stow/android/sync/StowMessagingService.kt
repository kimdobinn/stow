package dev.stow.android.sync

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import dev.stow.android.StowApplication
import dev.stow.android.remote.AlarmNotification

/**
 * The Mac's high-priority pushes: "videos" and "sync" wake the phone to fetch and download;
 * "alarm" says the morning alarm started or ended (the remote, nothing to download).
 */
class StowMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        // Only a paired phone listens to the Mac (a late push after switching to standalone does nothing).
        if (!(application as StowApplication).repository.isPaired) return
        val type = message.data["type"]
        android.util.Log.i("Stow", "Push from the Mac: $type")
        if (type == "alarm") AlarmNotification.onPush(this, message.data, message.sentTime) else SyncWorker.runNow(this)
    }

    override fun onNewToken(token: String) {
        (application as StowApplication).repository.onNewPushToken(token)
    }
}

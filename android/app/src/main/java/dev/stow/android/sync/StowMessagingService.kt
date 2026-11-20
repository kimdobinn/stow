package dev.stow.android.sync

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import dev.stow.android.StowApplication

/** The Mac's high-priority pushes ("videos", "sync") wake the phone to fetch and download. */
class StowMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        android.util.Log.i("Stow", "Push from the Mac: ${message.data["type"]}")
        SyncWorker.runNow(this)
    }

    override fun onNewToken(token: String) {
        (application as StowApplication).repository.onNewPushToken(token)
    }
}

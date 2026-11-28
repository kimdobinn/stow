package dev.stow.android

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import dev.stow.android.data.Repository
import dev.stow.android.player.PlayerConnection
import dev.stow.android.remote.AlarmNotification
import dev.stow.android.remote.RemoteClient
import dev.stow.android.sync.SyncWorker
import dev.stow.android.sync.YtDlp
import dev.stow.android.update.Updater
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ProcessLifecycleOwner
import dev.stow.android.standalone.CheckWorker
import dev.stow.android.standalone.Trigger

class StowApplication : Application() {
    lateinit var repository: Repository
        private set
    /** Created on first use (it binds to the playback service). */
    val player: PlayerConnection by lazy { PlayerConnection(this, repository) }
    /** The Mac's alarm remote, shared by the remote screen and the alarm notification. */
    val remoteClient: RemoteClient by lazy { RemoteClient(this, repository.prefs) }
    /** Checks GitHub for a newer version of the app and installs it. */
    val updater: Updater by lazy { Updater(this, repository.prefs) }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_DOWNLOADS, "Downloads", NotificationManager.IMPORTANCE_LOW))
        AlarmNotification.createChannel(this)
        dev.stow.android.account.AccountNotification.createChannel(this)
        repository = Repository(this)
        repository.start()
        // Also carries the daily update check; it reads nothing from Firebase unless paired.
        SyncWorker.schedule(this)
        if (repository.isPaired) SyncWorker.runNow(this)
        if (repository.isStandalone) {
            scope.launch { repository.standalone.checkIfDue(Trigger.LAUNCH) }
        } else {
            CheckWorker.cancel(this)
        }
        // Back on screen: standalone checks the channels if it's been 15 minutes.
        ProcessLifecycleOwner.get().lifecycle.addObserver(LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_START && repository.isStandalone) {
                scope.launch { repository.standalone.checkIfDue(Trigger.FOREGROUND) }
            }
        })
        scope.launch {
            runCatching { YtDlp.ensureReady(this@StowApplication) }
            YtDlp.updateIfDue(this@StowApplication, repository.prefs)
        }
    }

    companion object {
        const val CHANNEL_DOWNLOADS = "downloads"
    }
}

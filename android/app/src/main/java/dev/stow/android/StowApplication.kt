package dev.stow.android

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import dev.stow.android.data.Repository
import dev.stow.android.player.PlayerConnection
import dev.stow.android.sync.SyncWorker
import dev.stow.android.sync.YtDlp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class StowApplication : Application() {
    lateinit var repository: Repository
        private set
    /** Created on first use (it binds to the playback service). */
    val player: PlayerConnection by lazy { PlayerConnection(this, repository) }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_DOWNLOADS, "Downloads", NotificationManager.IMPORTANCE_LOW))
        repository = Repository(this)
        repository.start()
        SyncWorker.schedule(this)
        if (repository.isPaired) SyncWorker.runNow(this)
        scope.launch {
            runCatching { YtDlp.ensureReady(this@StowApplication) }
            YtDlp.updateIfDue(this@StowApplication, repository.prefs)
        }
    }

    companion object {
        const val CHANNEL_DOWNLOADS = "downloads"
    }
}

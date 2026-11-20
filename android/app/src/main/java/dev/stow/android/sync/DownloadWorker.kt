package dev.stow.android.sync

import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.media.MediaMetadataRetriever
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import dev.stow.android.R
import dev.stow.android.StowApplication
import dev.stow.android.data.DownloadState
import dev.stow.android.data.LocalVideo
import dev.stow.android.data.Remote
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CancellationException

/** Downloads one video with yt-dlp as a foreground job, reporting progress to the Mac. */
class DownloadWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    private val repository = (context.applicationContext as StowApplication).repository
    private val notificationId = (inputData.getString(KEY_ID) ?: "").hashCode()

    override suspend fun doWork(): Result {
        val id = inputData.getString(KEY_ID) ?: return Result.failure()
        val video = runCatching { repository.findVideo(id) }.getOrElse { e ->
            return if (e is Remote.NotPaired) Result.failure() else Result.retry()
        } ?: return Result.failure()
        val existing = repository.local[id]
        if (existing?.state == DownloadState.DOWNLOADED && existing.filePath?.let { File(it).exists() } == true) return Result.success()
        if (existing?.state == DownloadState.DELETED) return Result.success()

        setForeground(foregroundInfo(video.title, 0))
        repository.local.update(id) { (it ?: LocalVideo(id, DownloadState.QUEUED)).copy(state = DownloadState.DOWNLOADING, progress = 0, error = null) }
        runCatching { repository.remote.reportDownload(id, "downloading") }

        // Cookies only for members-only videos: sharing the session from a second IP more than
        // needed risks YouTube rotating it on the Mac too.
        val cookies = if (video.isMembersOnly) cookiesFile() else null
        try {
            var lastShown = 0L
            val file = YtDlp.download(applicationContext, video, cookies) { percent ->
                repository.local.update(id) { it?.copy(progress = percent) }
                val now = System.currentTimeMillis()
                if (now - lastShown > 1_000) {
                    lastShown = now
                    notificationManager().notify(notificationId, notification(video.title, percent))
                }
            }
            repository.local.update(id) {
                (it ?: LocalVideo(id, DownloadState.DOWNLOADED)).copy(
                    state = DownloadState.DOWNLOADED, progress = 100, error = null, filePath = file.absolutePath,
                    sizeBytes = file.length(), durationMs = durationMs(file), downloadedAt = System.currentTimeMillis())
            }
            runCatching { repository.remote.reportDownload(id, "downloaded") }
            return Result.success()
        } catch (e: CancellationException) {
            YtDlp.cancel(id)
            repository.local.update(id) { it?.takeIf { v -> v.state == DownloadState.DOWNLOADING }?.copy(state = DownloadState.QUEUED) ?: it }
            throw e
        } catch (e: Exception) {
            val message = e.message ?: e.javaClass.simpleName
            Log.w("Stow", "Download $id failed (attempt $runAttemptCount): $message")
            if (runAttemptCount < MAX_RETRIES) {
                repository.local.update(id) { it?.copy(state = DownloadState.QUEUED, error = message) }
                return Result.retry()
            }
            repository.local.update(id) { it?.copy(state = DownloadState.FAILED, error = message) }
            runCatching { repository.remote.reportDownload(id, "failed", message) }
            return Result.failure()
        } finally {
            cookies?.delete()
        }
    }

    private suspend fun cookiesFile(): File? {
        val key = repository.prefs.pairingKey ?: return null
        val data = runCatching { repository.remote.cookies(key) }.onFailure { Log.w("Stow", "No cookies", it) }.getOrNull() ?: return null
        return File(applicationContext.cacheDir, "cookies-${UUID.randomUUID()}.txt").apply { writeBytes(data) }
    }

    private fun durationMs(file: File): Long = runCatching {
        MediaMetadataRetriever().use { retriever ->
            retriever.setDataSource(file.absolutePath)
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLong() ?: 0
        }
    }.getOrDefault(0)

    override suspend fun getForegroundInfo(): ForegroundInfo = foregroundInfo("Downloading", 0)

    private fun foregroundInfo(title: String, percent: Int) =
        ForegroundInfo(notificationId, notification(title, percent), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)

    private fun notification(title: String, percent: Int): Notification =
        NotificationCompat.Builder(applicationContext, StowApplication.CHANNEL_DOWNLOADS)
            .setSmallIcon(R.drawable.ic_stat_stow)
            .setContentTitle(title)
            .setContentText(if (percent > 0) "Downloading · $percent%" else "Starting download…")
            .setProgress(100, percent, percent == 0)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .build()

    private fun notificationManager() = applicationContext.getSystemService(NotificationManager::class.java)

    companion object {
        const val KEY_ID = "id"
        const val TAG = "download"
        const val MAX_RETRIES = 3
    }
}

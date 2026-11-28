package dev.stow.android.sync

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import dev.stow.android.StowApplication
import dev.stow.android.data.Remote
import java.util.concurrent.TimeUnit

/** Reads the Mac's videos and queues downloads. Runs on each push and hourly as a fallback. */
class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val app = applicationContext as StowApplication
        val repository = app.repository
        // At most once a day, so the dot on the settings button is there before you open the app.
        app.updater.checkIfDue()
        // Only a paired phone in Mac mode has anything to read (standalone never touches Firebase).
        // Switched to standalone (or unpaired) while this ran: it stops there, its answer unused.
        val era = repository.modeEra
        if (repository.mode.value != dev.stow.android.standalone.AppMode.MAC || !repository.stillPaired(era) || repository.demo) return Result.success()
        return try {
            val videos = repository.remote.fetchVideos()
            if (!repository.stillPaired(era)) return Result.success()
            android.util.Log.i("Stow", "Sync: ${videos.size} videos from the Mac")
            repository.onSentVideos(videos)
            Result.success()
        } catch (e: Remote.NotPaired) {
            if (repository.stillPaired(era) && !repository.remote.isMember() && repository.stillPaired(era)) {
                repository.unpair("The Mac unpaired this phone.")
            }
            Result.success()
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            if (repository.stillPaired(era)) Result.retry() else Result.success()
        }
    }

    companion object {
        private val online = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()

        /** Right away (a push from the Mac): expedited, so it runs even in Doze. */
        fun runNow(context: Context) {
            val request = OneTimeWorkRequestBuilder<SyncWorker>()
                .setConstraints(online)
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork("sync-now", ExistingWorkPolicy.REPLACE, request)
        }

        /** Leaving Mac mode: a sync waiting or under way stops (it would read Firebase). The hourly one stays; it only checks for updates outside Mac mode. */
        fun stopNow(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork("sync-now")
        }

        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<SyncWorker>(1, TimeUnit.HOURS).setConstraints(online).build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork("sync-hourly", ExistingPeriodicWorkPolicy.KEEP, request)
        }
    }
}

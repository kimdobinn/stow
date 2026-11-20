package dev.stow.android.sync

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.workDataOf
import java.util.concurrent.TimeUnit

/** One WorkManager job per video, waiting for Wi-Fi (or any network) as set. */
object Downloads {
    private fun name(id: String) = "download-$id"

    fun enqueue(context: Context, id: String, wifiOnly: Boolean, replace: Boolean = false) {
        val request = OneTimeWorkRequestBuilder<DownloadWorker>()
            .setInputData(workDataOf(DownloadWorker.KEY_ID to id))
            .setConstraints(Constraints.Builder()
                .setRequiredNetworkType(if (wifiOnly) NetworkType.UNMETERED else NetworkType.CONNECTED)
                .setRequiresStorageNotLow(true)
                .build())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 2, TimeUnit.MINUTES)
            .addTag(DownloadWorker.TAG)
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(
            name(id), if (replace) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.KEEP, request)
    }

    fun cancel(context: Context, id: String) {
        WorkManager.getInstance(context).cancelUniqueWork(name(id))
        YtDlp.cancel(id)
    }
}

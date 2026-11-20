package dev.stow.android.data

import java.util.Date

/** A video the Mac sent (videos/{id} in Firestore). */
data class RemoteVideo(
    val id: String,
    val channelId: String,
    val channelTitle: String,
    val title: String,
    val publishedAt: Date?,
    val thumbnailUrl: String?,
    val isMembersOnly: Boolean,
    val sentAt: Date?,
    val watched: Boolean,
) {
    val watchUrl: String get() = "https://www.youtube.com/watch?v=$id"
}

/** A channel the Mac follows (channels/{id}). */
data class Channel(val id: String, val title: String, val avatarUrl: String?, val order: Int)

enum class DownloadState { QUEUED, DOWNLOADING, DOWNLOADED, FAILED, DELETED }

/** What this phone did with a video; kept on the phone only. */
data class LocalVideo(
    val id: String,
    val state: DownloadState,
    /** 0…100 while downloading. */
    val progress: Int = 0,
    val error: String? = null,
    val filePath: String? = null,
    val sizeBytes: Long = 0,
    val durationMs: Long = 0,
    val positionMs: Long = 0,
    /** The Mac's sentAt this state belongs to; a newer one ("Send to Phone Again") retries. */
    val sentAt: Long = 0,
    val updatedAt: Long = System.currentTimeMillis(),
)

/** A video as the library shows it. */
data class VideoItem(val remote: RemoteVideo, val local: LocalVideo?) {
    val id: String get() = remote.id
    val state: DownloadState get() = local?.state ?: DownloadState.QUEUED
    val isPlayable: Boolean get() = local?.state == DownloadState.DOWNLOADED && local.filePath != null
}

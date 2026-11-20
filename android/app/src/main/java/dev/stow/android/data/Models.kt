package dev.stow.android.data

import java.util.Date

/** A YouTube video, as the Mac describes it. */
data class Video(
    val id: String,
    val channelId: String,
    val channelTitle: String,
    val title: String,
    val publishedAt: Date?,
    val thumbnailUrl: String?,
    val isMembersOnly: Boolean,
    val liveStatus: String? = null,
) {
    val watchUrl: String get() = "https://www.youtube.com/watch?v=$id"
}

/** A video sent to the phone (videos/{id}): by the Mac, or by the phone from a channel page. */
data class SentVideo(val video: Video, val sentAt: Date?, val sentBy: String?, val watched: Boolean)

/** A channel the Mac follows (channels/{id}) with its newest videos. */
data class Channel(
    val id: String,
    val title: String,
    val handle: String?,
    val avatarUrl: String?,
    /** New uploads download to the phone automatically. */
    val autoDownload: Boolean,
    val order: Int,
    /** Newest first. */
    val recent: List<RecentVideo>,
)

data class RecentVideo(val video: Video, val watched: Boolean)

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
    /** The sentAt this state belongs to; a newer one ("Send to Phone Again") retries. */
    val sentAt: Long = 0,
    val downloadedAt: Long = 0,
    val updatedAt: Long = System.currentTimeMillis(),
)

/** A video as the app shows it: what it is, whether it was sent, and what the phone has. */
data class VideoItem(val video: Video, val sent: SentVideo?, val local: LocalVideo?, val watchedOnMac: Boolean) {
    val id: String get() = video.id
    val watched: Boolean get() = sent?.watched ?: watchedOnMac
    /** null when it was never downloaded (or the download was deleted). */
    val state: DownloadState? get() = local?.state?.takeIf { it != DownloadState.DELETED }
    val isPlayable: Boolean get() = local?.state == DownloadState.DOWNLOADED && local.filePath != null
    val isDownloading: Boolean get() = state == DownloadState.QUEUED || state == DownloadState.DOWNLOADING
    val durationMs: Long get() = local?.durationMs ?: 0
    /** How far you got, 0…1 (1 once watched). */
    val progress: Float
        get() = when {
            watched -> 1f
            local != null && local.durationMs > 0 -> (local.positionMs.toFloat() / local.durationMs).coerceIn(0f, 1f)
            else -> 0f
        }
}

/** A list of videos you made on the phone. */
data class Playlist(val id: String, val name: String, val videoIds: List<String>, val createdAt: Long)

enum class DownloadSort(val label: String) {
    RECENTLY_DOWNLOADED("Recently downloaded"),
    NEWEST("Upload date (newest)"),
    OLDEST("Upload date (oldest)"),
    CHANNEL("Channel (A–Z)"),
    LONGEST("Length (longest)"),
    SHORTEST("Length (shortest)"),
    TITLE("Title (A–Z)"),
}

enum class WatchFilter(val label: String) { ALL("All"), UNWATCHED("Unwatched"), WATCHED("Watched") }

package dev.stow.android.data

import java.util.Date
import org.json.JSONObject

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
    /** Known up front only for videos from YouTube's own feeds. */
    val durationSeconds: Long? = null,
) {
    val watchUrl: String get() = "https://www.youtube.com/watch?v=$id"
    /** A finished live stream ("Streamed"). */
    val isPastStream: Boolean get() = liveStatus == "wasLive" || liveStatus == "was_live"
    /** YouTube Shorts are never shown: anything this short counts as one. */
    val isShort: Boolean get() = durationSeconds != null && durationSeconds in 1..SHORTS_MAX_SECONDS

    companion object {
        const val SHORTS_MAX_SECONDS = 60L
    }
}

/** A named set of channels (shared/phone): Home can show just their videos. */
data class ChannelGroup(val id: String, val name: String, val channels: List<GroupChannel>) {
    val channelIds: Set<String> get() = channels.mapTo(HashSet()) { it.id }
}

data class GroupChannel(val id: String, val title: String)

/** A video sent to the phone (videos/{id}): by the Mac, or by the phone from a channel page. */
data class SentVideo(val video: Video, val sentAt: Date?, val sentBy: String?, val watched: Boolean)

/** A channel the Mac follows (channels/{id}) with its newest videos. */
data class Channel(
    val id: String,
    val title: String,
    val handle: String?,
    val avatarUrl: String?,
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
data class VideoItem(
    val video: Video, val sent: SentVideo?, val local: LocalVideo?, val watchedOnMac: Boolean,
    /** Only in YouTube's Home or Subscriptions feed: not from a Stow channel, never sent. */
    val onlyInYouTubeFeeds: Boolean = false,
) {
    val id: String get() = video.id
    val watched: Boolean get() = sent?.watched ?: watchedOnMac
    /** null when it was never downloaded (or the download was deleted). */
    val state: DownloadState? get() = local?.state?.takeIf { it != DownloadState.DELETED }
    val isPlayable: Boolean get() = local?.state == DownloadState.DOWNLOADED && local.filePath != null
    val isDownloading: Boolean get() = state == DownloadState.QUEUED || state == DownloadState.DOWNLOADING
    val durationMs: Long get() = local?.durationMs?.takeIf { it > 0 } ?: ((video.durationSeconds ?: 0) * 1000)
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

/**
 * What YouTube itself would show the account, as the Mac last read it (its Home
 * recommendations and the Subscriptions feed), in YouTube's order.
 */
data class YouTubeFeeds(val recommended: List<Video> = emptyList(), val subscriptions: List<Video> = emptyList()) {
    val isEmpty: Boolean get() = recommended.isEmpty() && subscriptions.isEmpty()

    companion object {
        /** The Mac's AccountFeeds JSON. */
        fun parse(json: String): YouTubeFeeds {
            val root = JSONObject(json)
            fun list(key: String): List<Video> {
                val array = root.optJSONArray(key) ?: return emptyList()
                return (0 until array.length()).mapNotNull { i ->
                    val o = array.optJSONObject(i) ?: return@mapNotNull null
                    val id = o.optString("id").takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                    Video(
                        id = id,
                        channelId = o.optString("channelId"),
                        channelTitle = o.optString("channelTitle"),
                        title = o.optString("title").ifEmpty { id },
                        thumbnailUrl = o.optString("thumbnailURL").takeIf { it.isNotEmpty() },
                        isMembersOnly = o.optBoolean("isMembersOnly"),
                        liveStatus = when {
                            o.optBoolean("wasLive") -> "wasLive"
                            o.optBoolean("isLive") -> "is_live"
                            else -> null
                        },
                        durationSeconds = if (o.has("duration") && !o.isNull("duration")) o.optDouble("duration").toLong() else null,
                        publishedAt = if (o.has("timestamp") && !o.isNull("timestamp")) java.util.Date((o.optDouble("timestamp") * 1000).toLong()) else null,
                    ).takeUnless { it.isShort || it.liveStatus == "is_live" }
                }
            }
            return YouTubeFeeds(list("recommended"), list("subscriptions"))
        }
    }
}

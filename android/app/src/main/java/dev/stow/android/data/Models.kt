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
    /** What was downloaded, so it stays listed without the Mac (or after its channel goes). */
    val video: Video? = null,
)

/** A video as the app shows it: what it is, whether it was sent, and what the phone has. */
data class VideoItem(
    val video: Video, val sent: SentVideo?, val local: LocalVideo?, val watchedOnMac: Boolean,
    /** Only in YouTube's Home or Subscriptions feed: not from a Stow channel, never sent. */
    val onlyInYouTubeFeeds: Boolean = false,
    /** Only known from a YouTube search on the phone (kept out of Home and the other lists). */
    val fromSearch: Boolean = false,
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
data class YouTubeFeeds(
    val recommended: List<Video> = emptyList(),
    val subscriptions: List<Video> = emptyList(),
    /** Pictures of the channels in them, by channel id (the Mac looks them up; the feeds have none). */
    val channelAvatars: Map<String, String> = emptyMap(),
) {
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
            val avatars = root.optJSONObject("channelAvatars")?.let { o ->
                o.keys().asSequence().mapNotNull { id -> o.optString(id).takeIf { it.isNotEmpty() }?.let { id to it } }.toMap()
            }.orEmpty()
            return YouTubeFeeds(list("recommended"), list("subscriptions"), avatars)
        }
    }
}

/** A channel's latest uploads and past streams, loaded on the phone for channels the Mac doesn't follow. */
data class ChannelPage(val title: String, val avatarUrl: String?, val videoIds: List<String>, val streamIds: List<String>, val loadedAt: Long,
                       val handle: String? = null)

/**
 * YouTube lists from yt-dlp's `--flat-playlist -J` answer: search results (`ytsearchN:`) or a
 * channel's tab (…/videos, …/streams).
 */
object YouTubeListing {
    /** The channel's picture, on a channel tab. */
    fun channelAvatar(json: String): String? {
        val thumbnails = JSONObject(json).optJSONArray("thumbnails") ?: return null
        val all = (0 until thumbnails.length()).mapNotNull { thumbnails.optJSONObject(it) }
        return all.firstOrNull { it.optString("id") == "avatar_uncropped" }?.optString("url")?.takeIf { it.isNotEmpty() }
    }

    /** The channel's name, on a channel tab. */
    fun channelTitle(json: String): String? =
        JSONObject(json).let { o -> (o.optString("channel").takeIf { it.isNotEmpty() && it != "null" } ?: o.optString("uploader").takeIf { it.isNotEmpty() && it != "null" }) }

    /** The channel's @handle, on a channel tab (yt-dlp's uploader_id, or the end of uploader_url). */
    fun channelHandle(json: String): String? {
        val o = JSONObject(json)
        o.optString("uploader_id").takeIf { it.startsWith("@") }?.let { return it }
        return o.optString("uploader_url").substringAfterLast("/").takeIf { it.startsWith("@") && it.length > 1 }
    }

    /**
     * Videos only, in YouTube's order: no Shorts, and no live or upcoming streams (only finished
     * ones). A channel tab's videos don't name their channel; they get the tab's.
     */
    fun parse(json: String): List<Video> {
        val root = JSONObject(json)
        val entries = root.optJSONArray("entries") ?: return emptyList()
        val pageChannelId = root.optString("channel_id").takeIf { it.startsWith("UC") }.orEmpty()
        val pageChannel = channelTitle(json).orEmpty().takeIf { pageChannelId.isNotEmpty() }.orEmpty()
        return (0 until entries.length()).mapNotNull { i ->
            val o = entries.optJSONObject(i) ?: return@mapNotNull null
            if ("/shorts/" in o.optString("url")) return@mapNotNull null
            val video = entry(o, pageChannelId, pageChannel) ?: return@mapNotNull null
            if (video.liveStatus == "is_live" || video.liveStatus == "is_upcoming" || video.liveStatus == "post_live") return@mapNotNull null
            video.takeUnless { it.isShort }
        }
    }

    /** One video's own answer (`-J` on a watch URL), Shorts and streams included: what a download is of. */
    fun video(json: String): Video? = runCatching {
        // A video's own answer lists every size, and the widest (maxresdefault) often doesn't exist.
        entry(JSONObject(json), "", "")?.let { it.copy(thumbnailUrl = "https://i.ytimg.com/vi/${it.id}/hqdefault.jpg") }
    }.getOrNull()

    private fun entry(o: JSONObject, pageChannelId: String, pageChannel: String): Video? {
        val id = o.optString("id").takeIf { it.length == 11 } ?: return null
        val live = o.optString("live_status").takeIf { it.isNotEmpty() && it != "null" }
        val thumbnails = o.optJSONArray("thumbnails")
        val thumbnail = thumbnails?.let { t ->
            (0 until t.length()).mapNotNull { t.optJSONObject(it) }.maxByOrNull { it.optInt("width") }?.optString("url")
        }?.takeIf { it.isNotEmpty() } ?: "https://i.ytimg.com/vi/$id/hqdefault.jpg"
        return Video(
            id = id,
            channelId = o.optString("channel_id").takeIf { it.isNotEmpty() && it != "null" } ?: pageChannelId,
            channelTitle = o.optString("channel").takeIf { it.isNotEmpty() && it != "null" }
                ?: o.optString("uploader").takeIf { it.isNotEmpty() && it != "null" } ?: pageChannel,
            title = o.optString("title").takeIf { it.isNotEmpty() && it != "null" } ?: id,
            publishedAt = if (o.has("timestamp") && !o.isNull("timestamp")) java.util.Date((o.optDouble("timestamp") * 1000).toLong()) else null,
            thumbnailUrl = thumbnail,
            isMembersOnly = o.optString("availability") == "subscriber_only",
            liveStatus = live,
            durationSeconds = if (o.has("duration") && !o.isNull("duration")) o.optDouble("duration").toLong() else null,
        )
    }
}

/**
 * A [Video] as JSON, in the field names both phones use (standalone.json, and a download's video
 * in videos.json): dates in epoch milliseconds, duration in seconds.
 */
object VideoJson {
    fun encode(video: Video): JSONObject = JSONObject().apply {
        put("id", video.id)
        put("channelId", video.channelId)
        put("channelTitle", video.channelTitle)
        put("title", video.title)
        put("publishedAt", video.publishedAt?.time ?: JSONObject.NULL)
        put("thumbnailURL", video.thumbnailUrl ?: JSONObject.NULL)
        put("isMembersOnly", video.isMembersOnly)
        put("liveStatus", if (video.isPastStream) "wasLive" else video.liveStatus ?: "none")
        put("duration", video.durationSeconds ?: JSONObject.NULL)
    }

    fun decode(o: JSONObject): Video? {
        val id = o.optString("id").takeIf { it.isNotEmpty() } ?: return null
        fun string(key: String) = o.optString(key).takeIf { o.has(key) && !o.isNull(key) }
        return Video(
            id = id,
            channelId = string("channelId").orEmpty(),
            channelTitle = string("channelTitle").orEmpty(),
            title = string("title") ?: id,
            publishedAt = if (o.has("publishedAt") && !o.isNull("publishedAt")) Date(o.optLong("publishedAt")) else null,
            thumbnailUrl = string("thumbnailURL"),
            isMembersOnly = o.optBoolean("isMembersOnly"),
            liveStatus = when (val live = string("liveStatus")) {
                null, "none", "unknown" -> null
                "was_live" -> "wasLive"
                else -> live
            },
            durationSeconds = if (o.has("duration") && !o.isNull("duration")) o.optDouble("duration").toLong() else null,
        )
    }
}

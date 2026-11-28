package dev.stow.android.standalone

import dev.stow.android.data.Video
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import org.json.JSONObject
import java.io.IOException
import java.util.Date

/** What one channel's feeds gave in a check (the Mac's `ChannelFetch`). */
data class ChannelFetch(
    val channelId: String,
    /** The feeds that worked, each newest first. */
    val sources: Map<FeedKind, List<Video>> = emptyMap(),
    val errors: List<String> = emptyList(),
    /** Neither the uploads feed nor the channel's own feed exists. */
    val notFound: Boolean = false,
    /** YouTube rejected the cookies for the members feeds. */
    val authExpired: Boolean = false,
    /** The members feed was read with accepted cookies. */
    val membersSucceeded: Boolean = false,
    /** The channel has no members-only playlist. */
    val noMembersPlaylist: Boolean = false,
    /** The uploads feed couldn't be reached. */
    val networkFailed: Boolean = false,
    /** YouTube asked to slow down: the check stops. */
    val slowDown: Boolean = false,
    /**
     * Videos whose dates are yt-dlp's approximate ones ("3 weeks ago", to the day), not a feed's:
     * they never replace a date already known ([Merge.recent]).
     */
    val approximateDates: Set<String> = emptySet(),
)

/** Reads one channel's feeds (a port of the Mac's `ChannelFetch.fetch`). */
class ChannelChecker(private val web: WebClient, private val tool: YouTubeTool) {
    suspend fun fetch(channel: FollowedChannel, feeds: Set<FeedKind>, cookies: String?): ChannelFetch {
        var result = ChannelFetch(channel.id)
        try {
            if (FeedKind.UPLOADS in feeds) {
                try {
                    val (videos, approximate) = uploads(channel.id)
                    result = result.copy(sources = result.sources + (FeedKind.UPLOADS to videos),
                                         approximateDates = if (approximate) result.approximateDates + videos.map { it.id } else result.approximateDates)
                } catch (e: RssFeed.NotFound) {
                    result = result.copy(notFound = true, errors = result.errors + "${channel.title}: channel not found")
                } catch (e: IOException) {
                    result = result.copy(networkFailed = true, errors = result.errors + "${channel.title}: uploads feed failed: ${e.message}")
                }
            }
            if (result.notFound) return result
            if (FeedKind.STREAMS in feeds) {
                try {
                    val (videos, approximate) = streams(channel.id)
                    result = result.copy(sources = result.sources + (FeedKind.STREAMS to videos), approximateDates = result.approximateDates + approximate)
                } catch (e: SlowDown) {
                    throw e
                } catch (e: Exception) {
                    result = result.copy(errors = result.errors + "${channel.title}: past streams failed: ${e.message}")
                }
            }
            if (FeedKind.MEMBERS in feeds && cookies != null) result = members(channel, cookies, result)
        } catch (e: SlowDown) {
            result = result.copy(slowDown = true, errors = result.errors + "${channel.title}: ${e.message}")
        }
        return result
    }

    /**
     * Long-form uploads from the UULF feed. YouTube's playlist feeds sometimes fail with a server
     * error for days while the channel feeds work; then the Videos tab through yt-dlp stands in
     * (it tells Shorts and live streams apart, which the channel feed can't). The tab's dates are
     * approximate (the second value), put in the tab's order.
     */
    private suspend fun uploads(channelId: String): Pair<List<Video>, Boolean> = try {
        RssFeed.uploads(web, channelId) to false
    } catch (e: SlowDown) {
        if (e.status !in 500..599) throw e
        val json = try {
            tool.flat("https://www.youtube.com/channel/$channelId/videos", Merge.RECENT_PER_CHANNEL, null).json
        } catch (failure: ToolFailure) {
            if (failure.kind == YouTubeFailure.Kind.UNAVAILABLE) throw RssFeed.NotFound(channelId)
            throw e
        }
        Merge.inListedOrder(dev.stow.android.data.YouTubeListing.parse(json)) to true
    }

    /**
     * Finished public streams: yt-dlp lists the Live tab with each stream's state; the UULV feed has
     * the original titles and dates. Without the feed, the tab's dates are approximate: those
     * videos' ids come back too.
     */
    private suspend fun streams(channelId: String): Pair<List<Video>, Set<String>> = coroutineScope {
        val feed = async { runCatching { RssFeed.fetch(web, RssFeed.playlistUrl(RssFeed.Playlists.liveStreams(channelId))) }.getOrNull() }
        val json = try {
            tool.flat("https://www.youtube.com/channel/$channelId/streams", PastStreams.LIMIT, null).json
        } catch (e: ToolFailure) {
            if (e.kind == YouTubeFailure.Kind.UNAVAILABLE) null else throw e   // No Live tab: no streams.
        }
        if (json != null && !PastStreams.hasStates(json)) {
            // An older yt-dlp lists the Live tab without each entry's state: nothing tells past streams
            // from live or upcoming ones. Not counted as read, so the next check asks again.
            throw IOException("yt-dlp gave no stream states")
        }
        if (json == null) return@coroutineScope emptyList<Video>() to emptySet()
        val rss = feed.await()
        val videos = PastStreams.streams(json, channelId, rss)
        if (rss != null) videos to emptySet() else Merge.inListedOrder(videos) to videos.mapTo(HashSet()) { it.id }
    }

    private suspend fun members(channel: FollowedChannel, cookies: String, start: ChannelFetch): ChannelFetch = coroutineScope {
        var result = start
        val id = channel.id
        val feed = async { runCatching { RssFeed.fetch(web, RssFeed.playlistUrl(RssFeed.Playlists.members(id))) }.getOrNull() }
        val output = try {
            tool.flat("https://www.youtube.com/playlist?list=${RssFeed.Playlists.members(id)}", Members.LIMIT, cookies)
        } catch (e: ToolFailure) {
            return@coroutineScope when (e.kind) {
                YouTubeFailure.Kind.UNAVAILABLE -> result.copy(noMembersPlaylist = true, sources = result.sources + (FeedKind.MEMBERS to emptyList()))
                YouTubeFailure.Kind.AUTH -> result.copy(authExpired = true)
                else -> result.copy(errors = result.errors + "${channel.title}: members feed failed: ${e.message}")
            }
        } catch (e: IOException) {
            return@coroutineScope result.copy(errors = result.errors + "${channel.title}: members feed failed: ${e.message}")
        }
        val (listed, approximate) = Members.dated(Members.parse(output.json, id), feed.await())
        val videos = listed.filter { it.liveStatus != Members.LIVE && it.liveStatus != Members.UPCOMING }
        // A playlist listed despite rejected cookies still counts.
        result = result.copy(sources = result.sources + (FeedKind.MEMBERS to videos), authExpired = output.cookiesRejected,
                             membersSucceeded = !output.cookiesRejected, approximateDates = result.approximateDates + approximate)
        if (result.authExpired) return@coroutineScope result
        try {
            val streamsFeed = async { runCatching { RssFeed.fetch(web, RssFeed.playlistUrl(RssFeed.Playlists.memberStreams(id))) }.getOrNull() }
            val streams = tool.flat("https://www.youtube.com/playlist?list=${RssFeed.Playlists.memberStreams(id)}", Members.LIMIT, cookies)
            val (list, streamsApproximate) = Members.dated(Members.parse(streams.json, id).filter { it.isPastStream }, streamsFeed.await())
            result = result.copy(sources = result.sources + (FeedKind.MEMBERS to (videos + list).distinctBy { it.id }),
                                 authExpired = streams.cookiesRejected, approximateDates = result.approximateDates + streamsApproximate)
        } catch (e: ToolFailure) {
            when (e.kind) {
                YouTubeFailure.Kind.UNAVAILABLE -> {}
                YouTubeFailure.Kind.AUTH -> result = result.copy(authExpired = true)
                else -> result = result.copy(errors = result.errors + "${channel.title}: members streams failed: ${e.message}")
            }
        } catch (e: IOException) {
            result = result.copy(errors = result.errors + "${channel.title}: members streams failed: ${e.message}")
        }
        result
    }
}

/** A Live tab's finished streams (a port of the Mac's `PastStreamsFetcher.streams`). */
object PastStreams {
    const val LIMIT = 15

    /** Whether a Live tab listing says each entry's live_status (an empty one does too). */
    fun hasStates(json: String): Boolean {
        val entries = runCatching { JSONObject(json) }.getOrNull()?.optJSONArray("entries") ?: return true
        if (entries.length() == 0) return true
        return (0 until entries.length()).any { i -> entries.optJSONObject(i)?.let { YouTubeJson.string(it, "live_status") } != null }
    }

    /** Only `was_live` entries. With the RSS `feed`, only the streams it lists, with its titles and dates. */
    fun streams(json: String, channelId: String, feed: List<Video>?): List<Video> {
        val root = runCatching { JSONObject(json) }.getOrNull() ?: return emptyList()
        val entries = root.optJSONArray("entries") ?: return emptyList()
        val byId = feed.orEmpty().associateBy { it.id }
        val seen = HashSet<String>()
        return (0 until entries.length()).mapNotNull { i ->
            val e = entries.optJSONObject(i) ?: return@mapNotNull null
            val id = e.optString("id")
            if (id.length != 11 || e.optString("live_status") != "was_live" || !seen.add(id)) return@mapNotNull null
            val original = byId[id]
            if (feed != null && original == null) return@mapNotNull null
            Video(
                id = id, channelId = channelId,
                channelTitle = original?.channelTitle ?: YouTubeJson.string(root, "channel").orEmpty(),
                title = original?.title ?: YouTubeJson.string(e, "title") ?: id,
                publishedAt = original?.publishedAt ?: YouTubeJson.double(e, "timestamp")?.let { Date((it * 1000).toLong()) },
                thumbnailUrl = original?.thumbnailUrl ?: "https://i.ytimg.com/vi/$id/hqdefault.jpg",
                isMembersOnly = false, liveStatus = "wasLive",
                durationSeconds = YouTubeJson.double(e, "duration")?.toLong(),
            )
        }
    }
}

/** A members-only playlist listing (a port of the Mac's `MembersFetcher.parse`). */
object Members {
    const val LIMIT = 10
    const val LIVE = "is_live"
    const val UPCOMING = "is_upcoming"

    /** yt-dlp's live_status: "post_live" (just ended, still processing) counts as live. */
    fun liveStatus(value: String?): String? = when (value) {
        "is_live", "post_live" -> LIVE
        "is_upcoming" -> UPCOMING
        "was_live" -> "wasLive"
        else -> null
    }

    /** The playlist's videos, members-only. Private and deleted placeholders are skipped. */
    fun parse(json: String, channelId: String): List<Video> {
        val root = runCatching { JSONObject(json) }.getOrNull() ?: return emptyList()
        val entries = root.optJSONArray("entries") ?: return emptyList()
        return (0 until entries.length()).mapNotNull { entries.optJSONObject(it) }
            .filter { e ->
                val title = e.optString("title")
                e.optString("id").isNotEmpty() && e.optString("availability") != "private" && title != "[Private video]" && title != "[Deleted video]"
            }
            .take(LIMIT)
            .map { e ->
                val id = e.optString("id")
                Video(
                    id = id,
                    channelId = YouTubeJson.string(e, "channel_id") ?: YouTubeJson.string(root, "channel_id") ?: channelId,
                    channelTitle = YouTubeJson.string(e, "channel") ?: YouTubeJson.string(root, "channel") ?: channelId,
                    title = YouTubeJson.string(e, "title") ?: id,
                    publishedAt = (YouTubeJson.double(e, "timestamp") ?: YouTubeJson.double(e, "release_timestamp"))?.let { Date((it * 1000).toLong()) },
                    thumbnailUrl = "https://i.ytimg.com/vi/$id/hqdefault.jpg",
                    isMembersOnly = true,
                    liveStatus = liveStatus(YouTubeJson.string(e, "live_status")),
                    durationSeconds = YouTubeJson.double(e, "duration")?.toLong(),
                )
            }
    }

    /**
     * The RSS feed's titles and dates applied, and the ids of the videos it doesn't list: their
     * dates are yt-dlp's approximate ones (all of them without the feed).
     */
    fun dated(videos: List<Video>, feed: List<Video>?): Pair<List<Video>, Set<String>> {
        val inFeed = feed.orEmpty().mapTo(HashSet()) { it.id }
        return applyOriginalMetadata(videos, feed.orEmpty()) to videos.map { it.id }.filterTo(HashSet()) { it !in inFeed }
    }

    /** The RSS feed's original titles and dates (yt-dlp's are auto-translated and undated) win. */
    fun applyOriginalMetadata(videos: List<Video>, feed: List<Video>): List<Video> {
        val byId = feed.associateBy { it.id }
        return videos.map { v ->
            val original = byId[v.id] ?: return@map v
            v.copy(title = original.title, publishedAt = original.publishedAt ?: v.publishedAt, channelTitle = original.channelTitle)
        }
    }
}

/** How fetched videos join a channel's recent list, and which of them show (the Mac's `mergeRecent` and visibility rules). */
object Merge {
    const val RECENT_PER_CHANNEL = 30

    /**
     * Fresh entries replace stored ones (titles change); videos that dropped out of a feed stay
     * until the cap. The channel's own title and id win over the feed's; an undated entry is
     * stamped with when it was first seen, so it sorts as newest. Newest first, at most 30.
     *
     * A date in `approximate` (yt-dlp's "3 weeks ago", when the RSS feeds are down) is used only
     * for a video without one, so a known date doesn't move between checks; a feed's date always wins.
     */
    fun recent(stored: List<RecentEntry>, fetched: List<Video>, channel: FollowedChannel, now: Long,
               approximate: Set<String> = emptySet()): List<RecentEntry> {
        val byId = LinkedHashMap<String, RecentEntry>()
        stored.forEach { byId[it.video.id] = it }
        for (fresh in fetched) {
            val old = byId[fresh.id]
            val foundAt = old?.foundAt ?: now
            var video = fresh.copy(channelId = channel.id, channelTitle = channel.title)
            val known = old?.video?.publishedAt
            video = video.copy(publishedAt = if (fresh.id in approximate) known ?: fresh.publishedAt ?: Date(foundAt)
                                             else fresh.publishedAt ?: known ?: Date(foundAt))
            if (video.durationSeconds == null) video = video.copy(durationSeconds = old?.video?.durationSeconds)
            if (video.thumbnailUrl == null) video = video.copy(thumbnailUrl = old?.video?.thumbnailUrl)
            if (video.liveStatus == null && old?.video?.isPastStream == true) video = video.copy(liveStatus = old.video.liveStatus)
            byId[fresh.id] = RecentEntry(video, foundAt)
        }
        return byId.values.sortedByDescending { it.video.publishedAt?.time ?: 0 }.take(RECENT_PER_CHANNEL)
    }

    /**
     * A listing's approximate dates (yt-dlp rounds "3 weeks ago" to a day, so many videos share
     * one) made to follow the listing's own order, newest first: a video dated no earlier than the
     * one listed before it is put a minute before that one. Undated videos stay undated.
     */
    fun inListedOrder(videos: List<Video>): List<Video> {
        var previous: Long? = null
        return videos.map { video ->
            var date = video.publishedAt?.time ?: return@map video
            previous?.let { if (date >= it) date = it - 60_000 }
            previous = date
            video.copy(publishedAt = Date(date))
        }
    }

    /** Members-only and not known to be watchable: kept out of sight. */
    fun isHidden(video: Video, access: Map<String, MemberAccess>): Boolean = video.isMembersOnly && access[video.id]?.canWatch != true

    /** What the screens show: hidden ones left out, ones public now no longer marked members-only. */
    fun visible(videos: List<Video>, access: Map<String, MemberAccess>): List<Video> =
        videos.filterNot { isHidden(it, access) }.map { if (access[it.id] == MemberAccess.NowPublic) it.copy(isMembersOnly = false) else it }
}

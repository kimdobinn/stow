package dev.stow.android.data

/** Pure list logic for Home and Subscriptions (unit-tested). */
object Feeds {
    /**
     * YouTube's Subscriptions feed (newest first, mostly undated) with your Mac channels' videos
     * it doesn't have (dated) slotted in by date. An undated feed video counts as being as old as
     * the dated one above it, so YouTube's own order is kept.
     */
    fun subscriptions(feed: List<VideoItem>, channelVideos: List<VideoItem>): List<VideoItem> {
        val ids = feed.mapTo(HashSet()) { it.id }
        var last = Long.MAX_VALUE
        val dated = feed.map { item ->
            item.video.publishedAt?.time?.let { last = minOf(last, it) }
            item to last
        } + channelVideos.filter { it.id !in ids }.distinctBy { it.id }.map { it to (it.video.publishedAt?.time ?: 0L) }
        return dated.sortedByDescending { it.second }.map { it.first }
    }

    /** A group's videos: from its channels, newest first (undated ones last). */
    fun group(group: ChannelGroup, all: Collection<VideoItem>): List<VideoItem> {
        val ids = group.channelIds
        return all.filter { it.video.channelId in ids }.distinctBy { it.id }
            .sortedByDescending { it.video.publishedAt?.time ?: it.sent?.sentAt?.time ?: 0L }
    }

    /** A channel's past live streams, and its other videos. */
    fun split(videos: List<VideoItem>): Pair<List<VideoItem>, List<VideoItem>> = videos.partition { !it.video.isPastStream }

    /** Rough download size, when yt-dlp can't say: about 3 Mbit/s for 1080p H.264 with AAC. */
    fun estimatedBytes(durationMs: Long): Long = durationMs / 1000 * 3_000_000L / 8
}

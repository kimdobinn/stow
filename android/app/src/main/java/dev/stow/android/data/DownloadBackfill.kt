package dev.stow.android.data

/**
 * Downloads made before 0.9.0 don't carry their [LocalVideo.video]: they were listed only through
 * the Mac's sent videos. These rules give them one, so they stay listed without the Mac. Pure, so
 * they're tested.
 */
object DownloadBackfill {
    /** The title a download shows while what it is isn't known yet (standalone, before its lookup). */
    const val PLACEHOLDER_TITLE = "Downloaded video"

    /** Downloads (not deleted) without their video, that one of `known` (first one wins) describes. */
    fun fill(local: Map<String, LocalVideo>, known: Iterable<Video>): Map<String, Video> {
        val missing = local.values.filter { it.video == null && it.state != DownloadState.DELETED }.mapTo(HashSet()) { it.id }
        if (missing.isEmpty()) return emptyMap()
        val found = LinkedHashMap<String, Video>()
        for (video in known) {
            if (video.id in missing && video.id !in found && !isPlaceholder(video)) found[video.id] = video
        }
        return found
    }

    /** Downloads (not deleted) that nothing describes: neither their own copy nor anything listed. */
    fun orphans(local: Map<String, LocalVideo>, listed: Set<String>): List<String> =
        local.values.filter { it.video == null && it.state != DownloadState.DELETED && it.id !in listed }.map { it.id }

    /** What an orphan shows until it's looked up: its thumbnail, and a plain title. */
    fun placeholder(id: String) = Video(id, "", "", PLACEHOLDER_TITLE, null, "https://i.ytimg.com/vi/$id/hqdefault.jpg", false)

    fun isPlaceholder(video: Video) = video.channelId.isEmpty() && video.title == PLACEHOLDER_TITLE && video.publishedAt == null
}

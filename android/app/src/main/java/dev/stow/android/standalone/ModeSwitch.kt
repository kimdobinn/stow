package dev.stow.android.standalone

import dev.stow.android.data.Channel
import dev.stow.android.data.ChannelGroup
import dev.stow.android.data.SentVideo
import dev.stow.android.data.Video

/** The data side of switching from the Mac to standalone (§1.4), pure so it's tested. */
object ModeSwitch {
    /**
     * `existing` with the Mac's channels (in its order, with their recent videos, their uploads and
     * past streams counted as read just now so they aren't all fetched at once) and groups merged in. What's already there
     * comes first; nothing is repeated.
     */
    fun adoptMac(existing: StandaloneState, channels: List<Channel>, groups: List<ChannelGroup>, now: Long): StandaloneState {
        val known = existing.channels.mapTo(HashSet()) { it.id }
        val added = channels.filter { known.add(it.id) }
        val followed = existing.channels + added.map { FollowedChannel(it.id, it.title, it.handle, it.avatarUrl, now) }
        val recent = existing.recentVideos.toMutableMap()
        val fetchedAt = existing.fetchedAt.toMutableMap()
        for (channel in added) {
            val target = followed.first { it.id == channel.id }
            recent[channel.id] = Merge.recent(recent[channel.id].orEmpty(), channel.recent.map { it.video }, target, now)
            // The Mac's recent videos include its past streams: those count as read just now too.
            fetchedAt[channel.id] = (fetchedAt[channel.id] ?: FetchedAt()).copy(uploads = now, streams = now)
        }
        val groupIds = existing.groups.mapTo(HashSet()) { it.id }
        val mergedGroups = existing.groups.map { mine ->
            val theirs = groups.firstOrNull { it.id == mine.id } ?: return@map mine
            mine.copy(channels = (mine.channels + theirs.channels).distinctBy { it.id })
        } + groups.filter { groupIds.add(it.id) }
        return existing.copy(channels = followed, recentVideos = recent, fetchedAt = fetchedAt, groups = mergedGroups)
    }

    /**
     * Every video the Mac told the phone about (sent ones first, then the channels' recent ones),
     * for downloads made before 0.9.0, which don't carry their own copy: without the Mac nothing
     * else would list them.
     */
    fun macVideos(sent: List<SentVideo>, channels: List<Channel>): List<Video> =
        sent.map { it.video } + channels.flatMap { c -> c.recent.map { it.video } }

    /** Videos watched on the Mac: sent ones marked watched, and recent ones it says are watched. */
    fun macWatched(sent: List<SentVideo>, channels: List<Channel>): Set<String> =
        sent.filter { it.watched }.mapTo(HashSet()) { it.video.id } + channels.flatMap { c -> c.recent.filter { it.watched }.map { it.video.id } }
}

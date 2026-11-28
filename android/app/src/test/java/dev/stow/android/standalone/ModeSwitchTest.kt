package dev.stow.android.standalone

import dev.stow.android.data.Channel
import dev.stow.android.data.ChannelGroup
import dev.stow.android.data.GroupChannel
import dev.stow.android.data.RecentVideo
import dev.stow.android.data.SentVideo
import dev.stow.android.data.Video
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Date

class ModeSwitchTest {
    private val now = 1_800_000_000_000L
    private fun video(id: String, channel: String) = Video(id, channel, "T", id, Date(now - 1000), null, false)
    private val macChannels = listOf(
        Channel(CHANNEL_B, "Bee", "@bee", "https://b", 0, listOf(RecentVideo(video("b1", CHANNEL_B), watched = true), RecentVideo(video("b2", CHANNEL_B), false))),
        Channel(CHANNEL_A, "Ay (Mac)", null, null, 1, listOf(RecentVideo(video("a9", CHANNEL_A), false))),
    )
    private val macGroups = listOf(ChannelGroup("g1", "News", listOf(GroupChannel(CHANNEL_B, "Bee"))), ChannelGroup("g2", "Fun", emptyList()))

    @Test fun keepsWhatsHereFirstAndAddsTheMacsInItsOrder() {
        val existing = StandaloneState(
            channels = listOf(FollowedChannel(CHANNEL_A, "Ay", addedAt = 1)),
            groups = listOf(ChannelGroup("g1", "Mine", listOf(GroupChannel(CHANNEL_A, "Ay")))),
        )
        val merged = ModeSwitch.adoptMac(existing, macChannels, macGroups, now)
        assertEquals(listOf(CHANNEL_A, CHANNEL_B), merged.channels.map { it.id })
        assertEquals("Ay", merged.channels[0].title)
        assertEquals(FollowedChannel(CHANNEL_B, "Bee", "@bee", "https://b", now), merged.channels[1])
        assertEquals(listOf("b1", "b2"), merged.recentVideos.getValue(CHANNEL_B).map { it.video.id })
        // Counted as read now: no refetch storm right after switching.
        assertEquals(now, merged.fetchedAt.getValue(CHANNEL_B).uploads)
        // The Mac's recent videos include its past streams: no yt-dlp run per channel right away either.
        assertEquals(now, merged.fetchedAt.getValue(CHANNEL_B).streams)
        assertEquals(null, merged.recentVideos[CHANNEL_A])
        // Groups merge by id: mine keep their name and gain the Mac's channels.
        assertEquals(listOf("g1", "g2"), merged.groups.map { it.id })
        assertEquals("Mine", merged.groups[0].name)
        assertEquals(listOf(CHANNEL_A, CHANNEL_B), merged.groups[0].channels.map { it.id })
    }

    @Test fun intoAnEmptyPhone() {
        val merged = ModeSwitch.adoptMac(StandaloneState(), macChannels, macGroups, now)
        assertEquals(listOf(CHANNEL_B, CHANNEL_A), merged.channels.map { it.id })
        assertEquals(macGroups, merged.groups)
    }

    @Test fun everyVideoTheMacListedForOlderDownloads() {
        val sent = listOf(SentVideo(video("s1", CHANNEL_A), null, "mac", watched = false))
        assertEquals(listOf("s1", "b1", "b2", "a9"), ModeSwitch.macVideos(sent, macChannels).map { it.id })
    }

    @Test fun theMacsWatchedVideos() {
        val sent = listOf(SentVideo(video("s1", CHANNEL_A), null, "mac", watched = true), SentVideo(video("s2", CHANNEL_A), null, "mac", watched = false))
        assertEquals(setOf("s1", "b1"), ModeSwitch.macWatched(sent, macChannels))
    }
}

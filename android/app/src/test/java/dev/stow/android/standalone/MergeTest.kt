package dev.stow.android.standalone

import dev.stow.android.data.Video
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date

class MergeTest {
    private val now = 1_800_000_000_000L
    private val channel = FollowedChannel(CHANNEL_A, "My Title")
    private fun video(id: String, minutesAgo: Long?, title: String = id, members: Boolean = false, live: String? = null) =
        Video(id, "UCother", "Feed's title", title, minutesAgo?.let { Date(now - it * 60_000) }, null, members, liveStatus = live)

    @Test fun capsAtThirtyNewestFirst() {
        val fetched = (1..40).map { video("v%010d".format(it), it.toLong()) }
        val merged = Merge.recent(emptyList(), fetched, channel, now)
        assertEquals(30, merged.size)
        assertEquals("v0000000001", merged.first().video.id)
        assertEquals("v0000000030", merged.last().video.id)
    }

    @Test fun freshEntriesReplaceAndOldOnesStay() {
        val stored = Merge.recent(emptyList(), listOf(video("a", 10, "Old title"), video("b", 20)), channel, now - 60_000)
        val merged = Merge.recent(stored, listOf(video("a", 10, "New title")), channel, now)
        assertEquals(listOf("a", "b"), merged.map { it.video.id })
        assertEquals("New title", merged[0].video.title)
        assertEquals("first seen stays", now - 60_000, merged[0].foundAt)
    }

    @Test fun theChannelsOwnTitleAndId() {
        val merged = Merge.recent(emptyList(), listOf(video("a", 1)), channel, now)
        assertEquals(CHANNEL_A, merged[0].video.channelId)
        assertEquals("My Title", merged[0].video.channelTitle)
    }

    @Test fun undatedEntriesAreStampedWhenFirstSeen() {
        val first = Merge.recent(emptyList(), listOf(video("old", 60 * 24), video("undated", null)), channel, now)
        assertEquals(listOf("undated", "old"), first.map { it.video.id })
        assertEquals(now, first[0].video.publishedAt!!.time)
        // Seen again later, still undated: keeps its first stamp.
        val later = Merge.recent(first, listOf(video("undated", null)), channel, now + 3_600_000)
        assertEquals(now, later.first { it.video.id == "undated" }.video.publishedAt!!.time)
    }

    @Test fun aStreamStaysAStreamAndKeepsItsLength() {
        val stored = Merge.recent(emptyList(), listOf(video("s", 10, live = "wasLive").copy(durationSeconds = 3600)), channel, now)
        val merged = Merge.recent(stored, listOf(video("s", 10)), channel, now)
        assertTrue(merged[0].video.isPastStream)
        assertEquals(3600L, merged[0].video.durationSeconds)
    }

    @Test fun membersOnlyHideUntilWatchable() {
        val videos = listOf(video("pub", 1), video("m1", 2, members = true), video("m2", 3, members = true), video("m3", 4, members = true),
                            video("m4", 5, members = true))
        val access = mapOf("m1" to MemberAccess.Watchable, "m2" to MemberAccess.NowPublic, "m3" to MemberAccess.Locked("Gold"))
        val shown = Merge.visible(videos, access)
        assertEquals(listOf("pub", "m1", "m2"), shown.map { it.id })
        assertTrue(shown[1].isMembersOnly)
        assertFalse("public now", shown[2].isMembersOnly)
        assertTrue(Merge.isHidden(videos[4], access))
    }

    // yt-dlp's approximate dates (RSS down)

    @Test fun anApproximateDateDoesntReplaceAKnownOne() {
        val stored = Merge.recent(emptyList(), listOf(video("a", 60)), channel, now - 60_000)
        val merged = Merge.recent(stored, listOf(video("a", 60 * 24 * 7), video("b", 60 * 24 * 7)), channel, now, approximate = setOf("a", "b"))
        assertEquals("the feed's date stays", now - 60 * 60_000, merged.first { it.video.id == "a" }.video.publishedAt!!.time)
        assertEquals("a video without one takes it", now - 60 * 24 * 7 * 60_000L, merged.first { it.video.id == "b" }.video.publishedAt!!.time)
    }

    @Test fun aFeedsDateAlwaysWins() {
        val stored = Merge.recent(emptyList(), listOf(video("a", 60 * 24)), channel, now - 60_000, approximate = setOf("a"))
        val merged = Merge.recent(stored, listOf(video("a", 90)), channel, now)
        assertEquals(now - 90 * 60_000, merged.single().video.publishedAt!!.time)
    }

    @Test fun anUndatedApproximateOneIsStampedWhenFirstSeen() {
        val merged = Merge.recent(emptyList(), listOf(video("a", null)), channel, now, approximate = setOf("a"))
        assertEquals(now, merged.single().video.publishedAt!!.time)
    }

    @Test fun sharedRoundedDatesKeepTheListedOrder() {
        val day = 60L * 24 * 3
        val listed = listOf(video("a", day), video("b", day), video("undated", null), video("c", day), video("d", day * 2), video("e", 10))
        val ordered = Merge.inListedOrder(listed)
        fun at(id: String) = ordered.first { it.id == id }.publishedAt?.time
        val base = now - day * 60_000
        assertEquals(base, at("a"))
        assertEquals("a minute before the one above", base - 60_000, at("b"))
        assertEquals("undated stays undated", null, at("undated"))
        assertEquals(base - 2 * 60_000, at("c"))
        assertEquals("an older date stays", now - day * 2 * 60_000, at("d"))
        assertEquals("a newer one below an older one goes under it", now - day * 2 * 60_000 - 60_000, at("e"))
        // Merged, they show in the tab's order.
        val merged = Merge.recent(emptyList(), ordered, channel, now, approximate = ordered.map { it.id }.toSet())
        assertEquals(listOf("undated", "a", "b", "c", "d", "e"), merged.map { it.video.id })
    }
}

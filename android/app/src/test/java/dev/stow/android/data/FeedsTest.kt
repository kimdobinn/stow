package dev.stow.android.data

import java.util.Date
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FeedsTest {
    private fun item(id: String, channel: String = "UCa", minutesAgo: Long? = null, live: String? = null, seconds: Long? = null) =
        VideoItem(Video(id, channel, channel, id, minutesAgo?.let { Date(1_800_000_000_000L - it * 60_000) }, null, false,
                        liveStatus = live, durationSeconds = seconds), null, null, false)

    @Test fun subscriptionsKeepYouTubesOrderAndSlotInTheMacsByDate() {
        // YouTube's feed: f1 (known to be 10 min old), f2 (undated), f3 (known: 100 min).
        val feed = listOf(item("f1", minutesAgo = 10), item("f2"), item("f3", minutesAgo = 100))
        val mac = listOf(item("m1", minutesAgo = 5), item("m2", minutesAgo = 50), item("f1", minutesAgo = 10), item("m3", minutesAgo = 500))
        assertEquals(listOf("m1", "f1", "f2", "m2", "f3", "m3"), Feeds.subscriptions(feed, mac).map { it.id })
        // An empty YouTube feed is just the Mac's, newest first.
        assertEquals(listOf("m1", "f1", "m2", "m3"), Feeds.subscriptions(emptyList(), mac).map { it.id })
    }

    @Test fun aGroupIsItsChannelsNewestFirst() {
        val group = ChannelGroup("g", "Investing", listOf(GroupChannel("UCa", "A"), GroupChannel("UCb", "B")))
        val all = listOf(item("a1", "UCa", 30), item("c1", "UCc", 1), item("b1", "UCb", 10), item("a2", "UCa"))
        assertEquals(listOf("b1", "a1", "a2"), Feeds.group(group, all).map { it.id })
    }

    @Test fun pastStreamsGoUnderLive() {
        val (uploads, streams) = Feeds.split(listOf(item("v1"), item("s1", live = "wasLive"), item("s2", live = "was_live")))
        assertEquals(listOf("v1"), uploads.map { it.id })
        assertEquals(listOf("s1", "s2"), streams.map { it.id })
    }

    @Test fun shortsAreAnythingAMinuteOrLess() {
        assertTrue(item("s", seconds = 59).video.isShort)
        assertTrue(item("s", seconds = 60).video.isShort)
        assertFalse(item("v", seconds = 61).video.isShort)
        assertFalse(item("v").video.isShort)
    }

    @Test fun sizeEstimate() {
        // An hour at ~3 Mbit/s is about 1.35 GB.
        assertEquals(1_350_000_000L, Feeds.estimatedBytes(3_600_000))
    }
}

package dev.stow.android.standalone

import dev.stow.android.data.Video
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date

class PastStreamsTest {
    private val tab = """{"channel":"Test Channel","entries":[
        {"id":"stream00001","title":"Auto-translated title","live_status":"was_live","duration":3600,"timestamp":1700000000},
        {"id":"live0000001","title":"Live now","live_status":"is_live"},
        {"id":"soon0000001","title":"Upcoming","live_status":"is_upcoming"},
        {"id":"stream00002","title":"Second stream","live_status":"was_live"},
        {"id":"stream00001","title":"Repeat","live_status":"was_live"},
        {"id":"short","live_status":"was_live"},
        null
    ]}"""

    @Test fun anOlderYtDlpsListingWithoutStatesIsntRead() {
        assertTrue(PastStreams.hasStates(tab))
        assertTrue("no Live tab entries", PastStreams.hasStates("""{"entries":[]}"""))
        assertFalse(PastStreams.hasStates("""{"entries":[{"id":"stream00001","title":"A"},{"id":"stream00002","live_status":null}]}"""))
    }

    @Test fun onlyFinishedStreamsWithoutTheFeed() {
        val streams = PastStreams.streams(tab, CHANNEL_A, feed = null)
        assertEquals(listOf("stream00001", "stream00002"), streams.map { it.id })
        val first = streams[0]
        assertEquals("wasLive", first.liveStatus)
        assertTrue(first.isPastStream)
        assertEquals(3600L, first.durationSeconds)
        assertEquals(1_700_000_000_000L, first.publishedAt!!.time)
        assertEquals("Test Channel", first.channelTitle)
        assertEquals("https://i.ytimg.com/vi/stream00001/hqdefault.jpg", first.thumbnailUrl)
    }

    @Test fun withTheFeedOnlyItsStreamsWithItsTitlesAndDates() {
        val feed = listOf(Video("stream00002", CHANNEL_A, "Original Channel", "Original title", Date(1_750_000_000_000L), "https://thumb", false))
        val streams = PastStreams.streams(tab, CHANNEL_A, feed)
        assertEquals(listOf("stream00002"), streams.map { it.id })
        assertEquals("Original title", streams[0].title)
        assertEquals(1_750_000_000_000L, streams[0].publishedAt!!.time)
        assertEquals("https://thumb", streams[0].thumbnailUrl)
        assertEquals("wasLive", streams[0].liveStatus)
    }

    @Test fun nothingUsable() {
        assertTrue(PastStreams.streams("{}", CHANNEL_A, null).isEmpty())
        assertTrue(PastStreams.streams("not json", CHANNEL_A, null).isEmpty())
    }
}

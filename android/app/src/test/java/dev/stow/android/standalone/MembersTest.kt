package dev.stow.android.standalone

import dev.stow.android.data.Video
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date

class MembersTest {
    private val playlist = """{"channel":"Playlist Channel","channel_id":"$CHANNEL_A","entries":[
        {"id":"memb0000001","title":"Translated","live_status":"not_live","duration":600},
        {"id":"memb0000002","title":"[Private video]"},
        {"id":"memb0000003","title":"Live now","live_status":"post_live"},
        {"id":"memb0000004","title":"Soon","live_status":"is_upcoming"},
        {"id":"memb0000005","title":"Old stream","live_status":"was_live","timestamp":1700000000},
        {"id":"memb0000006","title":"Hidden","availability":"private"},
        {"id":"memb0000007","title":"[Deleted video]"}
    ]}"""

    @Test fun parsesMembersOnlyEntries() {
        val videos = Members.parse(playlist, CHANNEL_A)
        assertEquals(listOf("memb0000001", "memb0000003", "memb0000004", "memb0000005"), videos.map { it.id })
        assertTrue(videos.all { it.isMembersOnly })
        assertEquals("Playlist Channel", videos[0].channelTitle)
        assertNull("undated until the RSS feed says", videos[0].publishedAt)
        assertEquals(600L, videos[0].durationSeconds)
        assertEquals(Members.LIVE, videos[1].liveStatus)
        assertEquals(Members.UPCOMING, videos[2].liveStatus)
        assertEquals("wasLive", videos[3].liveStatus)
        assertEquals("https://i.ytimg.com/vi/memb0000001/hqdefault.jpg", videos[0].thumbnailUrl)
    }

    @Test fun atMostTen() {
        val entries = (1..14).joinToString(",") { """{"id":"m${"%010d".format(it)}","title":"v$it"}""" }
        assertEquals(10, Members.parse("""{"entries":[$entries]}""", CHANNEL_A).size)
    }

    @Test fun theFeedsTitlesAndDatesWin() {
        val videos = Members.parse(playlist, CHANNEL_A)
        val feed = listOf(Video("memb0000001", CHANNEL_A, "Feed Channel", "Original", Date(1_760_000_000_000L), null, false))
        val corrected = Members.applyOriginalMetadata(videos, feed)
        assertEquals("Original", corrected[0].title)
        assertEquals("Feed Channel", corrected[0].channelTitle)
        assertEquals(1_760_000_000_000L, corrected[0].publishedAt!!.time)
        assertTrue("still members-only", corrected[0].isMembersOnly)
        assertEquals(videos.drop(1), corrected.drop(1))
    }

    @Test fun videosMissingFromTheMembersFeedHaveApproximateDates() {
        val videos = Members.parse(playlist, CHANNEL_A)
        val feed = listOf(Video("memb0000001", CHANNEL_A, "Original", "Original title", Date(1_700_000_000_000), null, true))
        val (dated, approximate) = Members.dated(videos, feed)
        assertEquals("Original title", dated.first { it.id == "memb0000001" }.title)
        assertTrue("memb0000001" !in approximate)
        assertTrue("memb0000005" in approximate)
        // Without the feed, all of them.
        assertEquals(videos.map { it.id }.toSet(), Members.dated(videos, null).second)
    }
}

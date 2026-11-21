package dev.stow.android.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class YouTubeFeedsTest {
    /** The Mac's AccountFeeds JSON (Swift's JSONEncoder leaves out nil fields). */
    @Test fun parsesTheMacsJson() {
        val json = """
            {"recommended":[
              {"channelId":"UCa","channelTitle":"Chan A","duration":754.0,"id":"aaaaaaaaaaa","isLive":false,
               "isMembersOnly":false,"thumbnailURL":"https:\/\/i.ytimg.com\/vi\/aaaaaaaaaaa\/big.jpg","title":"First"},
              {"channelId":"UCb","channelTitle":"Chan B","id":"bbbbbbbbbbb","isLive":true,"isMembersOnly":true,"title":"Live"}
            ],"subscriptions":[]}
        """
        val feeds = YouTubeFeeds.parse(json)
        assertEquals(listOf("aaaaaaaaaaa", "bbbbbbbbbbb"), feeds.recommended.map { it.id })
        val first = feeds.recommended[0]
        assertEquals("Chan A", first.channelTitle)
        assertEquals(754L, first.durationSeconds)
        assertEquals("https://i.ytimg.com/vi/aaaaaaaaaaa/big.jpg", first.thumbnailUrl)
        assertNull(first.liveStatus)
        val live = feeds.recommended[1]
        assertNull(live.durationSeconds)
        assertNull(live.thumbnailUrl)
        assertEquals("is_live", live.liveStatus)
        assertTrue(live.isMembersOnly)
        assertTrue(feeds.subscriptions.isEmpty())
    }

    @Test fun durationFallsBackToTheFeed() {
        val video = Video("aaaaaaaaaaa", "UCa", "A", "T", null, null, false, durationSeconds = 90)
        assertEquals(90_000L, VideoItem(video, null, null, false).durationMs)
        val local = LocalVideo("aaaaaaaaaaa", DownloadState.DOWNLOADED, durationMs = 91_500)
        assertEquals(91_500L, VideoItem(video, null, local, false).durationMs)
    }
}

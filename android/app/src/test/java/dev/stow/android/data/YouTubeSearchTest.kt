package dev.stow.android.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class YouTubeSearchTest {
    /** Trimmed from yt-dlp's `ytsearch:` answer with `--flat-playlist -J`. */
    private val json = """
        {"_type":"playlist","entries":[
          {"_type":"url","ie_key":"Youtube","id":"rFZHOHl-L8A","url":"https://www.youtube.com/watch?v=rFZHOHl-L8A",
           "title":"lofi hip hop radio","channel":"Lofi Girl","channel_id":"UCSJ4gkVC6NrvII8umztf0Ow","duration":null,"live_status":"is_live"},
          {"_type":"url","ie_key":"Youtube","id":"n61ULEU7CO0","url":"https://www.youtube.com/watch?v=n61ULEU7CO0",
           "title":"Best of lofi hip hop 2021","channel":"Lofi Girl","channel_id":"UCSJ4gkVC6NrvII8umztf0Ow","duration":22258.0,
           "live_status":null,"timestamp":null,
           "thumbnails":[{"url":"https://i.ytimg.com/vi/n61ULEU7CO0/small.jpg","width":360},{"url":"https://i.ytimg.com/vi/n61ULEU7CO0/big.jpg","width":720}]},
          {"_type":"url","ie_key":"Youtube","id":"abcdefghijk","url":"https://www.youtube.com/shorts/abcdefghijk","title":"A Short","duration":null},
          {"_type":"url","ie_key":"Youtube","id":"zyxwvutsrqp","url":"https://www.youtube.com/watch?v=zyxwvutsrqp","title":"Short too","duration":45},
          {"_type":"url","ie_key":"Youtube","id":"Upcoming123","url":"https://www.youtube.com/watch?v=Upcoming123","title":"Soon","live_status":"is_upcoming"},
          {"_type":"url","ie_key":"Youtube","id":"WasLive1234","url":"https://www.youtube.com/watch?v=WasLive1234","title":"Last night's stream",
           "uploader":"Someone","duration":7200,"live_status":"was_live"}
        ]}
    """.trimIndent()

    @Test fun keepsVideosAndFinishedStreamsOnly() {
        val videos = YouTubeSearch.parse(json)
        assertEquals(listOf("n61ULEU7CO0", "WasLive1234"), videos.map { it.id })
        val first = videos[0]
        assertEquals("Best of lofi hip hop 2021", first.title)
        assertEquals("Lofi Girl", first.channelTitle)
        assertEquals("UCSJ4gkVC6NrvII8umztf0Ow", first.channelId)
        assertEquals(22258L, first.durationSeconds)
        assertEquals("https://i.ytimg.com/vi/n61ULEU7CO0/big.jpg", first.thumbnailUrl)
        assertNull(first.liveStatus)
        assertNull(first.publishedAt)
        assertEquals("Someone", videos[1].channelTitle)
        assertEquals(true, videos[1].isPastStream)
        assertEquals("https://i.ytimg.com/vi/WasLive1234/hqdefault.jpg", videos[1].thumbnailUrl)
    }

    @Test fun emptyAnswer() {
        assertEquals(emptyList<Video>(), YouTubeSearch.parse("""{"entries":[]}"""))
    }
}

package dev.stow.android.standalone

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.IOException
import java.time.Instant

class RssFeedTest {
    @Test fun parsesTheAtomFeed() {
        val videos = RssFeed.parse(fixture("rss-uploads.xml"))
        assertEquals(listOf("vid00000001", "vid00000002"), videos.map { it.id })
        val first = videos[0]
        assertEquals(CHANNEL_A, first.channelId)
        assertEquals("Rockets & Moons", first.title)
        assertEquals("Test Channel", first.channelTitle)
        assertEquals(Instant.parse("2026-11-20T15:00:00Z").toEpochMilli(), first.publishedAt!!.time)
        assertEquals("https://i1.ytimg.com/vi/vid00000001/hqdefault.jpg", first.thumbnailUrl)
        assertEquals(false, first.isMembersOnly)
        assertNull("RSS can't tell", first.liveStatus)
        assertEquals("Test Channel (entry)", videos[1].channelTitle)
    }

    @Test fun anEmptyFeedHasNoVideos() {
        assertTrue(RssFeed.parse("""<feed xmlns="http://www.w3.org/2005/Atom"><title>x</title></feed>""").isEmpty())
    }

    @Test fun somethingElseIsAnError() {
        for (text in listOf("<html><body>Not found</body></html>", "not xml at all", "")) {
            try {
                RssFeed.parse(text)
                fail("parsed $text")
            } catch (e: IOException) {}
        }
    }

    @Test fun thePlaylistIds() {
        assertEquals("UULFLA_DiR1FfKNvjuUpBHmylQ", RssFeed.Playlists.uploads("UCLA_DiR1FfKNvjuUpBHmylQ"))
        assertEquals("UULVLA_DiR1FfKNvjuUpBHmylQ", RssFeed.Playlists.liveStreams("UCLA_DiR1FfKNvjuUpBHmylQ"))
        assertEquals("UUMFLA_DiR1FfKNvjuUpBHmylQ", RssFeed.Playlists.members("UCLA_DiR1FfKNvjuUpBHmylQ"))
        assertEquals("UUMVLA_DiR1FfKNvjuUpBHmylQ", RssFeed.Playlists.memberStreams("UCLA_DiR1FfKNvjuUpBHmylQ"))
        assertEquals("https://www.youtube.com/feeds/videos.xml?playlist_id=UULFx", RssFeed.playlistUrl("UULFx"))
    }

    private val uploads = RssFeed.playlistUrl(RssFeed.Playlists.uploads(CHANNEL_A))
    private val channelFeed = RssFeed.channelUrl(CHANNEL_A)

    @Test fun uploadsReadTheLongFormPlaylist() = runBlocking {
        val web = FakeWeb().apply { set(uploads, fixture("rss-uploads.xml")) }
        assertEquals(2, RssFeed.uploads(web, CHANNEL_A).size)
        assertEquals(listOf(uploads), web.requests)
    }

    @Test fun aMissingUploadsFeedWithAChannelFeedMeansNoLongFormVideos() = runBlocking {
        val web = FakeWeb().apply { set(channelFeed, fixture("rss-uploads.xml")) }
        assertTrue(RssFeed.uploads(web, CHANNEL_A).isEmpty())
        assertEquals(listOf(uploads, channelFeed), web.requests)
    }

    @Test fun neitherFeedMeansNoSuchChannel() = runBlocking {
        try {
            RssFeed.uploads(FakeWeb(), CHANNEL_A)
            fail("expected NotFound")
        } catch (e: RssFeed.NotFound) {}
    }

    @Test fun tooManyRequestsAndServerErrorsSlowDown() = runBlocking {
        for (status in listOf(429, 503)) {
            val web = FakeWeb().apply { set(uploads, "", status) }
            try {
                RssFeed.uploads(web, CHANNEL_A)
                fail("expected SlowDown for $status")
            } catch (e: SlowDown) {}
        }
    }
}

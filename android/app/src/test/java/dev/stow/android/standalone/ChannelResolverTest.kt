package dev.stow.android.standalone

import dev.stow.android.standalone.ChannelReference.Handle
import dev.stow.android.standalone.ChannelReference.Id
import dev.stow.android.standalone.ChannelReference.Url
import dev.stow.android.standalone.ChannelReference.VideoRef
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class ChannelResolverTest {
    private val nasa = "UCLA_DiR1FfKNvjuUpBHmylQ"

    @Test fun parsesEveryForm() {
        assertEquals(Id(nasa), ChannelResolver.parse(nasa))
        assertEquals(Id(nasa), ChannelResolver.parse("  $nasa\n"))
        assertEquals(Handle("NASA"), ChannelResolver.parse("@NASA"))
        assertEquals(Handle("NASA"), ChannelResolver.parse("NASA"))
        assertEquals(Handle("ペコラ"), ChannelResolver.parse("@ペコラ"))
        assertEquals(Handle("a.b_c-d·e"), ChannelResolver.parse("@a.b_c-d·e"))
        assertEquals(Handle("NASA"), ChannelResolver.parse("https://www.youtube.com/@NASA"))
        assertEquals(Handle("NASA"), ChannelResolver.parse("youtube.com/@NASA/videos"))
        assertEquals(Handle("NASA"), ChannelResolver.parse("https://m.youtube.com/@NASA"))
        assertEquals(Id(nasa), ChannelResolver.parse("https://www.youtube.com/channel/$nasa"))
        assertEquals(Id(nasa), ChannelResolver.parse("http://youtube.com/channel/$nasa/streams"))
        assertEquals(Url("https://www.youtube.com/c/NASA"), ChannelResolver.parse("https://www.youtube.com/c/NASA"))
        assertEquals(Url("https://www.youtube.com/user/NASAtelevision"), ChannelResolver.parse("youtube.com/user/NASAtelevision"))
        assertEquals(VideoRef("dQw4w9WgXcQ"), ChannelResolver.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10s"))
        assertEquals(VideoRef("dQw4w9WgXcQ"), ChannelResolver.parse("https://youtu.be/dQw4w9WgXcQ?si=x"))
        assertEquals(VideoRef("dQw4w9WgXcQ"), ChannelResolver.parse("https://www.youtube.com/shorts/dQw4w9WgXcQ"))
        assertEquals(VideoRef("dQw4w9WgXcQ"), ChannelResolver.parse("https://www.youtube.com/live/dQw4w9WgXcQ"))
        assertEquals(VideoRef("dQw4w9WgXcQ"), ChannelResolver.parse("https://www.youtube.com/embed/dQw4w9WgXcQ"))
        assertEquals(VideoRef("dQw4w9WgXcQ"), ChannelResolver.parse("https://www.youtube.com/v/dQw4w9WgXcQ"))
    }

    @Test fun rejectsWhatCantBeAChannel() {
        assertNull(ChannelResolver.parse("not a channel!!"))
        assertNull(ChannelResolver.parse(""))
        assertNull(ChannelResolver.parse("@"))
        assertNull(ChannelResolver.parse("https://www.youtube.com/channel/UCshort"))
        assertNull(ChannelResolver.parse("https://www.youtube.com/watch?v=short"))
        assertNull(ChannelResolver.parse("https://www.youtube.com/feed/subscriptions"))
        assertNull(ChannelResolver.parse("https://www.youtube.com/"))
        assertNull(ChannelResolver.parse("https://notyoutube.com/@NASA"))
        assertNull(ChannelResolver.parse("@" + "a".repeat(101)))
    }

    private fun resolver(web: FakeWeb, tool: FakeTool = FakeTool()) = ChannelResolver(web, tool)

    private fun message(block: suspend () -> Unit): String = try {
        runBlocking { block() }
        fail("expected an error")
        ""
    } catch (e: ChannelInputException) {
        e.message.orEmpty()
    }

    @Test fun resolvesFromTheChannelPage() = runBlocking {
        val web = FakeWeb().apply { set("https://www.youtube.com/@Test", fixture("channel-page.html")) }
        val info = resolver(web).resolve("@Test")
        assertEquals(CHANNEL_A, info.id)
        assertEquals("Test & Channel", info.title)
    }

    @Test fun aVideoResolvesToItsUploader() = runBlocking {
        val web = FakeWeb().apply {
            set("https://www.youtube.com/watch?v=vid00000001", fixture("watch-page.html"))
            set("https://www.youtube.com/channel/$CHANNEL_A", fixture("channel-page.html"))
        }
        assertEquals(CHANNEL_A, resolver(web).resolve("https://youtu.be/vid00000001").id)
    }

    @Test fun fallsBackToYtDlpWhenThePageCantBeParsed() = runBlocking {
        val web = FakeWeb().apply { set("https://www.youtube.com/@Consent", fixture("channel-page-noid.html")) }
        val tool = FakeTool { _, _ ->
            ToolOutput("""{"channel_id":"$CHANNEL_B","channel":"From yt-dlp","uploader_id":"@fromytdlp","thumbnails":[{"id":"avatar_uncropped","url":"https://a"}]}""")
        }
        val info = resolver(web, tool).resolve("@Consent")
        assertEquals(ChannelInfo(CHANNEL_B, "From yt-dlp", "@fromytdlp", "https://a"), info)
        assertTrue(tool.runs.single().first.containsAll(listOf("-J", "--flat-playlist", "--playlist-items", "0")))
    }

    @Test fun errorsSayWhatWentWrong() {
        assertEquals("Not a channel URL, @handle or channel ID: not a channel!!", message { resolver(FakeWeb()).resolve("not a channel!!") })
        assertEquals("Channel not found: @thishandledoesnotexist12345",
                     message { resolver(FakeWeb()).resolve("@thishandledoesnotexist12345") })
        // yt-dlp saying "does not exist" is "not found" too.
        val web = FakeWeb().apply { set("https://www.youtube.com/c/gone", "<html></html>") }
        val tool = FakeTool { _, _ -> throw ToolFailure("ERROR: [youtube:tab] gone: This channel does not exist.") }
        assertEquals("Channel not found: youtube.com/c/gone", message { resolver(web, tool).resolve("youtube.com/c/gone") })
        assertEquals("NASA is already added.", ChannelResolver.alreadyAdded("NASA").message)
    }
}

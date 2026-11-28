package dev.stow.android.standalone

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ChannelPageParserTest {
    @Test fun readsTheChannelsFields() {
        val info = ChannelPageParser.parse(fixture("channel-page.html"))!!
        // The itemprop identifier wins over externalId.
        assertEquals(CHANNEL_A, info.id)
        assertEquals("Test & Channel", info.title)
        assertEquals("@TestéChannel", info.handle)
        assertEquals("https://yt3.googleusercontent.com/test-avatar=s900", info.avatarUrl)
    }

    @Test fun externalIdAndEscapedSlashes() {
        val html = """<meta property="og:title" content="X"><script>{"externalId":"$CHANNEL_B","vanityChannelUrl":"https:\/\/www.youtube.com\/@x"}</script>"""
        val info = ChannelPageParser.parse(html)!!
        assertEquals(CHANNEL_B, info.id)
        assertEquals("@x", info.handle)
        assertNull(info.avatarUrl)
    }

    @Test fun aConsentWallIsntAChannel() {
        assertNull(ChannelPageParser.parse(fixture("channel-page-noid.html")))
    }

    @Test fun theWatchPagesFirstChannelIsTheUploader() {
        assertEquals(CHANNEL_A, ChannelPageParser.ownerChannelId(fixture("watch-page.html")))
        assertNull(ChannelPageParser.ownerChannelId("<html></html>"))
    }

    @Test fun decodesEntities() {
        assertEquals("a & b < c > \"d\" 'e' é é", ChannelPageParser.decodeEntities("a &amp; b &lt; c &gt; &quot;d&quot; &apos;e&#39; &#233; &#xE9;"))
        assertEquals("&bogus;", ChannelPageParser.decodeEntities("&bogus;"))
    }
}

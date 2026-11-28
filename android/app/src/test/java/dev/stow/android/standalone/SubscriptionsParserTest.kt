package dev.stow.android.standalone

import dev.stow.android.account.Cookie
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class SubscriptionsParserTest {
    private val html = fixture("feed-channels.html")

    @Test fun findsTheInitialDataAndConfig() {
        val data = SubscriptionsImport.initialData(html)!!
        assertTrue(data.startsWith("{\"contents\"") && data.endsWith("}"))
        JSONObject(data)
        val config = SubscriptionsImport.config(html)
        assertEquals("2.20261120.00.00", config.getString("INNERTUBE_CLIENT_VERSION"))
        assertEquals("999", config.getString("DELEGATED_SESSION_ID"))
        assertEquals("WEB", config.getJSONObject("INNERTUBE_CONTEXT").getJSONObject("client").getString("clientName"))
        assertNull(SubscriptionsImport.initialData("<html>signed out</html>"))
    }

    @Test fun parsesRenderersHandlesAvatarsAndTheContinuation() {
        val page = SubscriptionsParser.parse(SubscriptionsImport.initialData(html)!!)
        assertEquals(listOf(CHANNEL_A, CHANNEL_B), page.channels.map { it.id })
        assertEquals(ChannelInfo(CHANNEL_A, "First Channel", "@firsté", "https://yt3.ggpht.com/a=s176"), page.channels[0])
        assertEquals(ChannelInfo(CHANNEL_B, "Second Channel", "@second", "https://yt3.ggpht.com/b=s88"), page.channels[1])
        assertEquals("TOKEN-1", page.continuation)
        val next = SubscriptionsParser.parse(fixture("browse-continuation.json"))
        assertNull("a subscriber count isn't a handle", next.channels[0].handle)
        assertNull(next.continuation)
    }

    private val cookies = listOf(
        Cookie(".youtube.com", "SAPISID", "sapisid"), Cookie(".youtube.com", "__Secure-1PAPISID", "one"),
        Cookie(".youtube.com", "__Secure-3PAPISID", "three"), Cookie(".youtube.com", "LOGIN_INFO", "l"),
        Cookie(".google.com", "SID", "google"),
    )

    @Test fun readsEveryPageWithTheAccountsCookies() = runBlocking {
        val web = FakeWeb().apply {
            set(SubscriptionsImport.FEED_URL, html)
            set(SubscriptionsImport.BROWSE_URL, fixture("browse-continuation.json"))
        }
        val channels = SubscriptionsImport(web).fetch(cookies)
        assertEquals(listOf(CHANNEL_A, CHANNEL_B, "UC" + "c".repeat(22)), channels.map { it.id })
        assertEquals(listOf(SubscriptionsImport.FEED_URL, SubscriptionsImport.BROWSE_URL), web.requests)
    }

    @Test fun aFailedContinuationKeepsTheFirstPage() = runBlocking {
        val web = FakeWeb().apply { set(SubscriptionsImport.FEED_URL, html) }
        assertEquals(2, SubscriptionsImport(web).fetch(cookies).size)
    }

    @Test fun beingSentToSignInMeansSignedOut() = runBlocking {
        for (web in listOf(
            FakeWeb().apply { set(SubscriptionsImport.FEED_URL, "<html>sign in</html>", finalUrl = "https://accounts.google.com/ServiceLogin?x") },
            FakeWeb().apply { set(SubscriptionsImport.FEED_URL, "<html>no data</html>") },
        )) {
            try {
                SubscriptionsImport(web).fetch(cookies)
                fail("expected SignedOutByYouTube")
            } catch (e: SignedOutByYouTube) {}
        }
    }

    @Test fun theCookieHeaderHasYouTubesCookiesAndConsent() {
        assertEquals("SAPISID=sapisid; __Secure-1PAPISID=one; __Secure-3PAPISID=three; LOGIN_INFO=l; SOCS=CAI", SubscriptionsImport.cookieHeader(cookies))
        assertEquals("SOCS=x", SubscriptionsImport.cookieHeader(listOf(Cookie(".youtube.com", "SOCS", "x"))))
    }
}

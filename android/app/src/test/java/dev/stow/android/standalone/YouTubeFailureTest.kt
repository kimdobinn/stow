package dev.stow.android.standalone

import dev.stow.android.standalone.YouTubeFailure.Kind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class YouTubeFailureTest {
    @Test fun classifiesInOrder() {
        assertEquals(Kind.AUTH, YouTubeFailure.classify("WARNING: The provided YouTube account cookies are no longer valid."))
        assertEquals(Kind.AUTH, YouTubeFailure.classify("ERROR: Sign in to confirm. Use --cookies-from-browser or --cookies for the authentication."))
        // "Unable to download webpage: HTTP Error 404" is unavailable, not network.
        assertEquals(Kind.UNAVAILABLE, YouTubeFailure.classify("ERROR: Unable to download webpage: HTTP Error 404: Not Found"))
        assertEquals(Kind.UNAVAILABLE, YouTubeFailure.classify("ERROR: [youtube:tab] This channel does not have a streams tab"))
        assertEquals(Kind.UNAVAILABLE, YouTubeFailure.classify("ERROR: Video unavailable. This video is private"))
        assertEquals(Kind.NETWORK, YouTubeFailure.classify("ERROR: Unable to download webpage: <urlopen error [Errno 7] No address associated with hostname>"))
        assertEquals(Kind.NETWORK, YouTubeFailure.classify("ERROR: HTTP Error 429: Too Many Requests"))
        assertEquals(Kind.NETWORK, YouTubeFailure.classify("ERROR: HTTP Error 503: Service Unavailable"))
        assertEquals(Kind.NETWORK, YouTubeFailure.classify("Read timed out"))
        assertEquals(Kind.OTHER, YouTubeFailure.classify("ERROR: something new"))
        assertEquals(Kind.OTHER, YouTubeFailure.classify(null))
    }

    @Test fun cookiesRejectedIsAnAuthWarning() {
        assertTrue(YouTubeFailure.cookiesRejected("WARNING: [youtube] The provided YouTube account cookies are no longer valid. They have likely been rotated"))
        assertFalse(YouTubeFailure.cookiesRejected("WARNING: [youtube] Falling back to generic n function search"))
        assertFalse(YouTubeFailure.cookiesRejected(""))
        assertTrue(YouTubeFailure.isSlowDown("ERROR: HTTP Error 429: Too Many Requests"))
        assertFalse(YouTubeFailure.isSlowDown("ERROR: HTTP Error 404"))
    }

    @Test fun aToolFailureShowsItsFirstLine() {
        val failure = ToolFailure("ERROR: [youtube] abc: Video unavailable\nmore")
        assertEquals("[youtube] abc: Video unavailable", failure.message)
        assertEquals(Kind.UNAVAILABLE, failure.kind)
    }
}

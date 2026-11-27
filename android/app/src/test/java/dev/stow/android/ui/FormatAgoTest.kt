package dev.stow.android.ui

import java.util.Date
import org.junit.Assert.assertEquals
import org.junit.Test

class FormatAgoTest {
    private val now = 1_800_000_000_000L
    private fun ago(seconds: Long) = Format.ago(Date(now - seconds * 1000), now)

    @Test fun saysItLikeYouTube() {
        assertEquals("Just now", ago(10))
        assertEquals("1 minute ago", ago(60))
        assertEquals("5 minutes ago", ago(5 * 60))
        assertEquals("4 hours ago", ago(4 * 3600))
        assertEquals("3 days ago", ago(3 * 86_400))
        assertEquals("2 weeks ago", ago(17 * 86_400))
        assertEquals("3 months ago", ago(100 * 86_400))
        assertEquals("11 months ago", ago(340 * 86_400))
        assertEquals("1 year ago", ago(364 * 86_400))
        assertEquals("2 years ago", ago(729 * 86_400))
        assertEquals("3 years ago", ago(3 * 365 * 86_400))
        assertEquals("", Format.ago(null, now))
    }
}

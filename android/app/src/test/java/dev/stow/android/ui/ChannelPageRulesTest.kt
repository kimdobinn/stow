package dev.stow.android.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** A channel removed from its own page: YouTube's videos load again, under the name it had. */
class ChannelPageRulesTest {
    @Test fun unfollowingInStandaloneLoadsThePageAgain() {
        val following = ChannelPageRules.loadKey(attempt = 0, standalone = true, followed = true)
        val removed = ChannelPageRules.loadKey(attempt = 0, standalone = true, followed = false)
        assertNotEquals(following, removed)
        assertFalse(ChannelPageRules.loads(followed = true))
        assertTrue(ChannelPageRules.loads(followed = false))
        // A retry loads again too.
        assertNotEquals(removed, ChannelPageRules.loadKey(attempt = 1, standalone = true, followed = false))
    }

    @Test fun withTheMacFollowingDoesntChangeTheKey() {
        assertEquals(ChannelPageRules.loadKey(0, standalone = false, followed = true),
                     ChannelPageRules.loadKey(0, standalone = false, followed = false))
    }

    @Test fun theHeaderAndFollowStayWhileItLoads() {
        val title = ChannelPageRules.title(current = "", lastSeen = "Test")
        assertEquals("Test", title)
        assertEquals("New name", ChannelPageRules.title("New name", "Test"))
        assertTrue(ChannelPageRules.showsHeader(followed = false, hasVideos = false, standalone = true, title = title))
        assertFalse("nothing known yet", ChannelPageRules.showsHeader(followed = false, hasVideos = false, standalone = true, title = ""))
        assertFalse("with the Mac, only once there are videos", ChannelPageRules.showsHeader(false, false, standalone = false, title = title))
        assertTrue(ChannelPageRules.showsHeader(followed = true, hasVideos = false, standalone = false, title = ""))
    }
}

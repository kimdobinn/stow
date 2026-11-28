package dev.stow.android.standalone

import org.junit.Assert.assertEquals
import org.junit.Test

class WatchSyncTest {
    @Test fun aFirstReadIsAllNew() {
        assertEquals(listOf("a", "b"), WatchSync.newlyWatched(listOf("a", "b"), emptyList()))
    }

    @Test fun whatsAboveTheNewestAnchor() {
        assertEquals(listOf("x", "y"), WatchSync.newlyWatched(listOf("x", "y", "a", "b", "c"), listOf("a", "b", "c")))
        assertEquals(emptyList<String>(), WatchSync.newlyWatched(listOf("a", "b"), listOf("a", "b")))
        // "a" fell out (deleted from the history): the next anchor still works.
        assertEquals(listOf("x"), WatchSync.newlyWatched(listOf("x", "b", "c"), listOf("a", "b", "c")))
        // Watching an old one again moves it to the top.
        assertEquals(listOf("c"), WatchSync.newlyWatched(listOf("c", "a", "b"), listOf("a", "b", "c")))
    }

    @Test fun onlyTheFirstTenAnchorsCount() {
        val previous = (1..12).map { "p$it" }
        assertEquals(listOf("n", "p11", "p12"), WatchSync.newlyWatched(listOf("n", "p11", "p12"), previous))
    }

    @Test fun parsesTheHistoryWithoutRepeats() {
        assertEquals(listOf("a", "b"), WatchSync.parseHistory("""{"entries":[{"id":"a"},{"id":"b"},{"id":"a"},null,{}]}"""))
        assertEquals(emptyList<String>(), WatchSync.parseHistory("{}"))
    }
}

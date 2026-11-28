package dev.stow.android.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date

class DownloadBackfillTest {
    private fun video(id: String, title: String = "Title $id") = Video(id, "UCchannel", "Channel", title, Date(1_700_000_000_000L), null, false)
    private val local = mapOf(
        "old00000001" to LocalVideo("old00000001", DownloadState.DOWNLOADED),                   // a 0.8.x download
        "old00000002" to LocalVideo("old00000002", DownloadState.QUEUED),
        "gone0000001" to LocalVideo("gone0000001", DownloadState.DELETED),
        "new00000001" to LocalVideo("new00000001", DownloadState.DOWNLOADED, video = video("new00000001", "Mine")),
    )

    @Test fun olderDownloadsTakeTheVideoTheMacListed() {
        val filled = DownloadBackfill.fill(local, listOf(video("old00000001"), video("old00000001", "Second"), video("gone0000001"),
                                                         video("new00000001", "Other"), video("unrelated01")))
        assertEquals(mapOf("old00000001" to video("old00000001")), filled)
    }

    @Test fun placeholdersArentSaved() {
        assertTrue(DownloadBackfill.fill(local, listOf(DownloadBackfill.placeholder("old00000002"))).isEmpty())
    }

    @Test fun orphansAreTheOnesNothingDescribes() {
        assertEquals(listOf("old00000002"), DownloadBackfill.orphans(local, listed = setOf("old00000001")))
        val placeholder = DownloadBackfill.placeholder("old00000002")
        assertEquals(DownloadBackfill.PLACEHOLDER_TITLE, placeholder.title)
        assertEquals("https://i.ytimg.com/vi/old00000002/hqdefault.jpg", placeholder.thumbnailUrl)
        assertTrue(DownloadBackfill.isPlaceholder(placeholder))
    }
}

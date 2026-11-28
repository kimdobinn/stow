package dev.stow.android.standalone

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ImportSelectionTest {
    private val available = listOf(ChannelInfo("UC1", "One"), ChannelInfo("UC2", "Two"), ChannelInfo("UC3", "Three"))
    private val followed = setOf("UC2")

    @Test fun startsEmpty() {
        val selection = ImportSelection()
        assertEquals(0, selection.count)
        assertTrue(selection.chosen(available).isEmpty())
    }

    @Test fun selectAllIsOnlyAnExplicitActionAndSkipsFollowedChannels() {
        var selection = ImportSelection().toggle("UC1", followed)
        assertEquals(listOf("UC1"), selection.chosen(available).map { it.id })
        selection = selection.selectAll(available, followed)
        assertEquals(listOf("UC1", "UC3"), selection.chosen(available).map { it.id })
        assertEquals(0, selection.selectNone().count)
    }

    @Test fun followedChannelsStayDisabled() {
        val selection = ImportSelection().toggle("UC2", followed)
        assertEquals(0, selection.count)
        assertTrue(selection.isAdded("UC2", followed))
        assertFalse(selection.isPicked("UC2"))
        assertEquals(0, selection.toggle("UC1", followed).toggle("UC1", followed).count)
    }
}

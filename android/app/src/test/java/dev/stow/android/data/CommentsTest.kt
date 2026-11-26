package dev.stow.android.data

import dev.stow.android.ui.Format
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CommentsTest {
    private val json = """
        {"id":"v","formats":[{"url":"x"}],"comment_count":1234,"comments":[
          {"id":"a","parent":"root","text":"First!","author":"@ann","like_count":1500,"timestamp":1800000000,
           "is_pinned":true,"author_is_uploader":true,"is_favorited":true,"author_thumbnail":"https://yt3.ggpht.com/a.jpg"},
          {"id":"b","parent":"root","text":"Second","author":"@bob"},
          {"id":"a.1","parent":"a","text":"reply one","author":"@cat","like_count":3},
          {"id":"a.2","parent":"a","text":"reply two","author":"@dan"},
          {"id":"x.1","parent":"missing","text":"orphan","author":"@eve"},
          {"id":"c","parent":"root","author":"@no-text"}
        ]}
    """

    @Test fun threadsGatherTheirRepliesInOrder() {
        val page = Comments.parse(json)
        assertEquals(1234L, page.totalCount)
        assertEquals(1234L, page.shownCount)
        // yt-dlp's count when it's only the number fetched.
        assertNull(Comments.parse(json.replace("1234", "6")).shownCount)
        assertEquals(listOf("a", "b"), page.threads.map { it.id })
        val first = page.threads[0]
        assertEquals(listOf("a.1", "a.2"), first.replies.map { it.id })
        assertEquals(1500L, first.likes)
        assertTrue(first.isPinned && first.byUploader && first.isHearted)
        assertEquals(1_800_000_000L, first.postedAt)
        assertEquals("https://yt3.ggpht.com/a.jpg", first.authorThumbnail)
        val second = page.threads[1]
        assertEquals(0L, second.likes)
        assertNull(second.postedAt)
        assertNull(second.authorThumbnail)
        assertFalse(second.isPinned)
    }

    @Test fun theSavedCopyKeepsOnlyTheComments() {
        val trimmed = Comments.trim(json)
        assertFalse(trimmed.contains("formats"))
        assertEquals(Comments.parse(json), Comments.parse(trimmed))
        val none = Comments.parse(Comments.trim("""{"id":"v"}"""))
        assertTrue(none.threads.isEmpty())
        assertNull(none.totalCount)
    }

    @Test fun countsReadLikeYouTubes() {
        assertEquals("950", Format.shortCount(950))
        assertEquals("1K", Format.shortCount(1_000))
        assertEquals("1.2K", Format.shortCount(1_250))
        assertEquals("34K", Format.shortCount(34_900))
        assertEquals("1.5M", Format.shortCount(1_560_000))
        assertEquals("23M", Format.shortCount(23_000_000))
    }
}

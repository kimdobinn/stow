package dev.stow.android.standalone

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MemberAccessTest {
    @Test fun fromALookup() {
        assertEquals(MemberAccess.NowPublic, MemberAccess.fromLookup("""{"availability":"public"}"""))
        assertEquals(MemberAccess.NowPublic, MemberAccess.fromLookup("""{"availability":"unlisted"}"""))
        assertEquals(MemberAccess.Watchable, MemberAccess.fromLookup("""{"availability":"subscriber_only"}"""))
        assertEquals(MemberAccess.Watchable, MemberAccess.fromLookup("{}"))
    }

    @Test fun fromAnError() {
        assertEquals(MemberAccess.Locked("Gold"),
                     MemberAccess.fromError("ERROR: [youtube] x: This video is available to this channel's members on level: Gold (or any higher level). Join this channel"))
        assertEquals(MemberAccess.Locked("Tier 2"), MemberAccess.fromError("members on level: Tier 2. Join"))
        assertEquals(MemberAccess.Locked(null), MemberAccess.fromError("ERROR: Join this channel to get access to members-only content like this video"))
        assertEquals(MemberAccess.Locked(null), MemberAccess.fromError("ERROR: [youtube] x: Video unavailable"))
        assertEquals(MemberAccess.Watchable, MemberAccess.fromError("ERROR: [youtube] x: Requested format is not available"))
        assertNull(MemberAccess.fromError("ERROR: something else"))
    }

    @Test fun storedForms() {
        for (access in listOf(MemberAccess.Watchable, MemberAccess.NowPublic, MemberAccess.Locked(null), MemberAccess.Locked("Gold"))) {
            assertEquals(access, MemberAccess.parse(access.stored))
        }
        assertEquals("locked:Gold", MemberAccess.Locked("Gold").stored)
        assertNull(MemberAccess.parse("bogus"))
        assertTrue(MemberAccess.NowPublic.canWatch)
        assertFalse(MemberAccess.Locked(null).canWatch)
    }
}

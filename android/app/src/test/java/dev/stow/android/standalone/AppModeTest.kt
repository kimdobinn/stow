package dev.stow.android.standalone

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AppModeTest {
    @Test fun storedValuesWin() {
        assertEquals(AppMode.MAC, AppMode.resolve("mac", hasPairing = false))
        assertEquals(AppMode.STANDALONE, AppMode.resolve("standalone", hasPairing = false))
        // Stored "standalone" with a pairing can't happen, but the stored value still decides.
        assertEquals(AppMode.STANDALONE, AppMode.resolve("standalone", hasPairing = true))
        assertEquals(AppMode.MAC, AppMode.resolve("mac", hasPairing = true))
    }

    @Test fun installsPairedBeforeModesStayWithTheMacAndStoreIt() {
        val mode = AppMode.resolve(null, hasPairing = true)
        assertEquals(AppMode.MAC, mode)
        assertTrue(AppMode.needsStoring(null, mode))
        assertEquals("mac", mode.stored)
        assertFalse(AppMode.needsStoring("mac", mode))
    }

    @Test fun aFreshInstallChooses() {
        assertEquals(AppMode.CHOOSING, AppMode.resolve(null, hasPairing = false))
        assertEquals(AppMode.CHOOSING, AppMode.resolve("something else", hasPairing = false))
        assertFalse(AppMode.needsStoring(null, AppMode.CHOOSING))
        assertNull(AppMode.CHOOSING.stored)
    }
}

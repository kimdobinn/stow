package dev.stow.android.standalone

import dev.stow.android.data.MacPull
import dev.stow.android.data.Remote
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date

/** Switching to standalone in the middle of Mac-mode work: it stops there. */
class ModeEraTest {
    @Test fun everyModeChangeIsANewEra() {
        val era = ModeEra()
        val mac = era.value
        era.change(AppMode.MAC, AppMode.MAC)
        assertTrue("staying in Mac mode isn't a change", era.isCurrent(mac))
        era.change(AppMode.MAC, AppMode.STANDALONE)
        assertFalse(era.isCurrent(mac))
        val standalone = era.value
        era.change(AppMode.STANDALONE, AppMode.MAC)
        assertFalse("back with the Mac is another era", era.isCurrent(mac))
        assertFalse(era.isCurrent(standalone))
    }

    private val requested = 1_800_000_000_000L
    private fun shared(handled: Long?) = Remote.Shared(emptyList(), null, handled?.let(::Date))

    @Test fun thePullEndsWhenTheModeChanges() = runBlocking {
        val era = ModeEra()
        val started = era.value
        val mode = MutableStateFlow(AppMode.MAC)
        val sharedFlow = MutableStateFlow(shared(null))
        val changes = combine(sharedFlow, mode) { s, _ -> s }
        val pull = async { MacPull.await(changes, requested, timeoutMs = 120_000) { era.isCurrent(started) && mode.value == AppMode.MAC } }
        delay(50)
        era.change(AppMode.MAC, AppMode.STANDALONE)
        mode.value = AppMode.STANDALONE
        // Ends right away, not after two minutes; a late answer from the Mac doesn't count.
        assertEquals(MacPull.Answer.STOPPED, withTimeout(2_000) { pull.await() })
        sharedFlow.value = shared(requested)
    }

    @Test fun theMacsAnswerOrNone() = runBlocking {
        val sharedFlow = MutableStateFlow(shared(requested - 60_000))
        val pull = async { MacPull.await(sharedFlow, requested, timeoutMs = 5_000) { true } }
        delay(50)
        sharedFlow.value = shared(requested - 500)
        assertEquals("to the millisecond, a second's slack", MacPull.Answer.ANSWERED, pull.await())
        assertEquals(MacPull.Answer.NO_ANSWER, MacPull.await(MutableStateFlow(shared(null)), requested, timeoutMs = 100) { true })
    }
}

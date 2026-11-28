package dev.stow.android.ui

import androidx.compose.runtime.MonotonicFrameClock
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.unit.Velocity
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pulling up at the end of a feed: only the finger counts, and only past the threshold. */
class PullUpTest {
    private var pulls = 0
    private var armed = 0
    private var busy = false
    private val pull = PullUp(threshold = 100f, busy = { busy }, onPull = { pulls++ }).also { it.onArmed = { armed++ } }

    /** A frame clock that runs animations instantly (16 ms a frame). */
    private val clock = object : MonotonicFrameClock {
        var t = 0L
        override suspend fun <R> withFrameNanos(onFrame: (Long) -> R): R { t += 16_000_000; return onFrame(t) }
    }

    private fun dragUp(px: Float) = pull.onPostScroll(Offset.Zero, Offset(0f, -px), NestedScrollSource.UserInput)
    private fun release() = runBlocking(clock) { pull.onPreFling(Velocity(0f, -500f)) }

    @Test fun pullingPastTheThresholdRefreshesOnRelease() {
        assertEquals(Offset(0f, -250f), dragUp(250f))
        assertEquals(125f, pull.distance) // half the finger's travel
        assertEquals(1, armed)
        assertEquals(0, pulls) // not until the finger lets go
        assertEquals(Velocity(0f, -500f), release())
        assertEquals(1, pulls)
        assertEquals(0f, pull.drag)
    }

    @Test fun aShortPullDoesNothing() {
        dragUp(150f) // 75 px of spinner, under 100
        release()
        assertEquals(0, pulls)
        assertEquals(0, armed)
    }

    @Test fun movingBackDownTakesThePullBackFirst() {
        dragUp(250f)
        val used = pull.onPreScroll(Offset(0f, 120f), NestedScrollSource.UserInput)
        assertEquals(Offset(0f, 120f), used)
        assertEquals(65f, pull.distance)
        release()
        assertEquals(0, pulls)
    }

    @Test fun flingsAndRefreshesInProgressDontPull() {
        assertEquals(Offset.Zero, pull.onPostScroll(Offset.Zero, Offset(0f, -300f), NestedScrollSource.SideEffect))
        busy = true
        assertEquals(Offset.Zero, dragUp(300f))
        assertEquals(0f, pull.drag)
        // Nothing pulled: the fling goes to the list as usual.
        assertEquals(Velocity.Zero, release())
        assertFalse(pulls > 0)
    }

    @Test fun scrollingTheListItselfIsUntouched() {
        // Leftover only comes at the end; a normal scroll down the list has none.
        assertEquals(Offset.Zero, pull.onPostScroll(Offset(0f, -40f), Offset.Zero, NestedScrollSource.UserInput))
        assertEquals(Offset.Zero, pull.onPreScroll(Offset(0f, 40f), NestedScrollSource.UserInput))
        assertTrue(pull.drag == 0f)
    }
}

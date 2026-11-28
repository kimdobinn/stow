package dev.stow.android.ui

import androidx.compose.animation.core.AnimationSpec
import androidx.compose.animation.core.animate
import androidx.compose.runtime.MonotonicFrameClock
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The app's shared motion: where let-go gestures land, and how its curves and springs behave. */
class MotionTest {
    private val flick = 3000f // 1000 dp/s on a 3x phone, in px/s

    @Test fun aFlickDecidesWhereThePlayerLands() {
        // Flicked up from near the bottom: the watch page, even though the mini player is nearer.
        assertEquals(1f, Motion.sheetTarget(progress = 0.1f, velocity = 3500f, flick = flick))
        // Flicked down from near the top: the mini player.
        assertEquals(0f, Motion.sheetTarget(progress = 0.9f, velocity = -3500f, flick = flick))
    }

    @Test fun aSlowReleaseGoesToTheNearerEnd() {
        assertEquals(1f, Motion.sheetTarget(progress = 0.6f, velocity = -2000f, flick = flick))
        assertEquals(0f, Motion.sheetTarget(progress = 0.4f, velocity = 2000f, flick = flick))
        assertEquals(0f, Motion.sheetTarget(progress = 0.5f, velocity = 0f, flick = flick))
    }

    @Test fun theMiniPlayerGoesWhenSwipedFarOrFlicked() {
        val width = 1000f
        assertTrue(Motion.swipeDismisses(offset = 400f, velocity = 0f, width = width, flick = flick))
        assertTrue(Motion.swipeDismisses(offset = -400f, velocity = 0f, width = width, flick = flick))
        // A short flick either way is enough.
        assertTrue(Motion.swipeDismisses(offset = 60f, velocity = 4000f, width = width, flick = flick))
        assertTrue(Motion.swipeDismisses(offset = -60f, velocity = -4000f, width = width, flick = flick))
    }

    @Test fun theMiniPlayerStaysForShortDragsAndFlicksBack() {
        val width = 1000f
        assertFalse(Motion.swipeDismisses(offset = 200f, velocity = 500f, width = width, flick = flick))
        // Dragged far, then flicked back toward the middle: it stays.
        assertFalse(Motion.swipeDismisses(offset = 500f, velocity = -4000f, width = width, flick = flick))
        assertFalse(Motion.swipeDismisses(offset = 0f, velocity = 4000f, width = width, flick = flick))
    }

    @Test fun theCurvesStartAndEndInPlace() {
        for (easing in listOf(Motion.EmphasizedDecelerate, Motion.EmphasizedAccelerate, Motion.Standard)) {
            assertEquals(0f, easing.transform(0f), 0.001f)
            assertEquals(1f, easing.transform(1f), 0.001f)
        }
    }

    @Test fun enteringIsFastFirstAndLeavingIsFastLast() {
        // A quarter of the way in, something entering is already most of the way there...
        assertTrue(Motion.EmphasizedDecelerate.transform(0.25f) > 0.6f)
        // ...and something leaving has barely started.
        assertTrue(Motion.EmphasizedAccelerate.transform(0.25f) < 0.1f)
    }

    /** A frame clock that runs animations instantly, 16 ms a frame. */
    private class Clock : MonotonicFrameClock {
        var t = 0L
        override suspend fun <R> withFrameNanos(onFrame: (Long) -> R): R { t += 16_000_000; return onFrame(t) }
    }

    /** Runs `spec` from 0 to 1 and records (ms, value) for each frame. */
    private fun run(spec: AnimationSpec<Float>, velocity: Float = 0f): List<Pair<Long, Float>> {
        val frames = mutableListOf<Pair<Long, Float>>()
        val clock = Clock()
        var start = -1L
        runBlocking(clock) {
            animate(0f, 1f, initialVelocity = velocity, animationSpec = spec) { value, _ ->
                if (start < 0) start = clock.t
                frames += (clock.t - start) / 1_000_000 to value
            }
        }
        return frames
    }

    @Test fun openingAVideoIsQuickAndLandsWithoutAWobble() {
        val frames = run(Motion.Sheet)
        val nearlyThere = frames.first { it.second >= 0.98f }.first
        assertTrue("reached 98% at $nearlyThere ms", nearlyThere <= 260)
        assertTrue("finished at ${frames.last().first} ms", frames.last().first <= 450)
        assertTrue(frames.all { it.second <= 1f })
        assertEquals(1f, frames.last().second)
    }

    @Test fun aFlickKeepsItsSpeed() {
        val fromRest = run(Motion.Sheet).first { it.second >= 0.9f }.first
        val flicked = run(Motion.Sheet, velocity = 4f).first { it.second >= 0.9f }.first
        assertTrue("flicked $flicked ms, from rest $fromRest ms", flicked < fromRest)
    }
}

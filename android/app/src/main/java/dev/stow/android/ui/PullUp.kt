package dev.stow.android.ui

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.remember
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.unit.dp
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Pull up at the end of a list: the drag the list can't use any more (it's at its end) pulls a
 * spinner up from the bottom, and letting go past [threshold] pixels calls [onPull]. Only a drag
 * that starts at the end pulls: one that scrolls the list and then hits the end doesn't (so
 * swiping down quickly to the bottom never refreshes by accident), and nor does a fling.
 */
class PullUp(private val threshold: Float, private val busy: () -> Boolean, private val onPull: () -> Unit) : NestedScrollConnection {
    /** The finger's travel past the end, in pixels. */
    var drag by mutableFloatStateOf(0f)
        private set

    /** How far the spinner has come up: half the finger's travel, like a rubber band. */
    val distance get() = drag * RESISTANCE

    /** 0 to 1 while pulling; 1 means letting go refreshes. */
    val progress get() = min(distance / threshold, 1f)

    private var armedFired = false
    var onArmed: () -> Unit = {}

    /** This drag has scrolled the list, so it can't pull; the next drag starts afresh. */
    private var scrolledList = false

    override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
        // The finger moving back down takes the pull back first, before the list scrolls.
        if (source == NestedScrollSource.UserInput && available.y > 0 && drag > 0) {
            val used = min(available.y, drag)
            pullTo(drag - used)
            return Offset(0f, used)
        }
        return Offset.Zero
    }

    override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
        if (source != NestedScrollSource.UserInput) return Offset.Zero
        if (consumed.y != 0f) scrolledList = true
        if (available.y < 0 && !busy() && !scrolledList) {
            pullTo(drag - available.y)
            return Offset(0f, available.y)
        }
        return Offset.Zero
    }

    override suspend fun onPreFling(available: Velocity): Velocity {
        // The finger has let go: whatever it did, the next drag can pull.
        scrolledList = false
        if (drag <= 0f) return Velocity.Zero
        val fire = distance >= threshold
        armedFired = false
        if (fire) onPull()
        // Back down on a firm spring with no wobble. A finger already moving back down hands its
        // speed on; one still pulling up doesn't, so the spinner never jumps further up on release.
        animate(drag, 0f, initialVelocity = (-available.y).coerceAtMost(0f), animationSpec = SETTLE) { value, _ -> drag = value }
        return available
    }

    private fun pullTo(value: Float) {
        drag = value.coerceAtLeast(0f)
        if (!armedFired && distance >= threshold) { armedFired = true; onArmed() }
        if (armedFired && distance < threshold) armedFired = false
    }

    companion object {
        const val RESISTANCE = 0.5f
        private val SETTLE = spring<Float>(dampingRatio = 1f, stiffness = Spring.StiffnessMediumLow)
    }
}

/** The spinner at the bottom: comes up with the pull, then spins at [restPx] while refreshing. */
@Composable
fun BoxScope.PullUpIndicator(pull: PullUp, refreshing: Boolean, restPx: Float) {
    val active = refreshing || pull.drag > 0f
    // When the refresh is done the spinner shrinks and fades where it is (like Material's
    // pull-to-refresh) instead of vanishing in one frame.
    // Only the going is animated: while a finger pulls (or it spins) it's at full size at once, so
    // it follows the pull from the first pixel instead of growing in behind it.
    val fade by animateFloatAsState(if (active) 1f else 0f, if (active) snap() else tween(Motion.SHORT), label = "pull-up")
    val shown = if (active) 1f else fade
    // Where it was and what it showed while active, kept for that shrink.
    val held = remember { FloatArray(1) }
    val heldSpin = remember { BooleanArray(1) }
    val liveLift = if (refreshing) maxOf(restPx, pull.distance) else pull.distance
    if (active) { held[0] = liveLift; heldSpin[0] = refreshing }
    if (!active && shown == 0f) return
    val hiddenPx = with(LocalDensity.current) { 48.dp.toPx() }
    val lift = if (active) liveLift else held[0]
    val spinning = if (active) refreshing else heldSpin[0]
    Box(Modifier.align(Alignment.BottomCenter)
            .offset { IntOffset(0, (hiddenPx - min(lift, restPx * 1.4f)).roundToInt()) }
            .graphicsLayer {
                alpha = (if (spinning) 1f else pull.progress.coerceIn(0.25f, 1f)) * shown
                scaleX = shown
                scaleY = shown
            }) {
        Surface(shape = CircleShape, color = Stow.colors.background, shadowElevation = 3.dp, modifier = Modifier.size(40.dp)) {
            // The filling arc crossfades into the spinner when the pull fires.
            Crossfade(spinning, animationSpec = tween(100), label = "pull-up-spin") { spin ->
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    if (spin) CircularProgressIndicator(color = Stow.colors.accent, strokeWidth = 2.5.dp, modifier = Modifier.size(22.dp))
                    else CircularProgressIndicator(progress = { pull.progress }, color = Stow.colors.accent, strokeWidth = 2.5.dp,
                                                   trackColor = Stow.colors.chip, modifier = Modifier.size(22.dp))
                }
            }
        }
    }
}

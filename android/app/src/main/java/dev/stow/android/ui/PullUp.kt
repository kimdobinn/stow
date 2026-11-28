package dev.stow.android.ui

import androidx.compose.animation.core.animate
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
 * spinner up from the bottom, and letting go past [threshold] pixels calls [onPull]. Only the
 * finger counts, so a fling that hits the end doesn't refresh.
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
        if (source == NestedScrollSource.UserInput && available.y < 0 && !busy()) {
            pullTo(drag - available.y)
            return Offset(0f, available.y)
        }
        return Offset.Zero
    }

    override suspend fun onPreFling(available: Velocity): Velocity {
        if (drag <= 0f) return Velocity.Zero
        val fire = distance >= threshold
        armedFired = false
        if (fire) onPull()
        animate(drag, 0f) { value, _ -> drag = value }
        return available
    }

    private fun pullTo(value: Float) {
        drag = value.coerceAtLeast(0f)
        if (!armedFired && distance >= threshold) { armedFired = true; onArmed() }
        if (armedFired && distance < threshold) armedFired = false
    }

    companion object { const val RESISTANCE = 0.5f }
}

/** The spinner at the bottom: comes up with the pull, then spins at [restPx] while refreshing. */
@Composable
fun BoxScope.PullUpIndicator(pull: PullUp, refreshing: Boolean, restPx: Float) {
    if (!refreshing && pull.drag <= 0f) return
    val hiddenPx = with(LocalDensity.current) { 48.dp.toPx() }
    val lift = if (refreshing) maxOf(restPx, pull.distance) else pull.distance
    Box(Modifier.align(Alignment.BottomCenter)
            .offset { IntOffset(0, (hiddenPx - min(lift, restPx * 1.4f)).roundToInt()) }
            .graphicsLayer { alpha = if (refreshing) 1f else pull.progress.coerceIn(0.25f, 1f) }) {
        Surface(shape = CircleShape, color = Stow.colors.background, shadowElevation = 3.dp, modifier = Modifier.size(40.dp)) {
            Box(contentAlignment = Alignment.Center) {
                if (refreshing) CircularProgressIndicator(color = Stow.colors.accent, strokeWidth = 2.5.dp, modifier = Modifier.size(22.dp))
                else CircularProgressIndicator(progress = { pull.progress }, color = Stow.colors.accent, strokeWidth = 2.5.dp,
                                               trackColor = Stow.colors.chip, modifier = Modifier.size(22.dp))
            }
        }
    }
}

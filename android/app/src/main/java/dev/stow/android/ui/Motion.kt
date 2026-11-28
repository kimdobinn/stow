package dev.stow.android.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.AnimatedVisibilityScope
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.Easing
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.SpringSpec
import androidx.compose.animation.core.VisibilityThreshold
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.interaction.InteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.lazy.LazyItemScope
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.IntOffset
import kotlin.math.abs
import kotlin.math.sign

/**
 * One small motion system for the whole app, so every animation feels like part of the same thing
 * (YouTube's app follows Material 3's): short fades and state changes, a little longer for things
 * moving across the screen, decelerating as they come in and accelerating as they leave, and
 * critically damped springs (no wobble) for anything a finger drags, so a release keeps its speed.
 *
 * Compose scales every tween and spring by the phone's animator duration scale, and "Remove
 * animations" sets it to 0, so reduced motion needs nothing more here as long as nothing moves by
 * a hand-written delay or frame loop.
 */
object Motion {
    /** Things coming on screen: fast at first, then easing gently into place. */
    val EmphasizedDecelerate: Easing = CubicBezierEasing(0.05f, 0.7f, 0.1f, 1f)
    /** Things leaving: they gather speed and are gone. */
    val EmphasizedAccelerate: Easing = CubicBezierEasing(0.3f, 0f, 0.8f, 0.15f)
    /** Things that change in place (a bar thickening, a dot growing). */
    val Standard: Easing = FastOutSlowInEasing

    /** Fades and state changes. */
    const val SHORT = 150
    /** Something moving on screen (a banner opening, a snackbar coming up). */
    const val MEDIUM = 250
    /** A whole screen sliding in. */
    const val LONG = 300

    fun <T> enter(ms: Int = MEDIUM): FiniteAnimationSpec<T> = tween(ms, easing = EmphasizedDecelerate)
    fun <T> exit(ms: Int = 200): FiniteAnimationSpec<T> = tween(ms, easing = EmphasizedAccelerate)
    fun <T> fade(ms: Int = SHORT): FiniteAnimationSpec<T> = tween(ms)

    /**
     * The watch page and the mini player: critically damped (it lands without a wobble) and stiff
     * enough that opening a video takes about a quarter of a second, not half.
     */
    val Sheet: SpringSpec<Float> = spring(dampingRatio = 1f, stiffness = 700f, visibilityThreshold = 0.001f)

    /**
     * The same feel for things dragged in pixels (the full-screen video pulled down). Sheet's fine
     * threshold is for its 0-to-1 progress, where the default would snap the last ~20 px.
     */
    val Settle: SpringSpec<Float> = spring(dampingRatio = 1f, stiffness = 700f)

    /** A swiped-away mini player or a row: quick and firm, carrying the flick. */
    val Fling: SpringSpec<Float> = spring(dampingRatio = 1f, stiffness = 900f)

    /** Something let go short of where it would go: back home with no overshoot. */
    val SnapBack: SpringSpec<Float> = spring(dampingRatio = 1f, stiffness = Spring.StiffnessMedium)

    /** Rows sliding to their new place when a list changes. */
    val Placement: SpringSpec<IntOffset> =
        spring(dampingRatio = 1f, stiffness = Spring.StiffnessMediumLow, visibilityThreshold = IntOffset.VisibilityThreshold)

    /** Progress from a download: a spring keeps its speed when the next value comes, so it fills steadily. */
    val Progress: SpringSpec<Float> = spring(dampingRatio = 1f, stiffness = Spring.StiffnessVeryLow)

    /** Pressed buttons and chips: a quick press-in and a lively return. */
    val Press: SpringSpec<Float> = spring(dampingRatio = 0.6f, stiffness = Spring.StiffnessMedium)

    /** How much a pressed button or chip shrinks. */
    const val PRESSED_SCALE = 0.95f

    /** A banner or section opening in a column: it grows downward and fades in, pushing what's below. */
    val ExpandIn: EnterTransition = expandVertically(enter(MEDIUM), expandFrom = Alignment.Top) + fadeIn(tween(200))
    /** And closing: it folds up and fades. */
    val CollapseOut: ExitTransition = shrinkVertically(exit(200), shrinkTowards = Alignment.Top) + fadeOut(tween(SHORT))

    /** Faster than this (in dp per second) and a let-go drag counts as a flick, on any screen size. */
    const val FLICK_DP_PER_SECOND = 1000f

    /**
     * Where the player lands when let go: a flick goes the way it was flicked, otherwise the nearer
     * end. `velocity` is toward the watch page (positive) or the mini player, in the same units as
     * `flick` (pixels per second), so short flicks work the same on every phone.
     */
    fun sheetTarget(progress: Float, velocity: Float, flick: Float): Float = when {
        velocity > flick -> 1f
        velocity < -flick -> 0f
        progress > 0.5f -> 1f
        else -> 0f
    }

    /**
     * Whether a mini player swiped sideways by `offset` goes away: a flick either way decides
     * (back toward the middle keeps it), otherwise it has to be past a third of the width.
     */
    fun swipeDismisses(offset: Float, velocity: Float, width: Float, flick: Float): Boolean = when {
        abs(velocity) > flick -> offset != 0f && sign(velocity) == sign(offset)
        else -> abs(offset) > width * 0.35f
    }
}

/** How each row of a list comes, goes and moves: fades in and out, slides to its new place. */
fun LazyItemScope.itemMotion(): Modifier =
    Modifier.animateItem(fadeInSpec = tween(Motion.SHORT), placementSpec = Motion.Placement, fadeOutSpec = tween(100))

/** A slight press-in, like YouTube's buttons and chips; it springs back on release. */
@Composable
fun Modifier.pressScale(interaction: InteractionSource): Modifier {
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) Motion.PRESSED_SCALE else 1f, Motion.Press, label = "press")
    // Read in the layer, so pressing redraws the button without recomposing it.
    return this.graphicsLayer { scaleX = scale; scaleY = scale }
}

/**
 * Shows and hides `content` with the given transitions. The same as Compose's AnimatedVisibility,
 * but callable anywhere: inside a Row or Column the scoped versions would be picked (or refused,
 * inside a Box in a Column), and those come with their own defaults.
 */
@Composable
fun Appear(
    visible: Boolean, modifier: Modifier = Modifier, enter: EnterTransition, exit: ExitTransition,
    content: @Composable AnimatedVisibilityScope.() -> Unit,
) = AnimatedVisibility(visible, modifier, enter, exit, content = content)

/** The last non-null value, so something fading out can still show what it was. */
@Composable
fun <T : Any> rememberLast(value: T?): T? {
    // Plain memory, not state: the caller recomposes when `value` changes anyway.
    val last = remember { arrayOfNulls<Any>(1) }
    if (value != null) last[0] = value
    @Suppress("UNCHECKED_CAST")
    return value ?: last[0] as T?
}

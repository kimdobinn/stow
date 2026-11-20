package dev.stow.android.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

/** The Mac app icon's orange → pink → purple. */
val StowGradient = Brush.linearGradient(listOf(Color(0xFFFF8A3D), Color(0xFFFF3D7F), Color(0xFF8B5CF6)))

/** YouTube's red, for progress bars and the scrubber. */
val ProgressRed = Color(0xFFFF0000)

/** The flat greys of YouTube's mobile app. */
@Immutable
data class StowColors(
    val background: Color,
    val text: Color,
    val secondaryText: Color,
    val chip: Color,
    val chipSelected: Color,
    val chipSelectedText: Color,
    val divider: Color,
    val raised: Color,
)

private val Light = StowColors(
    background = Color(0xFFFFFFFF), text = Color(0xFF0F0F0F), secondaryText = Color(0xFF606060),
    chip = Color(0xFFF2F2F2), chipSelected = Color(0xFF0F0F0F), chipSelectedText = Color.White,
    divider = Color(0xFFE5E5E5), raised = Color(0xFFFFFFFF),
)

private val Dark = StowColors(
    background = Color(0xFF0F0F0F), text = Color(0xFFF1F1F1), secondaryText = Color(0xFFAAAAAA),
    chip = Color(0xFF272727), chipSelected = Color(0xFFF1F1F1), chipSelectedText = Color(0xFF0F0F0F),
    divider = Color(0xFF3F3F3F), raised = Color(0xFF212121),
)

val LocalStowColors = staticCompositionLocalOf { Light }

/** Calm mode: titles only, no thumbnails. */
val LocalCalm = androidx.compose.runtime.compositionLocalOf { false }

object Stow {
    val colors: StowColors @Composable get() = LocalStowColors.current
}

@Composable
fun StowTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val colors = if (dark) Dark else Light
    val scheme = if (dark) {
        darkColorScheme(
            primary = Color(0xFF3EA6FF), onPrimary = Color(0xFF0F0F0F),
            background = colors.background, onBackground = colors.text,
            surface = colors.background, onSurface = colors.text,
            surfaceVariant = colors.chip, onSurfaceVariant = colors.secondaryText,
            surfaceContainer = colors.raised, surfaceContainerHigh = colors.raised, surfaceContainerLow = colors.background,
            secondaryContainer = colors.chip, onSecondaryContainer = colors.text,
            outline = colors.divider, outlineVariant = colors.divider, error = Color(0xFFFF4E45),
        )
    } else {
        lightColorScheme(
            primary = Color(0xFF065FD4), onPrimary = Color.White,
            background = colors.background, onBackground = colors.text,
            surface = colors.background, onSurface = colors.text,
            surfaceVariant = colors.chip, onSurfaceVariant = colors.secondaryText,
            surfaceContainer = colors.raised, surfaceContainerHigh = colors.raised, surfaceContainerLow = colors.background,
            secondaryContainer = colors.chip, onSecondaryContainer = colors.text,
            outline = colors.divider, outlineVariant = colors.divider, error = Color(0xFFCC0000),
        )
    }
    androidx.compose.runtime.CompositionLocalProvider(LocalStowColors provides colors) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}

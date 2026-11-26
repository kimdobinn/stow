package dev.stow.android.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import dev.stow.android.data.AppTheme

/** The app icon's orange → pink → purple: the download ring and the app mark, nowhere else. */
val StowGradient = Brush.linearGradient(listOf(Color(0xFFFF8A3D), Color(0xFFFF2D55), Color(0xFF8B5CF6)))
val StowGradientColors = listOf(Color(0xFFFF8A3D), Color(0xFFFF2D55), Color(0xFF8B5CF6), Color(0xFFFF8A3D))

/**
 * Apple-style semantic colors, by role. Contrast against `background`:
 * text 21:1; secondaryText #6C6C70 5.2:1 (light), #98989F 7.3:1 (dark, 5.9:1 on `raised`);
 * accent #FF2D55 3.7:1 (light, bold text and fills only), #FF375F 6.0:1 (dark).
 */
@Immutable
data class StowColors(
    /** Screens with content: plain lists and feeds. */
    val background: Color,
    /** Behind inset grouped sections (Settings, sheets). */
    val groupedBackground: Color,
    val text: Color,
    val secondaryText: Color,
    /** Fills for controls: chips, buttons, the segmented control's track. */
    val chip: Color,
    val chipSelected: Color,
    val chipSelectedText: Color,
    val divider: Color,
    /** Grouped rows, the tab bar, the segmented control's thumb. */
    val raised: Color,
    /** Primary actions, the selected tab, status. */
    val accent: Color,
)

private val Light = StowColors(
    background = Color(0xFFFFFFFF), groupedBackground = Color(0xFFF2F2F7),
    text = Color(0xFF000000), secondaryText = Color(0xFF6C6C70),
    chip = Color(0xFFEEEEF0), chipSelected = Color(0xFF000000), chipSelectedText = Color.White,
    divider = Color(0xFFD1D1D6), raised = Color(0xFFFFFFFF), accent = Color(0xFFFF2D55),
)

private val Dark = StowColors(
    background = Color(0xFF000000), groupedBackground = Color(0xFF000000),
    text = Color(0xFFFFFFFF), secondaryText = Color(0xFF98989F),
    chip = Color(0xFF2C2C2E), chipSelected = Color(0xFFFFFFFF), chipSelectedText = Color(0xFF000000),
    divider = Color(0xFF38383A), raised = Color(0xFF1C1C1E), accent = Color(0xFFFF375F),
)

/**
 * Warm paper: off-white and cream with a terracotta accent. Contrast: text 16:1; secondaryText
 * #66655F 5.6:1 on `background`, 5.0:1 on `groupedBackground`; accent #C96442 4.8:1.
 */
private val Paper = StowColors(
    background = Color(0xFFFAF9F5), groupedBackground = Color(0xFFF0EEE6),
    text = Color(0xFF1F1E1D), secondaryText = Color(0xFF66655F),
    chip = Color(0xFFEDEBE3), chipSelected = Color(0xFF1F1E1D), chipSelectedText = Color(0xFFFAF9F5),
    divider = Color(0xFFDEDBD0), raised = Color(0xFFFFFEFB), accent = Color(0xFFC96442),
)

/** The colors a theme uses (Automatic follows the phone's dark mode). */
fun stowColors(theme: AppTheme, systemDark: Boolean): StowColors = when {
    theme.isDark(systemDark) -> Dark
    theme == AppTheme.PAPER -> Paper
    else -> Light
}

val LocalStowColors = staticCompositionLocalOf { Light }

/** Calm mode: titles only, no thumbnails. */
val LocalCalm = androidx.compose.runtime.compositionLocalOf { false }

object Stow {
    val colors: StowColors @Composable get() = LocalStowColors.current
}

/** Apple's text styles (in sp, so they follow the system font size). */
object StowType {
    val largeTitle = TextStyle(fontSize = 32.sp, lineHeight = 38.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.4).sp)
    val title2 = TextStyle(fontSize = 22.sp, lineHeight = 28.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.3).sp)
    val title3 = TextStyle(fontSize = 20.sp, lineHeight = 25.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.2).sp)
    val headline = TextStyle(fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.2).sp)
    val body = TextStyle(fontSize = 17.sp, lineHeight = 22.sp, letterSpacing = (-0.2).sp)
    val callout = TextStyle(fontSize = 16.sp, lineHeight = 21.sp, letterSpacing = (-0.1).sp)
    val subheadline = TextStyle(fontSize = 15.sp, lineHeight = 20.sp, letterSpacing = (-0.1).sp)
    val footnote = TextStyle(fontSize = 13.sp, lineHeight = 18.sp)
    val caption = TextStyle(fontSize = 12.sp, lineHeight = 16.sp)
}

@Composable
fun StowTheme(theme: AppTheme = AppTheme.SYSTEM, content: @Composable () -> Unit) {
    val systemDark = isSystemInDarkTheme()
    val dark = theme.isDark(systemDark)
    val colors = stowColors(theme, systemDark)
    val scheme = if (dark) {
        darkColorScheme(
            primary = colors.accent, onPrimary = Color.White,
            background = colors.background, onBackground = colors.text,
            surface = colors.background, onSurface = colors.text,
            surfaceVariant = colors.chip, onSurfaceVariant = colors.secondaryText,
            surfaceContainer = colors.raised, surfaceContainerHigh = colors.raised, surfaceContainerHighest = colors.raised,
            surfaceContainerLow = colors.background,
            secondaryContainer = colors.chip, onSecondaryContainer = colors.text,
            outline = colors.divider, outlineVariant = colors.divider, error = Color(0xFFFF453A),
        )
    } else {
        lightColorScheme(
            primary = colors.accent, onPrimary = Color.White,
            background = colors.background, onBackground = colors.text,
            surface = colors.background, onSurface = colors.text,
            surfaceVariant = colors.chip, onSurfaceVariant = colors.secondaryText,
            surfaceContainer = colors.raised, surfaceContainerHigh = colors.raised, surfaceContainerHighest = colors.raised,
            surfaceContainerLow = colors.background,
            secondaryContainer = colors.chip, onSecondaryContainer = colors.text,
            outline = colors.divider, outlineVariant = colors.divider, error = Color(0xFFD70015),
        )
    }
    val type = Typography(
        bodyLarge = StowType.body, bodyMedium = StowType.subheadline, bodySmall = StowType.footnote,
        titleLarge = StowType.title2, titleMedium = StowType.headline, titleSmall = StowType.subheadline.copy(fontWeight = FontWeight.SemiBold),
        labelLarge = StowType.subheadline.copy(fontWeight = FontWeight.SemiBold), labelMedium = StowType.footnote, labelSmall = StowType.caption,
        headlineSmall = StowType.title2,
    )
    androidx.compose.runtime.CompositionLocalProvider(LocalStowColors provides colors) {
        MaterialTheme(colorScheme = scheme, typography = type, content = content)
    }
}

/** Channel pictures by channel id: the Mac's channels', and the ones it looked up for YouTube's feeds. */
val LocalChannelAvatars = androidx.compose.runtime.compositionLocalOf<Map<String, String>> { emptyMap() }

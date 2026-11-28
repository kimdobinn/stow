package dev.stow.android.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.SystemUpdate
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.stow.android.update.Release
import dev.stow.android.update.Updater

/** A newer version is out: the settings buttons get a dot. */
val LocalUpdateAvailable = compositionLocalOf { false }

/** The release an update in progress is for (null when none is). */
val Updater.Install.release: Release?
    get() = when (this) {
        Updater.Install.Idle -> null
        is Updater.Install.NeedsPermission -> release
        is Updater.Install.Downloading -> release
        is Updater.Install.Installing -> release
        is Updater.Install.Confirm -> release
        is Updater.Install.Failed -> release
    }

/**
 * The update, from its release notes to Android's installer: what's new (Update / Not now), the
 * "allow from this source" step, the download's progress, then waiting on Android's confirm screen.
 */
@Composable
fun UpdateDialog(updater: Updater, release: Release, onDismiss: () -> Unit) {
    val install by updater.install.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val close = { updater.dismiss(); onDismiss() }
    when (val state = install) {
        Updater.Install.Idle -> AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text("Stow ${release.version}") },
            text = {
                Column {
                    Text("You have ${updater.currentVersion}. The download is ${Format.bytes(release.apkSize)}.",
                         style = StowType.footnote, color = Stow.colors.secondaryText)
                    if (release.notes.isNotBlank()) {
                        Spacer(Modifier.height(12.dp))
                        Text(release.notes, fontSize = 15.sp, lineHeight = 21.sp, color = Stow.colors.text,
                             modifier = Modifier.heightIn(max = 320.dp).verticalScroll(rememberScrollState()))
                    }
                }
            },
            confirmButton = { TextButton(onClick = { updater.update(release) }) { Text("Update", fontWeight = FontWeight.SemiBold) } },
            dismissButton = { TextButton(onClick = onDismiss) { Text("Not now") } },
        )
        is Updater.Install.NeedsPermission -> AlertDialog(
            onDismissRequest = close,
            title = { Text("Allow updates") },
            text = { Text("Turn on “Allow from this source” for Stow, then come back here to install.") },
            confirmButton = {
                TextButton(onClick = { context.startActivity(updater.allowInstallsIntent()) }) {
                    Text("Open settings", fontWeight = FontWeight.SemiBold)
                }
            },
            dismissButton = { TextButton(onClick = close) { Text("Cancel") } },
        )
        is Updater.Install.Downloading -> AlertDialog(
            // Only Cancel stops it.
            onDismissRequest = {},
            title = { Text("Downloading ${state.release.version}") },
            text = {
                Column {
                    // Fills steadily between the download's updates instead of stepping.
                    val shown by animateFloatAsState((state.bytes.toFloat() / state.release.apkSize).coerceIn(0f, 1f), Motion.Progress, label = "update")
                    LinearProgressIndicator(
                        progress = { shown },
                        color = Stow.colors.accent, trackColor = Stow.colors.chip,
                        modifier = Modifier.fillMaxWidth().height(6.dp).clip(RoundedCornerShape(3.dp)),
                        drawStopIndicator = {},
                    )
                    Spacer(Modifier.height(10.dp))
                    Text("${Format.bytes(state.bytes)} of ${Format.bytes(state.release.apkSize)}",
                         style = StowType.footnote, color = Stow.colors.secondaryText)
                }
            },
            confirmButton = { TextButton(onClick = { updater.cancel() }) { Text("Cancel") } },
        )
        is Updater.Install.Installing, is Updater.Install.Confirm -> AlertDialog(
            onDismissRequest = close,
            title = { Text("Installing ${state.release?.version.orEmpty()}") },
            text = { Text("Confirm on Android's screen. Stow closes to update; open it again when it's done.") },
            confirmButton = { TextButton(onClick = close) { Text("Close") } },
        )
        is Updater.Install.Failed -> AlertDialog(
            onDismissRequest = close,
            title = { Text("Couldn't update") },
            text = { Text(state.message) },
            confirmButton = { TextButton(onClick = { updater.update(state.release) }) { Text("Try again", fontWeight = FontWeight.SemiBold) } },
            dismissButton = { TextButton(onClick = close) { Text("Close") } },
        )
    }
}

/** Home's one line about a newer version; closing it hides it until the next one. */
@Composable
fun UpdateBanner(version: String, onOpen: () -> Unit, onDismiss: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp).clip(RoundedCornerShape(14.dp))
            .background(Stow.colors.chip).clickable(onClick = onOpen).padding(start = 14.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Rounded.SystemUpdate, contentDescription = null, tint = Stow.colors.accent, modifier = Modifier.size(22.dp))
        Spacer(Modifier.width(12.dp))
        Text("Stow $version is out", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = Stow.colors.text,
             maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        Text("See what's new", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = Stow.colors.accent, maxLines = 1)
        Box(Modifier.size(40.dp).clip(CircleShape).clickable(onClickLabel = "Hide", onClick = onDismiss), contentAlignment = Alignment.Center) {
            Icon(Icons.Rounded.Close, contentDescription = "Hide", tint = Stow.colors.secondaryText, modifier = Modifier.size(18.dp))
        }
    }
}

/** The small dot on a button or row that says there's an update. */
@Composable
fun UpdateDot(modifier: Modifier = Modifier) {
    Box(modifier.size(9.dp).clip(CircleShape).background(Stow.colors.accent))
}

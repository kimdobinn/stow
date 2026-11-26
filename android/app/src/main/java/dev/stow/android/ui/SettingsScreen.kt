package dev.stow.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Alarm
import androidx.compose.material.icons.rounded.BarChart
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.Contrast
import androidx.compose.material.icons.rounded.DeleteForever
import androidx.compose.material.icons.rounded.DeleteSweep
import androidx.compose.material.icons.rounded.HideImage
import androidx.compose.material.icons.rounded.PlayCircle
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.material.icons.rounded.LinkOff
import androidx.compose.material.icons.rounded.SdStorage
import androidx.compose.material.icons.rounded.SystemUpdateAlt
import androidx.compose.material.icons.rounded.Wifi
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.stow.android.data.DownloadState
import dev.stow.android.data.Repository
import dev.stow.android.sync.YtDlp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Downloads, the downloader and the pairing, in YouTube's plain settings style. */
@Composable
fun SettingsScreen(repository: Repository, wifiOnly: Boolean, onReport: () -> Unit, onRemote: () -> Unit, onGroups: () -> Unit, onBack: () -> Unit) {
    val groups by repository.groups.collectAsStateWithLifecycle()
    val autoplay by repository.prefs.autoplay.collectAsStateWithLifecycle()
    val calm by repository.prefs.calm.collectAsStateWithLifecycle()
    val grayscale by repository.prefs.grayscale.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var storage by remember { mutableStateOf<Long?>(null) }
    var ytdlp by remember { mutableStateOf<String?>(null) }
    var updating by remember { mutableStateOf(false) }
    var confirmUnpair by remember { mutableStateOf(false) }
    var confirmDeleteWatched by remember { mutableStateOf(false) }
    var confirmDeleteAll by remember { mutableStateOf(false) }

    LaunchedEffect(updating) {
        if (!updating) {
            storage = withContext(Dispatchers.IO) { repository.storageUsedBytes() }
            ytdlp = withContext(Dispatchers.IO) { YtDlp.ensureReady(context); YtDlp.version(context) }
        }
    }

    Column(Modifier.fillMaxSize().background(Stow.colors.groupedBackground)) {
        BackTopBar("Settings", onBack)
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
            Section("Watching") {
                SettingRow(Icons.Rounded.BarChart, Purple, "Your week", "Time watched per day and channel", onClick = onReport, chevron = true)
                SettingRow(Icons.Rounded.Folder, Orange, "Channel groups",
                           if (groups.isEmpty()) "Home can show just the channels you pick" else Format.count(groups.size, "group"),
                           onClick = onGroups, chevron = true)
                SettingRow(Icons.Rounded.PlayArrow, Blue, "Autoplay next video", if (autoplay) "Plays the next video in the list" else "Stops at the end of each video",
                           onClick = { repository.prefs.setAutoplay(!autoplay) }) {
                    StowSwitch(autoplay, repository.prefs::setAutoplay)
                }
                SettingRow(Icons.Rounded.HideImage, Teal, "Calm mode", "Titles only, no thumbnails",
                           onClick = { repository.prefs.setCalm(!calm) }) {
                    StowSwitch(calm, repository.prefs::setCalm)
                }
                SettingRow(Icons.Rounded.Contrast, Gray, "Black and white", "The app in grayscale (videos stay in color)",
                           onClick = { repository.prefs.setGrayscale(!grayscale) }, last = true) {
                    StowSwitch(grayscale, repository.prefs::setGrayscale)
                }
            }
            Section("Downloads", footer = "Videos download only when you tap the download button, here or with Send to Phone on the Mac.") {
                SettingRow(Icons.Rounded.Wifi, Blue, "Download on Wi-Fi only", if (wifiOnly) "Waits for Wi-Fi" else "Also uses mobile data",
                           onClick = { repository.setWifiOnly(!wifiOnly) }) {
                    StowSwitch(wifiOnly, repository::setWifiOnly)
                }
                SettingRow(Icons.Rounded.SdStorage, Gray, "Storage used", storage?.let(Format::bytes) ?: "…")
                SettingRow(Icons.Rounded.DeleteSweep, Orange, "Delete watched downloads", "Frees space; videos stay in your lists",
                           onClick = { confirmDeleteWatched = true })
                SettingRow(Icons.Rounded.DeleteForever, Red, "Delete all downloads", "Every video on this phone, watched or not",
                           onClick = { confirmDeleteAll = true }, destructive = true, last = true)
            }
            Section("Downloader") {
                SettingRow(Icons.Rounded.SystemUpdateAlt, Green, "Update yt-dlp",
                           if (updating) "Updating…" else "Version ${ytdlp ?: "…"} · checks daily by itself",
                           onClick = if (updating) null else ({
                               updating = true
                               scope.launch {
                                   YtDlp.updateIfDue(context, repository.prefs, force = true)
                                   updating = false
                               }
                           }), last = true)
            }
            Section("Mac") {
                SettingRow(Icons.Rounded.Alarm, Indigo, "Alarm remote", "Control the Mac's morning alarm from this phone", onClick = onRemote, chevron = true)
                SettingRow(Icons.Rounded.LinkOff, Red, "Unpair this phone", "Paired with Firebase project ${repository.prefs.pairedProject ?: "–"}",
                           onClick = { confirmUnpair = true }, destructive = true, last = true)
            }
        }
    }

    if (confirmUnpair) {
        AlertDialog(
            onDismissRequest = { confirmUnpair = false },
            title = { Text("Unpair this phone?") },
            text = { Text("It stops getting videos until you scan a new code. Downloads stay. Also unpair it on the Mac (Stow › Phone).") },
            confirmButton = { TextButton(onClick = { confirmUnpair = false; repository.unpair(); onBack() }) { Text("Unpair") } },
            dismissButton = { TextButton(onClick = { confirmUnpair = false }) { Text("Cancel") } },
        )
    }
    if (confirmDeleteAll) {
        val count = remember { repository.downloadIds().size }
        AlertDialog(
            onDismissRequest = { confirmDeleteAll = false },
            title = { Text("Delete all downloads?") },
            text = {
                Text("Deletes ${if (count == 1) "1 video" else "$count videos"} (${storage?.let(Format::bytes) ?: "…"}) from this phone " +
                     "and stops downloads under way. Videos stay in your lists; they aren't downloaded again unless you ask.")
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmDeleteAll = false
                    repository.deleteAllDownloads()
                    storage = repository.storageUsedBytes()
                }) { Text("Delete All") }
            },
            dismissButton = { TextButton(onClick = { confirmDeleteAll = false }) { Text("Cancel") } },
        )
    }
    if (confirmDeleteWatched) {
        AlertDialog(
            onDismissRequest = { confirmDeleteWatched = false },
            title = { Text("Delete watched downloads?") },
            confirmButton = {
                TextButton(onClick = {
                    confirmDeleteWatched = false
                    repository.items.value.values
                        .filter { it.watched && it.state == DownloadState.DOWNLOADED }
                        .forEach { repository.deleteDownload(it.id) }
                    storage = repository.storageUsedBytes()
                }) { Text("Delete") }
            },
            dismissButton = { TextButton(onClick = { confirmDeleteWatched = false }) { Text("Cancel") } },
        )
    }
}

private val Purple = Color(0xFFAF52DE)
private val Blue = Color(0xFF007AFF)
private val Teal = Color(0xFF30B0C7)
private val Gray = Color(0xFF8E8E93)
private val Orange = Color(0xFFFF9500)
private val Red = Color(0xFFFF3B30)
private val Green = Color(0xFF34C759)
private val Indigo = Color(0xFF5856D6)

/** An inset grouped section: a small header, rounded rows, and an optional note under it. */
@Composable
private fun Section(title: String, footer: String? = null, content: @Composable () -> Unit) {
    Text(title, style = StowType.footnote, fontWeight = FontWeight.SemiBold, color = Stow.colors.secondaryText,
         modifier = Modifier.padding(start = 32.dp, end = 32.dp, top = 24.dp, bottom = 7.dp))
    Column(Modifier.padding(horizontal = 16.dp).fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Stow.colors.raised)) {
        content()
    }
    if (footer != null) {
        Text(footer, style = StowType.footnote, color = Stow.colors.secondaryText,
             modifier = Modifier.padding(start = 32.dp, end = 32.dp, top = 7.dp))
    }
}

/** A row: a white symbol on a colored rounded square, the title and a line under it, then a control. */
@Composable
private fun SettingRow(icon: ImageVector, tint: Color, title: String, subtitle: String, onClick: (() -> Unit)? = null,
                       chevron: Boolean = false, destructive: Boolean = false, last: Boolean = false,
                       trailing: (@Composable () -> Unit)? = null) {
    Column(Modifier.fillMaxWidth().then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)) {
        Row(Modifier.fillMaxWidth().heightIn(min = 60.dp).padding(start = 16.dp, end = 14.dp, top = 10.dp, bottom = 10.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(30.dp).clip(RoundedCornerShape(8.dp)).background(tint), contentAlignment = Alignment.Center) {
                Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(19.dp))
            }
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(title, style = StowType.body, color = if (destructive) Red else Stow.colors.text)
                Text(subtitle, style = StowType.footnote, color = Stow.colors.secondaryText)
            }
            trailing?.invoke()
            if (chevron) {
                Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null, tint = Stow.colors.secondaryText,
                     modifier = Modifier.size(22.dp))
            }
        }
        if (!last) HorizontalDivider(Modifier.padding(start = 60.dp), thickness = 0.5.dp, color = Stow.colors.divider)
    }
}

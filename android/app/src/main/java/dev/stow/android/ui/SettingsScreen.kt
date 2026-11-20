package dev.stow.android.ui

import androidx.compose.foundation.clickable
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
import androidx.compose.material.icons.outlined.DeleteSweep
import androidx.compose.material.icons.outlined.LinkOff
import androidx.compose.material.icons.outlined.SdStorage
import androidx.compose.material.icons.outlined.SystemUpdateAlt
import androidx.compose.material.icons.outlined.Wifi
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
fun SettingsScreen(repository: Repository, wifiOnly: Boolean, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var storage by remember { mutableStateOf<Long?>(null) }
    var ytdlp by remember { mutableStateOf<String?>(null) }
    var updating by remember { mutableStateOf(false) }
    var confirmUnpair by remember { mutableStateOf(false) }
    var confirmDeleteWatched by remember { mutableStateOf(false) }

    LaunchedEffect(updating) {
        if (!updating) {
            storage = withContext(Dispatchers.IO) { repository.storageUsedBytes() }
            ytdlp = withContext(Dispatchers.IO) { YtDlp.ensureReady(context); YtDlp.version(context) }
        }
    }

    Column(Modifier.fillMaxSize()) {
        BackTopBar("Settings", onBack)
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            Group("Downloads")
            SettingRow(Icons.Outlined.Wifi, "Download on Wi-Fi only", if (wifiOnly) "Waits for Wi-Fi" else "Also uses mobile data",
                       onClick = { repository.setWifiOnly(!wifiOnly) }) {
                Switch(checked = wifiOnly, onCheckedChange = repository::setWifiOnly)
            }
            SettingRow(Icons.Outlined.SdStorage, "Storage used", storage?.let(Format::bytes) ?: "…")
            SettingRow(Icons.Outlined.DeleteSweep, "Delete watched downloads", "Frees space; videos stay in your lists",
                       onClick = { confirmDeleteWatched = true })
            HorizontalDivider(color = Stow.colors.divider)
            Group("Downloader")
            SettingRow(Icons.Outlined.SystemUpdateAlt, "Update yt-dlp",
                       if (updating) "Updating…" else "Version ${ytdlp ?: "…"} · checks daily by itself",
                       onClick = if (updating) null else ({
                           updating = true
                           scope.launch {
                               YtDlp.updateIfDue(context, repository.prefs, force = true)
                               updating = false
                           }
                       }))
            HorizontalDivider(color = Stow.colors.divider)
            Group("Mac")
            SettingRow(Icons.Outlined.LinkOff, "Unpair this phone", "Paired with Firebase project ${repository.prefs.pairedProject ?: "–"}",
                       onClick = { confirmUnpair = true })
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

@Composable
private fun Group(text: String) {
    Text(text, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = Stow.colors.secondaryText,
         modifier = Modifier.padding(start = 16.dp, top = 20.dp, bottom = 4.dp))
}

@Composable
private fun SettingRow(icon: ImageVector, title: String, subtitle: String, onClick: (() -> Unit)? = null,
                       trailing: (@Composable () -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 16.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = Stow.colors.text, modifier = Modifier.size(24.dp))
        Spacer(Modifier.width(20.dp))
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 16.sp, color = Stow.colors.text)
            Text(subtitle, fontSize = 13.sp, color = Stow.colors.secondaryText)
        }
        trailing?.invoke()
    }
}

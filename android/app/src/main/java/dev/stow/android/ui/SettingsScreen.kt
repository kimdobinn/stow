package dev.stow.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import dev.stow.android.data.DownloadState
import dev.stow.android.data.Repository
import dev.stow.android.sync.YtDlp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@OptIn(ExperimentalMaterial3Api::class)
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

    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Settings") },
            navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") } },
        )
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())) {
            Header("Downloads")
            ListItem(
                headlineContent = { Text("Download on Wi-Fi only") },
                supportingContent = { Text(if (wifiOnly) "Waits for Wi-Fi" else "Also uses mobile data") },
                trailingContent = { Switch(checked = wifiOnly, onCheckedChange = repository::setWifiOnly) },
            )
            ListItem(
                headlineContent = { Text("Storage used") },
                supportingContent = { Text(storage?.let(Format::bytes) ?: "…") },
            )
            ListItem(
                headlineContent = { Text("Delete watched downloads") },
                supportingContent = { Text("Frees space; they stay in the list as deleted") },
                modifier = Modifier.padding(0.dp),
                trailingContent = { TextButton(onClick = { confirmDeleteWatched = true }) { Text("Delete") } },
            )
            HorizontalDivider()
            Header("Downloader")
            ListItem(
                headlineContent = { Text("yt-dlp") },
                supportingContent = { Text(if (updating) "Updating…" else ytdlp ?: "…") },
                trailingContent = {
                    TextButton(enabled = !updating, onClick = {
                        updating = true
                        scope.launch {
                            YtDlp.updateIfDue(context, repository.prefs, force = true)
                            updating = false
                        }
                    }) { Text("Update") }
                },
            )
            HorizontalDivider()
            Header("Mac")
            ListItem(
                headlineContent = { Text("Paired") },
                supportingContent = { Text("Firebase project ${repository.prefs.pairedProject ?: "–"}") },
                trailingContent = { TextButton(onClick = { confirmUnpair = true }) { Text("Unpair") } },
            )
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
private fun Header(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, top = 20.dp, bottom = 4.dp),
    )
}

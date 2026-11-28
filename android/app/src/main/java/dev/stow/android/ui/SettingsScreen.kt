package dev.stow.android.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.border
import dev.stow.android.data.AppTheme
import dev.stow.android.data.DownloadQuality
import androidx.compose.foundation.selection.selectable
import androidx.compose.material.icons.rounded.HighQuality
import androidx.compose.material3.RadioButton
import androidx.compose.material3.RadioButtonDefaults
import androidx.compose.ui.semantics.Role
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
import dev.stow.android.update.Updater
import androidx.compose.material.icons.rounded.SystemUpdate
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.map
import dev.stow.android.standalone.AccountState
import dev.stow.android.standalone.AppMode
import dev.stow.android.standalone.Standalone
import androidx.compose.material.icons.automirrored.rounded.Logout
import androidx.compose.material.icons.rounded.AccountCircle
import androidx.compose.material.icons.rounded.CloudDownload
import androidx.compose.material.icons.rounded.Description
import androidx.compose.material.icons.rounded.Laptop
import androidx.compose.material.icons.rounded.Login
import androidx.compose.material.icons.rounded.PhoneAndroid
import androidx.compose.material.icons.rounded.Subscriptions
import androidx.compose.material.icons.rounded.Sync
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Downloads, the downloader and the pairing, in YouTube's plain settings style. */
@Composable
fun SettingsScreen(repository: Repository, updater: Updater, wifiOnly: Boolean, onReport: () -> Unit, onRemote: () -> Unit, onGroups: () -> Unit,
                   onUpdate: () -> Unit, onBack: () -> Unit,
                   onSignIn: () -> Unit = {}, onManageChannels: () -> Unit = {}, onImport: () -> Unit = {}, notify: (String) -> Unit = {}) {
    val mode by repository.mode.collectAsStateWithLifecycle()
    val standaloneMode = mode == AppMode.STANDALONE
    var confirmStandalone by remember { mutableStateOf(false) }
    var confirmMac by remember { mutableStateOf(false) }
    val groups by repository.groups.collectAsStateWithLifecycle()
    val autoplay by repository.prefs.autoplay.collectAsStateWithLifecycle()
    val calm by repository.prefs.calm.collectAsStateWithLifecycle()
    val grayscale by repository.prefs.grayscale.collectAsStateWithLifecycle()
    val theme by repository.prefs.theme.collectAsStateWithLifecycle()
    val quality by repository.prefs.downloadQuality.collectAsStateWithLifecycle()
    var pickQuality by remember { mutableStateOf(false) }
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
            if (standaloneMode) StandaloneSections(repository, onSignIn, onManageChannels, onImport, notify)
            Section("Appearance") {
                ThemePicker(theme, repository.prefs::setTheme)
            }
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
            Section("Downloads", footer = if (standaloneMode) "Videos download only when you tap the download button."
                                          else "Videos download only when you tap the download button, here or with Send to Phone on the Mac.") {
                SettingRow(Icons.Rounded.Wifi, Blue, "Download on Wi-Fi only", if (wifiOnly) "Waits for Wi-Fi" else "Also uses mobile data",
                           onClick = { repository.setWifiOnly(!wifiOnly) }) {
                    StowSwitch(wifiOnly, repository::setWifiOnly)
                }
                SettingRow(Icons.Rounded.HighQuality, Purple, "Quality",
                           if (quality == DownloadQuality.BEST) "Best available" else "Up to ${quality.label}",
                           onClick = { pickQuality = true }, chevron = true)
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
            Section("About") {
                UpdateRow(updater, onUpdate)
            }
            if (standaloneMode) {
                Section("Mac") {
                    SettingRow(Icons.Rounded.Laptop, Indigo, "Use with my Mac", "Pair with Stow on a Mac instead",
                               onClick = { confirmMac = true }, chevron = true, last = true)
                }
            } else {
                Section("Mac") {
                    SettingRow(Icons.Rounded.Alarm, Indigo, "Alarm remote", "Control the Mac's morning alarm from this phone", onClick = onRemote, chevron = true)
                    SettingRow(Icons.Rounded.PhoneAndroid, Teal, "Use on its own", "This phone follows channels and checks them itself",
                               onClick = { confirmStandalone = true })
                    SettingRow(Icons.Rounded.LinkOff, Red, "Unpair this phone", "Paired with Firebase project ${repository.prefs.pairedProject ?: "–"}",
                               onClick = { confirmUnpair = true }, destructive = true, last = true)
                }
            }
        }
    }

    if (pickQuality) {
        AlertDialog(
            onDismissRequest = { pickQuality = false },
            title = { Text("Download quality") },
            text = {
                Column {
                    Text("The highest a download takes. Videos without it download at the next best. Videos already downloaded stay as they are.",
                         style = StowType.footnote, color = Stow.colors.secondaryText, modifier = Modifier.padding(bottom = 8.dp))
                    DownloadQuality.entries.forEach { option ->
                        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp))
                                .selectable(option == quality, role = Role.RadioButton) {
                                    repository.prefs.setDownloadQuality(option)
                                    pickQuality = false
                                }
                                .padding(vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically) {
                            RadioButton(option == quality, onClick = null, colors = RadioButtonDefaults.colors(selectedColor = Stow.colors.accent),
                                        modifier = Modifier.padding(horizontal = 8.dp))
                            Column {
                                Text(option.label + if (option == DownloadQuality.P1080) " (default)" else "",
                                     style = StowType.body, color = Stow.colors.text)
                                Text(option.detail, style = StowType.footnote, color = Stow.colors.secondaryText)
                            }
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { pickQuality = false }) { Text("Done") } },
        )
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
    if (confirmStandalone) {
        val count = remember { repository.channels.value.size }
        var keep by remember { mutableStateOf(true) }
        AlertDialog(
            onDismissRequest = { confirmStandalone = false },
            title = { Text("Use Stow without your Mac?") },
            text = {
                Column {
                    Text("This phone stops getting videos from the Mac and checks your channels itself. Also remove it on the Mac (Stow › Phone).")
                    Spacer(Modifier.height(12.dp))
                    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).clickable { keep = !keep }.padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        androidx.compose.material3.Checkbox(checked = keep, onCheckedChange = { keep = it })
                        Text("Keep the Mac's ${Format.count(count, "channel")} and groups on this phone", style = StowType.subheadline)
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmStandalone = false
                    repository.switchToStandalone(keep)
                    notify("Stow now works on its own")
                    onBack()
                }) { Text("Use on Its Own") }
            },
            dismissButton = { TextButton(onClick = { confirmStandalone = false }) { Text("Cancel") } },
        )
    }
    if (confirmMac) {
        AlertDialog(
            onDismissRequest = { confirmMac = false },
            title = { Text("Pair with your Mac instead?") },
            text = {
                Text("The Mac's channels replace this phone's while paired. Your channels and groups here are kept for later. " +
                     "You'll be signed out of YouTube on this phone (the Mac's sign-in is used). Downloads, playlists and watched videos stay.")
            },
            confirmButton = { TextButton(onClick = { confirmMac = false; repository.switchToMac() }) { Text("Use with My Mac") } },
            dismissButton = { TextButton(onClick = { confirmMac = false }) { Text("Cancel") } },
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

/** Standalone only: the phone's own YouTube sign-in and channels. */
@Composable
private fun StandaloneSections(repository: Repository, onSignIn: () -> Unit, onManageChannels: () -> Unit, onImport: () -> Unit,
                               notify: (String) -> Unit) {
    val engine = repository.standalone
    val account by engine.account.collectAsStateWithLifecycle()
    val sync by remember { engine.state.map { it.syncWatchedWithYouTube } }.collectAsStateWithLifecycle(true)
    val syncError by engine.watchSyncError.collectAsStateWithLifecycle()
    val status by engine.checkStatus.collectAsStateWithLifecycle()
    var confirmSignOut by remember { mutableStateOf(false) }
    val cookies = rememberCookiesImport(engine, notify)
    val since = account.since.takeIf { it > 0 }?.let { java.text.SimpleDateFormat("d MMM", java.util.Locale.getDefault()).format(java.util.Date(it)) }
    Section("YouTube account") {
        when (account.state) {
            AccountState.SIGNED_OUT -> {
                SettingRow(Icons.Rounded.AccountCircle, Red, "Sign in to YouTube",
                           "Not signed in. Optional: for Home, Subscriptions and members-only videos.", onClick = onSignIn, chevron = true)
                SettingRow(Icons.Rounded.Description, Gray, "Use a cookies.txt file", "From a desktop browser", onClick = cookies.start, last = true)
            }
            AccountState.SIGNED_IN -> {
                SettingRow(Icons.Rounded.AccountCircle, Red, "YouTube",
                           listOfNotNull("Signed in", since?.let { "since $it" }).joinToString(" · ") +
                               if (account.source == Standalone.SOURCE_FILE) " · from a cookies.txt file" else "")
                SettingRow(Icons.Rounded.Sync, Green, "Sync watched with YouTube",
                           syncError?.let { "Couldn't sync: $it" } ?: if (sync) "Watched here shows on YouTube, and back" else "Off",
                           onClick = { engine.setSyncWatched(!sync) }) {
                    StowSwitch(sync, engine::setSyncWatched)
                }
                SettingRow(Icons.Rounded.Description, Gray, "Use a cookies.txt file", "Replaces the sign-in", onClick = cookies.start)
                SettingRow(Icons.AutoMirrored.Rounded.Logout, Red, "Sign out", "Deletes the sign-in from this phone",
                           onClick = { confirmSignOut = true }, destructive = true, last = true)
            }
            AccountState.EXPIRED -> {
                SettingRow(Icons.Rounded.AccountCircle, Red, "YouTube signed you out. Sign in again.",
                           "Home, Subscriptions and members-only videos wait for a new sign-in", destructive = true)
                SettingRow(Icons.Rounded.Login, Blue, "Sign in again", "Google's sign-in page", onClick = onSignIn, chevron = true)
                SettingRow(Icons.Rounded.Description, Gray, "Use a cookies.txt file", "Replaces the sign-in", onClick = cookies.start)
                SettingRow(Icons.AutoMirrored.Rounded.Logout, Red, "Sign out", "Deletes the sign-in from this phone",
                           onClick = { confirmSignOut = true }, destructive = true, last = true)
            }
        }
    }
    val signedIn = account.state == AccountState.SIGNED_IN
    Section("Channels", footer = "Stow checks your channels about every 15 minutes, and when you pull down to refresh.") {
        SettingRow(Icons.Rounded.Subscriptions, Orange, "Your channels (${status.channelCount})", checkStatusText(status),
                   onClick = onManageChannels, chevron = true, last = !signedIn)
        if (signedIn) {
            SettingRow(Icons.Rounded.CloudDownload, Red, "Import from YouTube", "Pick from your subscriptions", onClick = onImport,
                       chevron = true, last = true)
        }
    }
    if (confirmSignOut) {
        AlertDialog(
            onDismissRequest = { confirmSignOut = false },
            title = { Text("Sign out of YouTube?") },
            text = { Text("Home and Subscriptions empty, and members-only videos hide until you sign in again. Downloads stay.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmSignOut = false
                    engine.signOut()
                    notify("Signed out of YouTube")
                }) { Text("Sign Out", color = Red) }
            },
            dismissButton = { TextButton(onClick = { confirmSignOut = false }) { Text("Cancel") } },
        )
    }
}

/** "Checked 4 min ago · 23 channels", or what's wrong. */
private fun checkStatusText(status: Standalone.CheckStatus, now: Long = System.currentTimeMillis()): String {
    val errors = status.channelErrors.size
    return when {
        status.isChecking -> "Checking now…"
        status.failedCheckStreak >= Standalone.FAILING_STREAK && status.lastCheck?.errors?.isNotEmpty() == true ->
            "Checks are failing: ${status.lastCheck.errors.first()}"
        status.backoffUntil > now -> "YouTube asked Stow to slow down. It'll try again later."
        status.channelCount == 0 -> "Add channels to check them for new videos"
        status.lastCheck?.offline == true && status.lastCheck.finishedAt >= status.lastReadAt -> listOf(
            "Couldn't reach YouTube " + Format.ago(java.util.Date(status.lastCheck.finishedAt), now).replaceFirstChar { it.lowercase() },
            Format.count(status.channelCount, "channel"),
        ).joinToString(" · ")
        status.lastReadAt <= 0 -> "Not checked yet"
        else -> listOfNotNull(
            "Checked " + Format.ago(java.util.Date(status.lastReadAt), now).replaceFirstChar { it.lowercase() },
            Format.count(status.channelCount, "channel"),
            (if (errors == 1) "1 channel had errors" else "$errors channels had errors").takeIf { errors > 0 },
        ).joinToString(" · ")
    }
}

/** The app's version and whether there's a newer one (tap: check now, or see the update). */
@Composable
private fun UpdateRow(updater: Updater, onUpdate: () -> Unit) {
    val check by updater.check.collectAsStateWithLifecycle()
    val install by updater.install.collectAsStateWithLifecycle()
    val current = updater.currentVersion
    val downloading = install as? Updater.Install.Downloading
    val (title, subtitle) = when {
        downloading != null -> "Update to ${downloading.release.version}" to
            "Downloading… ${(downloading.bytes * 100 / downloading.release.apkSize.coerceAtLeast(1)).coerceIn(0, 100)}%"
        install is Updater.Install.Installing || install is Updater.Install.Confirm -> "Update to ${install.release?.version}" to "Installing…"
        else -> when (val c = check) {
            is Updater.Check.Available -> "Update to ${c.release.version}" to "You have $current · see what's new"
            Updater.Check.Checking -> "Stow $current" to "Checking for updates…"
            Updater.Check.UpToDate -> "Stow $current" to "Up to date · checks daily by itself"
            Updater.Check.Unknown -> "Stow $current" to "Tap to check for updates"
            is Updater.Check.Failed -> "Stow $current" to "${c.message} Tap to try again."
        }
    }
    val available = check is Updater.Check.Available
    SettingRow(Icons.Rounded.SystemUpdate, Blue, title, subtitle,
               onClick = when {
                   available || install != Updater.Install.Idle -> onUpdate
                   check == Updater.Check.Checking -> null
                   else -> updater::checkInBackground
               },
               chevron = available, last = true) {
        if (available) UpdateDot(Modifier.padding(end = 6.dp))
    }
}

/** The four themes as little phone screens in their colors; tap one to switch. */
@Composable
private fun ThemePicker(selected: AppTheme, onSelect: (AppTheme) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 14.dp)) {
        AppTheme.entries.forEach { theme ->
            val isSelected = theme == selected
            // The picked theme's frame thickens and takes the accent quickly instead of jumping.
            val ringWidth by animateDpAsState(if (isSelected) 2.5.dp else 1.dp, tween(Motion.SHORT), label = "theme-ring")
            val inset by animateDpAsState(if (isSelected) 4.dp else 1.dp, tween(Motion.SHORT), label = "theme-inset")
            val corner by animateDpAsState(if (isSelected) 8.dp else 11.dp, tween(Motion.SHORT), label = "theme-corner")
            val ring by animateColorAsState(if (isSelected) Stow.colors.accent else Stow.colors.divider, tween(Motion.SHORT), label = "theme-color")
            val label by animateColorAsState(if (isSelected) Stow.colors.accent else Stow.colors.text, tween(Motion.SHORT), label = "theme-label")
            Column(Modifier.weight(1f).clip(RoundedCornerShape(12.dp)).clickable { onSelect(theme) }.padding(vertical = 4.dp),
                   horizontalAlignment = Alignment.CenterHorizontally) {
                val shape = RoundedCornerShape(12.dp)
                Box(Modifier.size(width = 62.dp, height = 92.dp)
                        .border(ringWidth, ring, shape)
                        .padding(inset)
                        .clip(RoundedCornerShape(corner))) {
                    if (theme == AppTheme.SYSTEM) {
                        Row(Modifier.fillMaxSize()) {
                            MiniScreen(stowColors(AppTheme.LIGHT, false), Modifier.weight(1f))
                            MiniScreen(stowColors(AppTheme.DARK, true), Modifier.weight(1f))
                        }
                    } else {
                        MiniScreen(stowColors(theme, false), Modifier.fillMaxSize())
                    }
                }
                Spacer(Modifier.height(8.dp))
                Text(theme.label, style = StowType.footnote, fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                     color = label)
            }
        }
    }
}

/** A tiny screen in a theme's colors: a title, a thumbnail, a line of text and an accent dot. */
@Composable
private fun MiniScreen(colors: StowColors, modifier: Modifier) {
    Column(modifier.fillMaxHeight().background(colors.background).padding(7.dp)) {
        Box(Modifier.width(28.dp).height(5.dp).clip(RoundedCornerShape(3.dp)).background(colors.text))
        Spacer(Modifier.height(7.dp))
        Box(Modifier.width(44.dp).height(24.dp).clip(RoundedCornerShape(4.dp)).background(colors.chip))
        Spacer(Modifier.height(5.dp))
        Box(Modifier.width(36.dp).height(4.dp).clip(RoundedCornerShape(2.dp)).background(colors.secondaryText))
        Spacer(Modifier.weight(1f))
        Box(Modifier.width(44.dp).height(10.dp).clip(RoundedCornerShape(5.dp)).background(colors.raised)) {
            Box(Modifier.padding(start = 6.dp).size(6.dp).align(Alignment.CenterStart).clip(RoundedCornerShape(3.dp)).background(colors.accent))
        }
    }
}

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

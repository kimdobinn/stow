package dev.stow.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.PlaylistPlay
import androidx.compose.material.icons.automirrored.filled.Sort
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import dev.stow.android.data.Channel
import dev.stow.android.data.DownloadSort
import dev.stow.android.data.Playlist
import dev.stow.android.data.VideoItem
import dev.stow.android.data.WatchFilter

fun List<VideoItem>.sortedFor(sort: DownloadSort): List<VideoItem> = when (sort) {
    DownloadSort.RECENTLY_DOWNLOADED -> sortedByDescending { it.local?.downloadedAt ?: it.local?.updatedAt ?: 0 }
    DownloadSort.NEWEST -> sortedByDescending { it.video.publishedAt?.time ?: 0 }
    DownloadSort.OLDEST -> sortedBy { it.video.publishedAt?.time ?: Long.MAX_VALUE }
    DownloadSort.CHANNEL -> sortedWith(compareBy<VideoItem> { it.video.channelTitle.lowercase() }.thenByDescending { it.video.publishedAt?.time ?: 0 })
    DownloadSort.LONGEST -> sortedByDescending { it.durationMs }
    DownloadSort.SHORTEST -> sortedBy { it.durationMs }
    DownloadSort.TITLE -> sortedBy { it.video.title.lowercase() }
}

/** Your downloads (sortable, groupable, filterable) and your playlists, like YouTube's You tab. */
@Composable
fun DownloadsScreen(
    all: List<VideoItem>, channels: List<Channel>, playlists: List<Playlist>, byId: Map<String, VideoItem>,
    sort: DownloadSort, groupByChannel: Boolean, storageText: String,
    actions: VideoActions, onSort: (DownloadSort) -> Unit, onGroup: (Boolean) -> Unit,
    onOpenPlaylist: (String) -> Unit, onNewPlaylist: (String) -> Unit, onSearch: () -> Unit, onSettings: () -> Unit,
) {
    var filter by rememberSaveable { mutableStateOf(WatchFilter.ALL) }
    var sortMenu by remember { mutableStateOf(false) }
    var newPlaylist by remember { mutableStateOf(false) }
    val avatars = channels.associate { it.id to it.avatarUrl }
    val downloading = all.filter { it.isDownloading || it.state == dev.stow.android.data.DownloadState.FAILED }
        .sortedByDescending { it.local?.updatedAt ?: 0 }
    val downloaded = all.filter { it.isPlayable }.filter {
        when (filter) {
            WatchFilter.ALL -> true
            WatchFilter.UNWATCHED -> !it.watched
            WatchFilter.WATCHED -> it.watched
        }
    }.sortedFor(sort)

    Column(Modifier.fillMaxSize()) {
        LogoTopBar(onSearch, onSettings)
        LazyColumn(Modifier.fillMaxSize()) {
            item { SectionHeader("Playlists") }
            item {
                LazyRow(contentPadding = PaddingValues(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    item { NewPlaylistCard { newPlaylist = true } }
                    items(playlists, key = { it.id }) { playlist ->
                        PlaylistCard(playlist, playlist.videoIds.firstNotNullOfOrNull { byId[it] }) { onOpenPlaylist(playlist.id) }
                    }
                }
            }
            if (downloading.isNotEmpty()) {
                item { SectionHeader("Downloading · ${downloading.size}") }
                items(downloading, key = { "d-" + it.id }) { VideoRow(it, actions) }
            }
            item {
                SectionHeader("Downloaded · ${all.count { it.isPlayable }}") {
                    Box {
                        TextButton(onClick = { sortMenu = true }) {
                            Icon(Icons.AutoMirrored.Filled.Sort, contentDescription = null, tint = Stow.colors.text, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(sort.label, color = Stow.colors.text, fontSize = 13.sp)
                        }
                        DropdownMenu(expanded = sortMenu, onDismissRequest = { sortMenu = false }) {
                            DownloadSort.entries.forEach { option ->
                                DropdownMenuItem(
                                    text = { Text(option.label) },
                                    trailingIcon = { if (option == sort) Icon(Icons.Filled.Check, contentDescription = null) },
                                    onClick = { sortMenu = false; onSort(option) },
                                )
                            }
                            HorizontalDivider()
                            DropdownMenuItem(
                                text = { Text("Group by channel") },
                                trailingIcon = { Checkbox(checked = groupByChannel, onCheckedChange = null) },
                                onClick = { sortMenu = false; onGroup(!groupByChannel) },
                            )
                        }
                    }
                }
            }
            item {
                ChipRow { WatchFilter.entries.forEach { f -> Chip(f.label, filter == f, onClick = { filter = f }) } }
            }
            if (downloaded.isEmpty()) {
                item { EmptyState(if (all.any { it.isPlayable }) "Nothing matches this filter." else "No downloads yet. Tap any video to download it.") }
            } else if (groupByChannel) {
                downloaded.groupBy { it.video.channelId }.entries
                    .sortedBy { (_, list) -> list.first().video.channelTitle.lowercase() }
                    .forEach { (channelId, list) ->
                        item(key = "g-$channelId") {
                            Row(Modifier.fillMaxWidth().clickable { actions.openChannel(channelId) }.padding(horizontal = 12.dp, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically) {
                                ChannelAvatar(avatars[channelId], 28.dp)
                                Spacer(Modifier.width(10.dp))
                                Text(list.first().video.channelTitle, fontWeight = FontWeight.Bold, fontSize = 15.sp, color = Stow.colors.text,
                                     modifier = Modifier.weight(1f))
                                Text("${list.size}", fontSize = 13.sp, color = Stow.colors.secondaryText)
                            }
                        }
                        items(list, key = { "v-" + it.id }) { VideoRow(it, actions, showChannel = false) }
                    }
            } else {
                items(downloaded, key = { "v-" + it.id }) { VideoRow(it, actions) }
            }
            item {
                Text(storageText, fontSize = 12.sp, color = Stow.colors.secondaryText,
                     modifier = Modifier.fillMaxWidth().padding(16.dp))
            }
        }
    }

    if (newPlaylist) NameDialog("New playlist", "", onDismiss = { newPlaylist = false }) { onNewPlaylist(it); newPlaylist = false }
}

@Composable
private fun NewPlaylistCard(onClick: () -> Unit) {
    Column(Modifier.width(150.dp).clickable(onClick = onClick)) {
        Box(Modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(RoundedCornerShape(10.dp)).background(Stow.colors.chip),
            contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Add, contentDescription = null, tint = Stow.colors.text, modifier = Modifier.size(32.dp))
        }
        Spacer(Modifier.height(6.dp))
        Text("New playlist", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = Stow.colors.text)
    }
}

@Composable
private fun PlaylistCard(playlist: Playlist, cover: VideoItem?, onClick: () -> Unit) {
    Column(Modifier.width(150.dp).clickable(onClick = onClick)) {
        Box(Modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(RoundedCornerShape(10.dp)).background(Stow.colors.chip)) {
            AsyncImage(model = cover?.video?.thumbnailUrl, contentDescription = null, contentScale = ContentScale.Crop,
                       modifier = Modifier.fillMaxSize())
            Row(Modifier.align(Alignment.BottomEnd).padding(6.dp).background(Color.Black.copy(alpha = 0.75f), RoundedCornerShape(4.dp))
                    .padding(horizontal = 5.dp, vertical = 1.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.AutoMirrored.Filled.PlaylistPlay, contentDescription = null, tint = Color.White, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(2.dp))
                Text("${playlist.videoIds.size}", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Medium)
            }
        }
        Spacer(Modifier.height(6.dp))
        Text(playlist.name, fontSize = 13.sp, fontWeight = FontWeight.Medium, color = Stow.colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(Format.count(playlist.videoIds.size, "video"), fontSize = 12.sp, color = Stow.colors.secondaryText)
    }
}

/** One of your playlists: Play all, Shuffle, and its videos in order. */
@Composable
fun PlaylistScreen(
    playlist: Playlist?, videos: List<VideoItem>, actions: VideoActions,
    onPlayAll: (shuffle: Boolean) -> Unit, onRename: (String) -> Unit, onDelete: () -> Unit, onBack: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    var rename by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize()) {
        BackTopBar(playlist?.name.orEmpty(), onBack) {
            Box {
                IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreVert, contentDescription = "More", tint = Stow.colors.text) }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text("Rename") }, onClick = { menu = false; rename = true })
                    DropdownMenuItem(text = { Text("Delete playlist") }, onClick = { menu = false; confirmDelete = true })
                }
            }
        }
        if (playlist == null) {
            EmptyState("This playlist was deleted.")
            return
        }
        val totalMs = videos.sumOf { it.durationMs }
        LazyColumn(Modifier.fillMaxSize()) {
            item {
                Column(Modifier.padding(16.dp)) {
                    videos.firstOrNull()?.let { Thumbnail(it, Modifier.fillMaxWidth(), rounded = 12.dp) }
                    Spacer(Modifier.height(12.dp))
                    Text(playlist.name, fontSize = 24.sp, fontWeight = FontWeight.Bold, color = Stow.colors.text)
                    Text(listOfNotNull(Format.count(videos.size, "video"), totalMs.takeIf { it > 0 }?.let(Format::duration)).joinToString(" · "),
                         fontSize = 13.sp, color = Stow.colors.secondaryText)
                    Spacer(Modifier.height(12.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        PillButton("Play all", Icons.Filled.PlayArrow, onClick = { onPlayAll(false) }, filled = true)
                        PillButton("Shuffle", Icons.Filled.Shuffle, onClick = { onPlayAll(true) })
                    }
                }
            }
            if (videos.isEmpty()) item { EmptyState("Add videos with ⋮ › Save to playlist.") }
            items(videos, key = { it.id }) { VideoRow(it, actions) }
        }
    }
    if (rename && playlist != null) NameDialog("Rename playlist", playlist.name, onDismiss = { rename = false }) { onRename(it); rename = false }
    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete “${playlist?.name}”?") },
            text = { Text("The videos stay downloaded.") },
            confirmButton = { TextButton(onClick = { confirmDelete = false; onDelete() }) { Text("Delete") } },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }
}

@Composable
fun NameDialog(title: String, initial: String, onDismiss: () -> Unit, onDone: (String) -> Unit) {
    var name by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { OutlinedTextField(value = name, onValueChange = { name = it }, singleLine = true, placeholder = { Text("Name") }) },
        confirmButton = { TextButton(enabled = name.isNotBlank(), onClick = { onDone(name) }) { Text("Save") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** "Save video to…": tick playlists, or make a new one. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SaveToPlaylistSheet(
    item: VideoItem, playlists: List<Playlist>,
    onToggle: (Playlist, Boolean) -> Unit, onCreate: (String) -> Unit, onDismiss: () -> Unit,
) {
    var creating by remember { mutableStateOf(false) }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = Stow.colors.raised) {
        Column(Modifier.fillMaxWidth().padding(bottom = 24.dp)) {
            Text("Save video to…", fontSize = 16.sp, fontWeight = FontWeight.Bold, color = Stow.colors.text,
                 modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp))
            playlists.forEach { playlist ->
                val contains = item.id in playlist.videoIds
                Row(Modifier.fillMaxWidth().clickable { onToggle(playlist, !contains) }.padding(horizontal = 12.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = contains, onCheckedChange = { onToggle(playlist, it) })
                    Text(playlist.name, color = Stow.colors.text, fontSize = 15.sp, modifier = Modifier.weight(1f))
                    Text("${playlist.videoIds.size}", color = Stow.colors.secondaryText, fontSize = 13.sp, modifier = Modifier.padding(end = 12.dp))
                }
            }
            HorizontalDivider(Modifier.padding(vertical = 8.dp))
            Row(Modifier.fillMaxWidth().clickable { creating = true }.padding(horizontal = 20.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Add, contentDescription = null, tint = Stow.colors.text)
                Spacer(Modifier.width(16.dp))
                Text("New playlist", color = Stow.colors.text, fontSize = 15.sp, fontWeight = FontWeight.Medium)
            }
            if (!item.isPlayable) {
                Text("Saving it also downloads it.", fontSize = 12.sp, color = Stow.colors.secondaryText,
                     modifier = Modifier.padding(horizontal = 20.dp))
            }
        }
    }
    if (creating) NameDialog("New playlist", "", onDismiss = { creating = false }) { onCreate(it); creating = false }
}


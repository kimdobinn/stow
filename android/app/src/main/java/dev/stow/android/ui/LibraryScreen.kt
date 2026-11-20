package dev.stow.android.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import dev.stow.android.data.DownloadState
import dev.stow.android.data.VideoItem
import dev.stow.android.sync.SyncWorker
import kotlinx.coroutines.delay

/** Downloading first, then ready to watch, then watched. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibraryScreen(
    items: List<VideoItem>,
    onPlay: (VideoItem) -> Unit,
    onSetWatched: (VideoItem, Boolean) -> Unit,
    onDelete: (VideoItem) -> Unit,
    onRetry: (VideoItem) -> Unit,
    onSettings: () -> Unit,
) {
    val context = LocalContext.current
    var refreshing by remember { mutableStateOf(false) }
    LaunchedEffect(refreshing) {
        if (refreshing) {
            SyncWorker.runNow(context)
            delay(1_500)
            refreshing = false
        }
    }
    val visible = items.filter { it.state != DownloadState.DELETED }
    val downloading = visible.filter { it.state != DownloadState.DOWNLOADED }
    val ready = visible.filter { it.state == DownloadState.DOWNLOADED && !it.remote.watched }
    val watched = visible.filter { it.state == DownloadState.DOWNLOADED && it.remote.watched }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Stow", fontWeight = FontWeight.Bold) },
            actions = { IconButton(onClick = onSettings) { Icon(Icons.Filled.Settings, contentDescription = "Settings") } },
        )
    }) { padding ->
        PullToRefreshBox(isRefreshing = refreshing, onRefresh = { refreshing = true }, modifier = Modifier.padding(padding)) {
            if (visible.isEmpty()) {
                Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
                    Text(
                        "Nothing here yet. New videos from channels with Phone on arrive automatically, " +
                            "and you can send any video from the Mac's Inbox.",
                        textAlign = TextAlign.Center,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            } else {
                LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    section("Downloading", downloading, onPlay, onSetWatched, onDelete, onRetry)
                    section("Ready to watch", ready, onPlay, onSetWatched, onDelete, onRetry)
                    section("Watched", watched, onPlay, onSetWatched, onDelete, onRetry)
                }
            }
        }
    }
}

private fun androidx.compose.foundation.lazy.LazyListScope.section(
    title: String,
    items: List<VideoItem>,
    onPlay: (VideoItem) -> Unit,
    onSetWatched: (VideoItem, Boolean) -> Unit,
    onDelete: (VideoItem) -> Unit,
    onRetry: (VideoItem) -> Unit,
) {
    if (items.isEmpty()) return
    item(key = "header-$title") {
        Text(
            "$title · ${items.size}",
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 6.dp),
        )
    }
    items(items, key = { it.id }) { item ->
        VideoRow(item, onPlay, onSetWatched, onDelete, onRetry)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun VideoRow(
    item: VideoItem,
    onPlay: (VideoItem) -> Unit,
    onSetWatched: (VideoItem, Boolean) -> Unit,
    onDelete: (VideoItem) -> Unit,
    onRetry: (VideoItem) -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    val local = item.local
    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .combinedClickable(
                    onClick = {
                        when {
                            item.isPlayable -> onPlay(item)
                            item.state == DownloadState.FAILED -> onRetry(item)
                            else -> menu = true
                        }
                    },
                    onLongClick = { menu = true },
                )
                .padding(horizontal = 16.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Box(Modifier.width(160.dp).aspectRatio(16f / 9f).clip(RoundedCornerShape(10.dp)).background(Color.Black)) {
                AsyncImage(
                    model = item.remote.thumbnailUrl,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize().alpha(if (item.remote.watched) 0.55f else 1f),
                )
                if (local != null && local.durationMs > 0) {
                    Text(
                        Format.duration(local.durationMs),
                        color = Color.White,
                        style = MaterialTheme.typography.labelSmall,
                        modifier = Modifier.align(Alignment.BottomEnd).padding(6.dp)
                            .background(Color.Black.copy(alpha = 0.7f), RoundedCornerShape(4.dp))
                            .padding(horizontal = 4.dp, vertical = 1.dp),
                    )
                }
                // How far you got, YouTube-style (all the way once watched).
                val fraction = when {
                    item.remote.watched -> 1f
                    local != null && local.durationMs > 0 -> (local.positionMs.toFloat() / local.durationMs).coerceIn(0f, 1f)
                    else -> 0f
                }
                if (fraction > 0.01f) {
                    Box(Modifier.align(Alignment.BottomStart).fillMaxWidth(fraction).height(3.dp).background(Color.Red))
                }
            }
            Column(Modifier.weight(1f)) {
                Text(
                    item.remote.title,
                    style = MaterialTheme.typography.titleSmall,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    color = if (item.remote.watched) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
                )
                Spacer(Modifier.height(2.dp))
                Text(
                    listOf(item.remote.channelTitle, Format.ago(item.remote.publishedAt)).filter { it.isNotEmpty() }.joinToString(" · "),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
                Spacer(Modifier.height(6.dp))
                Status(item)
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            if (item.isPlayable) DropdownMenuItem(text = { Text("Play") }, onClick = { menu = false; onPlay(item) })
            DropdownMenuItem(
                text = { Text(if (item.remote.watched) "Mark as unwatched" else "Mark as watched") },
                onClick = { menu = false; onSetWatched(item, !item.remote.watched) },
            )
            if (item.state == DownloadState.FAILED) DropdownMenuItem(text = { Text("Retry download") }, onClick = { menu = false; onRetry(item) })
            DropdownMenuItem(
                text = { Text(if (item.state == DownloadState.DOWNLOADED) "Delete download" else "Cancel download") },
                onClick = { menu = false; onDelete(item) },
            )
        }
    }
}

@Composable
private fun Status(item: VideoItem) {
    val local = item.local
    when (item.state) {
        DownloadState.QUEUED -> Text(
            local?.error?.let { "Waiting to retry · $it" } ?: "Waiting to download",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 2,
        )
        DownloadState.DOWNLOADING -> Column {
            LinearProgressIndicator(progress = { (local?.progress ?: 0) / 100f }, modifier = Modifier.fillMaxWidth())
            Text("Downloading · ${local?.progress ?: 0}%", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
        }
        DownloadState.FAILED -> Text(
            "Failed · tap to retry\n${local?.error.orEmpty()}",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.error,
            maxLines = 3,
        )
        DownloadState.DOWNLOADED -> if (item.remote.isMembersOnly) {
            Text("Members only", style = MaterialTheme.typography.labelMedium, color = Color(0xFF2E9E4F))
        }
        DownloadState.DELETED -> {}
    }
}

package dev.stow.android.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import dev.stow.android.data.DownloadState
import dev.stow.android.data.VideoItem

/** Stow's mark and name, where YouTube's app puts its logo. */
@Composable
fun StowLogo() {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(width = 30.dp, height = 21.dp).clip(RoundedCornerShape(6.dp)).background(StowGradient),
            contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.PlayArrow, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
        }
        Spacer(Modifier.width(4.dp))
        Text("Stow", fontSize = 21.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.8).sp, color = Stow.colors.text)
    }
}

/** The channel's picture, or its initial on a colored circle until (or unless) one loads. */
@Composable
fun ChannelAvatar(url: String?, size: Dp, modifier: Modifier = Modifier, name: String = "") {
    val hue = (name.hashCode() and 0x7fffffff) % 360
    Box(modifier.size(size).clip(CircleShape).background(Color.hsl(hue.toFloat(), 0.45f, 0.5f)), contentAlignment = Alignment.Center) {
        Text(name.firstOrNull()?.uppercase() ?: "", color = Color.White, fontWeight = FontWeight.Medium,
             fontSize = (size.value * 0.42f).sp)
        if (url != null) {
            AsyncImage(model = url, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        }
    }
}

/** A thumbnail with the duration badge and the red "how far you got" bar, like YouTube's. */
@Composable
fun Thumbnail(item: VideoItem, modifier: Modifier = Modifier, rounded: Dp = 0.dp, overlay: @Composable BoxScope.() -> Unit = {}) {
    Box(modifier.aspectRatio(16f / 9f).clip(RoundedCornerShape(rounded)).background(Stow.colors.chip)) {
        AsyncImage(model = item.video.thumbnailUrl, contentDescription = null, contentScale = ContentScale.Crop,
                   modifier = Modifier.fillMaxSize())
        if (item.durationMs > 0) {
            Text(
                Format.duration(item.durationMs),
                color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Medium,
                modifier = Modifier.align(Alignment.BottomEnd).padding(6.dp)
                    .background(Color.Black.copy(alpha = 0.8f), RoundedCornerShape(4.dp))
                    .padding(horizontal = 4.dp, vertical = 1.dp),
            )
        }
        if (item.progress > 0.01f) {
            Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(3.dp).background(Color(0x66FFFFFF)))
            Box(Modifier.align(Alignment.BottomStart).fillMaxWidth(item.progress).height(3.dp).background(ProgressRed))
        }
        overlay()
    }
}

/** What the phone has of a video: downloading %, downloaded, failed. */
@Composable
fun DownloadStatus(item: VideoItem) {
    val local = item.local
    val color = Stow.colors.secondaryText
    when (item.state) {
        DownloadState.DOWNLOADED -> Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = color, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(4.dp))
            Text(listOfNotNull("Downloaded", local?.sizeBytes?.takeIf { it > 0 }?.let(Format::bytes)).joinToString(" · "),
                 fontSize = 12.sp, color = color)
        }
        DownloadState.DOWNLOADING, DownloadState.QUEUED -> Row(verticalAlignment = Alignment.CenterVertically) {
            val percent = local?.progress ?: 0
            if (item.state == DownloadState.DOWNLOADING && percent > 0) {
                CircularProgressIndicator(progress = { percent / 100f }, modifier = Modifier.size(12.dp), strokeWidth = 2.dp,
                                          color = MaterialTheme.colorScheme.primary)
            } else {
                CircularProgressIndicator(modifier = Modifier.size(12.dp), strokeWidth = 2.dp, color = color)
            }
            Spacer(Modifier.width(6.dp))
            Text(
                when {
                    item.state == DownloadState.DOWNLOADING -> "Downloading · $percent%"
                    local?.error != null -> "Retrying soon"
                    else -> "Waiting to download"
                },
                fontSize = 12.sp, color = MaterialTheme.colorScheme.primary,
            )
        }
        DownloadState.FAILED -> Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.ErrorOutline, contentDescription = null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(4.dp))
            Text("Download failed", fontSize = 12.sp, color = MaterialTheme.colorScheme.error, maxLines = 1)
        }
        else -> {}
    }
}

/** What you can do with a video, from its ⋮ menu or a long press. */
data class VideoActions(
    val play: (VideoItem) -> Unit,
    val download: (VideoItem) -> Unit,
    val delete: (VideoItem) -> Unit,
    val setWatched: (VideoItem, Boolean) -> Unit,
    val saveToPlaylist: (VideoItem) -> Unit,
    val openChannel: (String) -> Unit,
    /** A short confirmation at the bottom of the screen, like YouTube's snackbars. */
    val notify: (String) -> Unit = {},
    /** Shown when the list is a playlist. */
    val removeFromPlaylist: ((VideoItem) -> Unit)? = null,
    val move: ((VideoItem, Int) -> Unit)? = null,
)

@Composable
fun VideoMenu(item: VideoItem, actions: VideoActions, expanded: Boolean, onDismiss: () -> Unit) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        fun act(block: () -> Unit) = { onDismiss(); block() }
        if (item.isPlayable) DropdownMenuItem(text = { Text("Play") }, onClick = act { actions.play(item) })
        when {
            item.isPlayable -> {}
            item.isDownloading -> {}
            else -> DropdownMenuItem(text = { Text(if (item.state == DownloadState.FAILED) "Retry download" else "Download") },
                                     onClick = act { actions.download(item) })
        }
        DropdownMenuItem(text = { Text("Save to playlist") }, onClick = act { actions.saveToPlaylist(item) })
        if (item.sent != null) {
            DropdownMenuItem(text = { Text(if (item.watched) "Mark as unwatched" else "Mark as watched") },
                             onClick = act { actions.setWatched(item, !item.watched) })
        }
        DropdownMenuItem(text = { Text("Go to channel") }, onClick = act { actions.openChannel(item.video.channelId) })
        actions.move?.let { move ->
            DropdownMenuItem(text = { Text("Move up") }, onClick = act { move(item, -1) })
            DropdownMenuItem(text = { Text("Move down") }, onClick = act { move(item, 1) })
        }
        actions.removeFromPlaylist?.let { remove ->
            DropdownMenuItem(text = { Text("Remove from playlist") }, onClick = act { remove(item) })
        }
        if (item.isPlayable || item.isDownloading) {
            DropdownMenuItem(text = { Text(if (item.isPlayable) "Delete from downloads" else "Cancel download") },
                             onClick = act { actions.delete(item) })
        }
    }
}

/** Tapping a video plays it when downloaded, otherwise starts the download. */
fun VideoActions.open(item: VideoItem) {
    when {
        item.isPlayable -> play(item)
        item.state == DownloadState.DOWNLOADING -> notify("Still downloading · ${item.local?.progress ?: 0}%")
        item.isDownloading -> notify("Waiting to download")
        else -> download(item)
    }
}

/** Home and Subscriptions: a full-width thumbnail with the channel avatar and title below. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun VideoCard(item: VideoItem, avatarUrl: String?, actions: VideoActions) {
    var menu by remember { mutableStateOf(false) }
    val haptics = androidx.compose.ui.platform.LocalHapticFeedback.current
    Column(Modifier.fillMaxWidth().combinedClickable(onClick = { actions.open(item) }, onLongClick = {
        haptics.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.LongPress)
        menu = true
    })) {
        Thumbnail(item, Modifier.fillMaxWidth()) {
            if (!item.isPlayable && !item.isDownloading) {
                DownloadBadge(Modifier.align(Alignment.TopEnd).padding(8.dp))
            }
        }
        Row(Modifier.padding(start = 12.dp, top = 12.dp, bottom = 20.dp)) {
            ChannelAvatar(avatarUrl, 36.dp, Modifier.clickable { actions.openChannel(item.video.channelId) }, name = item.video.channelTitle)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(item.video.title, fontSize = 15.sp, fontWeight = FontWeight.Medium, maxLines = 2,
                     overflow = TextOverflow.Ellipsis, color = Stow.colors.text, lineHeight = 20.sp)
                Spacer(Modifier.height(3.dp))
                Text(Format.meta(item), fontSize = 12.sp, color = Stow.colors.secondaryText, maxLines = 1)
                Spacer(Modifier.height(3.dp))
                DownloadStatus(item)
            }
            Box {
                IconButton(onClick = { menu = true }) {
                    Icon(Icons.Filled.MoreVert, contentDescription = "More", tint = Stow.colors.text, modifier = Modifier.size(20.dp))
                }
                VideoMenu(item, actions, menu) { menu = false }
            }
        }
    }
}

/** Downloads, channel pages, playlists: thumbnail on the left, text on the right. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun VideoRow(item: VideoItem, actions: VideoActions, showChannel: Boolean = true, trailing: (@Composable () -> Unit)? = null) {
    var menu by remember { mutableStateOf(false) }
    val haptics = androidx.compose.ui.platform.LocalHapticFeedback.current
    Row(
        Modifier.fillMaxWidth().combinedClickable(onClick = { actions.open(item) }, onLongClick = {
            haptics.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.LongPress)
            menu = true
        })
            .padding(start = 12.dp, top = 6.dp, bottom = 6.dp),
    ) {
        Thumbnail(item, Modifier.width(168.dp), rounded = 8.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f).padding(top = 2.dp)) {
            Text(item.video.title, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 2,
                 overflow = TextOverflow.Ellipsis, color = Stow.colors.text, lineHeight = 19.sp)
            Spacer(Modifier.height(3.dp))
            Text(if (showChannel) Format.meta(item) else Format.ago(item.video.publishedAt),
                 fontSize = 12.sp, color = Stow.colors.secondaryText, maxLines = 2)
            Spacer(Modifier.height(3.dp))
            DownloadStatus(item)
        }
        if (trailing != null) trailing()
        Box {
            IconButton(onClick = { menu = true }) {
                Icon(Icons.Filled.MoreVert, contentDescription = "More", tint = Stow.colors.text, modifier = Modifier.size(20.dp))
            }
            VideoMenu(item, actions, menu) { menu = false }
        }
    }
}

@Composable
private fun DownloadBadge(modifier: Modifier) {
    Box(modifier.background(Color.Black.copy(alpha = 0.7f), CircleShape).padding(5.dp)) {
        Icon(Icons.Outlined.Download, contentDescription = "Not downloaded", tint = Color.White, modifier = Modifier.size(16.dp))
    }
}

/** A YouTube filter chip. */
@Composable
fun Chip(label: String, selected: Boolean, onClick: () -> Unit, leading: (@Composable () -> Unit)? = null) {
    val colors = Stow.colors
    Row(
        Modifier.clip(RoundedCornerShape(8.dp)).background(if (selected) colors.chipSelected else colors.chip)
            .clickable(onClick = onClick).padding(horizontal = 12.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        leading?.let { it(); Spacer(Modifier.width(6.dp)) }
        Text(label, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = if (selected) colors.chipSelectedText else colors.text, maxLines = 1)
    }
}

@Composable
fun ChipRow(content: @Composable () -> Unit) {
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) { content() }
}

/** A rounded grey action button, like YouTube's Like/Share/Save row. */
@Composable
fun PillButton(label: String, icon: androidx.compose.ui.graphics.vector.ImageVector?, onClick: () -> Unit, filled: Boolean = false) {
    val colors = Stow.colors
    Row(
        Modifier.clip(RoundedCornerShape(50)).background(if (filled) colors.chipSelected else colors.chip)
            .clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, tint = if (filled) colors.chipSelectedText else colors.text, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
        }
        Text(label, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = if (filled) colors.chipSelectedText else colors.text)
    }
}

@Composable
fun SectionHeader(text: String, modifier: Modifier = Modifier, trailing: (@Composable () -> Unit)? = null) {
    Row(modifier.fillMaxWidth().padding(start = 12.dp, end = 4.dp, top = 16.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(text, fontSize = 20.sp, fontWeight = FontWeight.Bold, color = Stow.colors.text, modifier = Modifier.weight(1f))
        trailing?.invoke()
    }
}

@Composable
fun EmptyState(text: String, padding: PaddingValues = PaddingValues(32.dp)) {
    Box(Modifier.fillMaxWidth().padding(padding), contentAlignment = Alignment.Center) {
        Text(text, color = Stow.colors.secondaryText, fontSize = 14.sp, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
    }
}

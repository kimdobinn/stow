package dev.stow.android.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material.icons.rounded.ArrowDownward
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
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
import androidx.compose.foundation.lazy.LazyListScope
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

/** A thumbnail with the duration badge and the accent "how far you got" bar. */
@Composable
fun Thumbnail(item: VideoItem, modifier: Modifier = Modifier, rounded: Dp = 0.dp, overlay: @Composable BoxScope.() -> Unit = {}) {
    Box(modifier.aspectRatio(16f / 9f).clip(RoundedCornerShape(rounded)).background(Stow.colors.chip)) {
        AsyncImage(model = item.video.thumbnailUrl, contentDescription = null, contentScale = ContentScale.Crop,
                   modifier = Modifier.fillMaxSize())
        if (item.durationMs > 0) {
            Text(
                Format.duration(item.durationMs),
                color = Color.White, style = StowType.caption, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.align(Alignment.BottomEnd).padding(8.dp)
                    .background(Color.Black.copy(alpha = 0.72f), RoundedCornerShape(6.dp))
                    .padding(horizontal = 6.dp, vertical = 2.dp),
            )
        }
        if (item.progress > 0.01f) {
            Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(4.dp).background(Color(0x59FFFFFF)))
            Box(Modifier.align(Alignment.BottomStart).fillMaxWidth(item.progress).height(4.dp).background(Stow.colors.accent))
        }
        overlay()
    }
}

/**
 * Stow's download control: one disc that tells the whole story. An arrow to stow the video on the
 * phone; a ring in the app icon's colors while it downloads (tap to stop); a filled disc with a
 * check once it's here. `onMedia` draws it dimmed for sitting on a thumbnail.
 */
@Composable
fun DownloadDisc(item: VideoItem, actions: VideoActions, modifier: Modifier = Modifier, onMedia: Boolean = true, size: Dp = 40.dp) {
    val colors = Stow.colors
    val state = when {
        item.isPlayable -> DiscState.DONE
        item.isDownloading -> DiscState.LOADING
        item.state == DownloadState.FAILED -> DiscState.FAILED
        else -> DiscState.IDLE
    }
    val face = if (onMedia) Color.White else colors.text
    val label = when (state) {
        DiscState.IDLE -> "Download"
        DiscState.LOADING -> "Stop download"
        DiscState.FAILED -> "Retry download"
        DiscState.DONE -> "Downloaded"
    }
    val click: (() -> Unit)? = when (state) {
        DiscState.IDLE, DiscState.FAILED -> ({ actions.download(item) })
        DiscState.LOADING -> ({ actions.delete(item) })
        DiscState.DONE -> null
    }
    // 48 dp to touch, whatever the disc's drawn size.
    Box(modifier.size(maxOf(size, 48.dp)).then(
            if (click != null) Modifier.clip(CircleShape).clickable(onClickLabel = label, role = Role.Button, onClick = click) else Modifier
        ).semantics { contentDescription = label },
        contentAlignment = Alignment.Center) {
        AnimatedContent(state, transitionSpec = {
            (fadeIn(tween(180)) + scaleIn(tween(220), initialScale = 0.7f)) togetherWith fadeOut(tween(120))
        }, label = "disc") { shown ->
            val discSize = if (shown == DiscState.DONE) size * 0.78f else size
            Box(
                Modifier.size(discSize).clip(CircleShape).then(
                    when {
                        shown == DiscState.DONE -> Modifier.background(StowGradient)
                        onMedia -> Modifier.background(Color.Black.copy(alpha = 0.45f)).border(1.dp, Color.White.copy(alpha = 0.28f), CircleShape)
                        else -> Modifier.background(colors.chip)
                    }
                ),
                contentAlignment = Alignment.Center,
            ) {
                when (shown) {
                    DiscState.IDLE -> Icon(Icons.Rounded.ArrowDownward, contentDescription = null, tint = face, modifier = Modifier.size(size * 0.5f))
                    DiscState.FAILED -> Icon(Icons.Rounded.Refresh, contentDescription = null, tint = face, modifier = Modifier.size(size * 0.5f))
                    DiscState.DONE -> Icon(Icons.Rounded.Check, contentDescription = null, tint = Color.White, modifier = Modifier.size(size * 0.46f))
                    DiscState.LOADING -> {
                        val percent = item.local?.progress ?: 0
                        DownloadRing(if (item.state == DownloadState.DOWNLOADING && percent > 0) percent / 100f else null,
                                     track = face.copy(alpha = 0.25f), modifier = Modifier.fillMaxSize().padding(3.dp))
                        Box(Modifier.size(size * 0.24f).clip(RoundedCornerShape(2.dp)).background(face))
                    }
                }
            }
        }
    }
}

private enum class DiscState { IDLE, LOADING, FAILED, DONE }

/** The ring around the stop square: how much is down, or a turning arc while it waits to start. */
@Composable
private fun DownloadRing(fraction: Float?, track: Color, modifier: Modifier) {
    val shown by animateFloatAsState(fraction ?: 0f, tween(400), label = "ring")
    val turn = if (fraction == null) {
        val spin = rememberInfiniteTransition(label = "wait")
        spin.animateFloat(0f, 360f, infiniteRepeatable(tween(1100, easing = LinearEasing)), label = "spin").value
    } else 0f
    val brush = Brush.sweepGradient(StowGradientColors)
    Canvas(modifier) {
        val stroke = Stroke(width = 3.dp.toPx(), cap = StrokeCap.Round)
        drawArc(track, 0f, 360f, useCenter = false, style = stroke)
        if (fraction == null) {
            rotate(turn) { drawArc(brush, 0f, 100f, useCenter = false, style = stroke) }
        } else if (shown > 0f) {
            rotate(-90f) { drawArc(brush, 0f, 360f * shown, useCenter = false, style = stroke) }
        }
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
                 style = StowType.caption, color = color)
        }
        DownloadState.DOWNLOADING, DownloadState.QUEUED -> Row(verticalAlignment = Alignment.CenterVertically) {
            val percent = local?.progress ?: 0
            if (item.state == DownloadState.DOWNLOADING && percent > 0) {
                CircularProgressIndicator(progress = { percent / 100f }, modifier = Modifier.size(12.dp), strokeWidth = 2.dp,
                                          color = Stow.colors.accent, trackColor = Stow.colors.chip)
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
                style = StowType.caption, fontWeight = FontWeight.Medium, color = Stow.colors.accent,
            )
        }
        DownloadState.FAILED -> Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.ErrorOutline, contentDescription = null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(4.dp))
            Text("Download failed", style = StowType.caption, color = MaterialTheme.colorScheme.error, maxLines = 1)
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
    /** Puts the video's channel in your channel groups. */
    val addToGroup: ((VideoItem) -> Unit)? = null,
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
        actions.addToGroup?.let { add ->
            if (item.video.channelId.isNotEmpty()) DropdownMenuItem(text = { Text("Add channel to a group") }, onClick = act { add(item) })
        }
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

/** Tapping a video plays it: from the phone when downloaded, otherwise streamed. */
fun VideoActions.open(item: VideoItem) = play(item)

/** Home and Subscriptions: a rounded thumbnail with the download disc, the channel and title below. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun VideoCard(item: VideoItem, avatarUrl: String?, actions: VideoActions) {
    var menu by remember { mutableStateOf(false) }
    val haptics = androidx.compose.ui.platform.LocalHapticFeedback.current
    Column(Modifier.fillMaxWidth().combinedClickable(onClick = { actions.open(item) }, onLongClick = {
        haptics.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.LongPress)
        menu = true
    }).padding(horizontal = 16.dp)) {
        val calm = LocalCalm.current
        if (!calm) {
            Thumbnail(item, Modifier.fillMaxWidth().padding(top = 8.dp), rounded = 14.dp) {
                DownloadDisc(item, actions, Modifier.align(Alignment.TopEnd).padding(4.dp))
            }
        }
        Row(Modifier.padding(top = 12.dp, bottom = if (calm) 12.dp else 20.dp)) {
            ChannelAvatar(avatarUrl, 36.dp, Modifier.clickable(onClickLabel = "Go to channel") { actions.openChannel(item.video.channelId) },
                          name = item.video.channelTitle)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(item.video.title, style = StowType.headline, fontSize = 16.sp, lineHeight = 21.sp, maxLines = 2,
                     overflow = TextOverflow.Ellipsis, color = Stow.colors.text)
                Spacer(Modifier.height(3.dp))
                Text(Format.meta(item, withDuration = calm), style = StowType.footnote, color = Stow.colors.secondaryText, maxLines = 1)
                if (item.isDownloading || item.state == DownloadState.FAILED) {
                    Spacer(Modifier.height(3.dp))
                    DownloadStatus(item)
                }
                if (calm && item.progress > 0.01f) WatchedLine(item.progress)
            }
            if (calm) DownloadDisc(item, actions, onMedia = false, size = 34.dp)
            Box {
                MoreButton { menu = true }
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
            .padding(start = 16.dp, end = 4.dp, top = 8.dp, bottom = 8.dp),
    ) {
        val calm = LocalCalm.current
        if (!calm) {
            Thumbnail(item, Modifier.width(156.dp), rounded = 10.dp)
            Spacer(Modifier.width(12.dp))
        }
        Column(Modifier.weight(1f).padding(top = 1.dp)) {
            Text(item.video.title, style = StowType.subheadline, fontWeight = FontWeight.SemiBold, maxLines = 2,
                 overflow = TextOverflow.Ellipsis, color = Stow.colors.text)
            Spacer(Modifier.height(3.dp))
            Text(if (showChannel) Format.meta(item, withDuration = calm)
                 else listOfNotNull(Format.whenText(item).ifEmpty { null }, item.durationMs.takeIf { calm && it > 0 }?.let(Format::duration)).joinToString(" · "),
                 style = StowType.footnote, color = Stow.colors.secondaryText, maxLines = 2)
            Spacer(Modifier.height(3.dp))
            DownloadStatus(item)
            if (calm && item.progress > 0.01f) WatchedLine(item.progress)
        }
        if (trailing != null) trailing()
        if (!item.isPlayable) DownloadDisc(item, actions, onMedia = false, size = 34.dp)
        Box {
            MoreButton { menu = true }
            VideoMenu(item, actions, menu) { menu = false }
        }
    }
}

/** "⋯", like iOS's More buttons. */
@Composable
private fun MoreButton(onClick: () -> Unit) {
    IconButton(onClick = onClick) {
        Icon(Icons.Rounded.MoreHoriz, contentDescription = "More", tint = Stow.colors.secondaryText, modifier = Modifier.size(22.dp))
    }
}

/** In calm mode, how far you got shows as a thin line under the text. */
@Composable
private fun WatchedLine(fraction: Float) {
    Box(Modifier.padding(top = 6.dp).width(120.dp).height(3.dp).background(Stow.colors.chip)) {
        Box(Modifier.fillMaxWidth(fraction).height(3.dp).background(Stow.colors.accent))
    }
}

/** A filter token: a capsule, filled with the text color when selected (no accent, so content leads). */
@Composable
@OptIn(ExperimentalFoundationApi::class)
fun Chip(label: String, selected: Boolean, onClick: () -> Unit, leading: (@Composable () -> Unit)? = null,
         onLongClick: (() -> Unit)? = null) {
    val colors = Stow.colors
    Row(
        Modifier.heightIn(min = 36.dp).clip(CircleShape).background(if (selected) colors.chipSelected else colors.chip)
            .combinedClickable(role = Role.Tab, onClick = onClick, onLongClick = onLongClick).padding(horizontal = 14.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        leading?.let { it(); if (label.isNotEmpty()) Spacer(Modifier.width(6.dp)) }
        if (label.isNotEmpty()) {
            Text(label, style = StowType.subheadline, fontWeight = FontWeight.SemiBold,
                 color = if (selected) colors.chipSelectedText else colors.text, maxLines = 1)
        }
    }
}

@Composable
fun ChipRow(content: @Composable () -> Unit) {
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) { content() }
}

/** An iOS-style switch: green when on. */
@Composable
fun StowSwitch(checked: Boolean, onChange: (Boolean) -> Unit) {
    androidx.compose.material3.Switch(
        checked = checked, onCheckedChange = onChange,
        colors = androidx.compose.material3.SwitchDefaults.colors(
            checkedTrackColor = Color(0xFF34C759), checkedThumbColor = Color.White, checkedBorderColor = Color.Transparent,
            uncheckedTrackColor = Stow.colors.divider, uncheckedThumbColor = Color.White, uncheckedBorderColor = Color.Transparent,
        ),
        thumbContent = null,
    )
}

/** A capsule button; `filled` is the screen's one primary action, in the accent. */
@Composable
fun PillButton(label: String, icon: androidx.compose.ui.graphics.vector.ImageVector?, onClick: () -> Unit, filled: Boolean = false) {
    val colors = Stow.colors
    val content = if (filled) Color.White else colors.text
    Row(
        Modifier.heightIn(min = 40.dp).clip(CircleShape).background(if (filled) colors.accent else colors.chip)
            .clickable(role = Role.Button, onClick = onClick).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, tint = content, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
        }
        Text(label, style = StowType.subheadline, fontWeight = FontWeight.SemiBold, color = content, maxLines = 1)
    }
}

@Composable
fun SectionHeader(text: String, modifier: Modifier = Modifier, trailing: (@Composable () -> Unit)? = null) {
    Row(modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp, top = 20.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(text, style = StowType.title3, fontWeight = FontWeight.Bold, color = Stow.colors.text, modifier = Modifier.weight(1f))
        trailing?.invoke()
    }
}

@Composable
fun EmptyState(text: String, padding: PaddingValues = PaddingValues(32.dp)) {
    Box(Modifier.fillMaxWidth().padding(padding), contentAlignment = Alignment.Center) {
        Text(text, color = Stow.colors.secondaryText, style = StowType.subheadline, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
    }
}

/**
 * A fixed first row, so a list stays at the top while its videos arrive: a list keeps its first
 * visible row on screen, and without this the videos loading in land above it (as when only
 * "You're caught up" was there at first) and have to be scrolled up to.
 */
fun LazyListScope.topAnchor() {
    item(key = "top-anchor", contentType = "top-anchor") { Spacer(Modifier.fillMaxWidth().height(1.dp)) }
}

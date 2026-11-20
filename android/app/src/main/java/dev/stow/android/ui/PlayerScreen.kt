package dev.stow.android.ui

import android.app.Activity
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.view.ViewGroup
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.PlaylistAdd
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.FullscreenExit
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Speed
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.media3.common.Player
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import coil3.compose.AsyncImage
import dev.stow.android.data.Channel
import dev.stow.android.data.VideoItem
import dev.stow.android.player.PlayerConnection
import kotlinx.coroutines.delay
import kotlin.math.roundToInt

/** Each double-tap skips this far; taps in a row add up (5, 10, 15 s). */
private const val SKIP_MS = 5_000L

private val Speeds = listOf(0.25f, 0.5f, 0.75f, 1f, 1.25f, 1.5f, 1.75f, 2f)

/**
 * The watch page: the video with YouTube-style controls (tap for controls, double-tap a side
 * to skip 5 s, red seek bar, full screen), the title and actions, then Up next.
 */
@Composable
fun PlayerScreen(
    connection: PlayerConnection,
    current: VideoItem?,
    upNext: List<VideoItem>,
    channel: Channel?,
    actions: VideoActions,
    onCollapse: () -> Unit,
    onAutoDownload: (String, Boolean) -> Unit,
) {
    val context = LocalContext.current
    val activity = context as? Activity
    val landscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
    val controller by connection.controller.collectAsStateCompat()
    var speedDialog by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }

    // Full screen when sideways: hide the status and navigation bars.
    DisposableEffect(landscape) {
        val window = activity?.window
        if (window != null) {
            val insets = WindowCompat.getInsetsController(window, window.decorView)
            if (landscape) {
                insets.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                insets.hide(WindowInsetsCompat.Type.systemBars())
            } else {
                insets.show(WindowInsetsCompat.Type.systemBars())
            }
        }
        onDispose { window?.let { WindowCompat.getInsetsController(it, it.decorView).show(WindowInsetsCompat.Type.systemBars()) } }
    }
    // Leaving the watch page gives rotation back to the phone.
    DisposableEffect(Unit) { onDispose { activity?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED } }

    fun setFullscreen(on: Boolean) {
        activity?.requestedOrientation =
            if (on) ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE else ActivityInfo.SCREEN_ORIENTATION_USER_PORTRAIT
    }
    BackHandler { if (landscape) setFullscreen(false) else onCollapse() }

    val player = controller
    val resolving = connection.resolving.collectAsStateCompat().value
    val streamError = connection.error.collectAsStateCompat().value
    val queue = connection.queue.collectAsStateCompat().value
    val index = queue.indexOf(current?.id)
    var dragDown by remember { mutableFloatStateOf(0f) }
    val video: @Composable (Modifier) -> Unit = { modifier ->
        Box(modifier.background(Color.Black)
            // Swipe the video down to shrink it into the mini-player, like YouTube.
            .then(if (landscape) Modifier else Modifier.pointerInput(Unit) {
                detectVerticalDragGestures(
                    onDragEnd = { if (dragDown > 120.dp.toPx()) onCollapse(); dragDown = 0f },
                    onDragCancel = { dragDown = 0f },
                    onVerticalDrag = { _, amount -> dragDown = (dragDown + amount).coerceAtLeast(0f) },
                )
            })
            .offset { IntOffset(0, (dragDown * 0.5f).roundToInt()) }) {
            AndroidView(
                factory = { ctx ->
                    PlayerView(ctx).apply {
                        layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                        useController = false
                        resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                        keepScreenOn = true
                        setShutterBackgroundColor(android.graphics.Color.BLACK)
                    }
                },
                update = { it.player = player },
                modifier = Modifier.fillMaxSize(),
            )
            if (player != null && resolving == null && streamError == null) {
                PlayerControls(
                    player = player,
                    fullscreen = landscape,
                    hasPrevious = index > 0,
                    hasNext = index in 0 until queue.lastIndex,
                    nextTitle = upNext.firstOrNull()?.video?.title,
                    onDone = { connection.stop(); onCollapse() },
                    onFullscreen = { setFullscreen(!landscape) },
                    onCollapse = { if (landscape) setFullscreen(false) else onCollapse() },
                    onSettings = { speedDialog = true },
                )
            }
            when {
                streamError != null -> Column(Modifier.align(Alignment.Center).padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(streamError, color = Color.White, fontSize = 13.sp, maxLines = 4, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                    Spacer(Modifier.height(12.dp))
                    if (current != null) PillButton("Try again", null, onClick = { connection.play(listOf(current), current) })
                }
                resolving != null -> Column(Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
                    androidx.compose.material3.CircularProgressIndicator(Modifier.size(40.dp), color = Color.White, strokeWidth = 3.dp)
                    Spacer(Modifier.height(10.dp))
                    Text("Getting the video from YouTube…", color = Color.White.copy(alpha = 0.8f), fontSize = 12.sp)
                }
            }
            if (resolving != null || streamError != null) {
                IconButton(onClick = onCollapse, modifier = Modifier.align(Alignment.TopStart).padding(4.dp)) {
                    Icon(Icons.Filled.KeyboardArrowDown, contentDescription = "Minimize", tint = Color.White)
                }
            }
        }
    }

    if (landscape) {
        video(Modifier.fillMaxSize())
    } else {
        Column(Modifier.fillMaxSize().background(Stow.colors.background)) {
            Spacer(Modifier.statusBarsPadding())
            video(Modifier.fillMaxWidth().aspectRatio(16f / 9f))
            if (current == null) return@Column
            LazyColumn(Modifier.fillMaxSize().navigationBarsPadding()) {
                item {
                    Column(Modifier.padding(horizontal = 12.dp, vertical = 12.dp)) {
                        Text(current.video.title, fontSize = 18.sp, fontWeight = FontWeight.Bold, color = Stow.colors.text, lineHeight = 24.sp)
                        Spacer(Modifier.height(4.dp))
                        Text(listOf(Format.ago(current.video.publishedAt),
                                    current.durationMs.takeIf { it > 0 }?.let(Format::duration) ?: "",
                                    if (current.video.isMembersOnly) "Members only" else "")
                                 .filter { it.isNotEmpty() }.joinToString(" · "),
                             fontSize = 12.sp, color = Stow.colors.secondaryText)
                    }
                    Row(Modifier.fillMaxWidth().clickable { actions.openChannel(current.video.channelId) }
                            .padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        ChannelAvatar(channel?.avatarUrl, 36.dp, name = current.video.channelTitle)
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(current.video.channelTitle, fontSize = 15.sp, fontWeight = FontWeight.Medium, color = Stow.colors.text, maxLines = 1)
                            channel?.let {
                                Text(Format.count(it.recent.size, "recent video"), fontSize = 12.sp, color = Stow.colors.secondaryText)
                            }
                        }
                        // Where YouTube puts Subscribe.
                        if (channel != null) {
                            if (channel.autoDownload) {
                                PillButton("Auto-downloading", Icons.Filled.Check, onClick = { onAutoDownload(channel.id, false) })
                            } else {
                                PillButton("Auto-download", null, onClick = { onAutoDownload(channel.id, true) }, filled = true)
                            }
                        }
                    }
                    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 8.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        PillButton(if (current.watched) "Watched" else "Mark watched", if (current.watched) Icons.Filled.Check else null,
                                   onClick = { actions.setWatched(current, !current.watched) })
                        when {
                            current.isPlayable -> {}
                            current.isDownloading -> PillButton("Downloading ${current.local?.progress ?: 0}%", Icons.Outlined.Download, onClick = {})
                            else -> PillButton("Download", Icons.Outlined.Download, onClick = { actions.download(current) })
                        }
                        PillButton("Save", Icons.AutoMirrored.Outlined.PlaylistAdd, onClick = { actions.saveToPlaylist(current) })
                        PillButton("Speed", Icons.Outlined.Speed, onClick = { speedDialog = true })
                        if (current.isPlayable) PillButton("Delete", Icons.Outlined.Delete, onClick = { confirmDelete = true })
                    }
                }
                if (upNext.isNotEmpty()) {
                    item { SectionHeader("Up next") }
                    items(upNext, key = { "n-" + it.id }) { VideoRow(it, actions) }
                }
            }
        }
    }

    if (speedDialog) {
        val currentSpeed = player?.playbackParameters?.speed ?: 1f
        AlertDialog(
            onDismissRequest = { speedDialog = false },
            title = { Text("Playback speed") },
            text = {
                Column {
                    Speeds.forEach { speed ->
                        Row(Modifier.fillMaxWidth().clickable { connection.setSpeed(speed); speedDialog = false }.padding(vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.width(28.dp)) { if (speed == currentSpeed) Icon(Icons.Filled.Check, contentDescription = null) }
                            Text(if (speed == 1f) "Normal" else "${speed}x".replace(".0x", "x"), fontSize = 15.sp)
                        }
                    }
                }
            },
            confirmButton = {},
        )
    }
    if (confirmDelete && current != null) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete from downloads?") },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    connection.stop()
                    actions.delete(current)
                    onCollapse()
                }) { Text("Delete") }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }
}

/** Tap to show/hide; double-tap left/right to skip 5 s (more taps add up); drag the red bar to seek. */
@Composable
private fun PlayerControls(
    player: Player,
    fullscreen: Boolean,
    hasPrevious: Boolean,
    hasNext: Boolean,
    nextTitle: String?,
    onDone: () -> Unit,
    onFullscreen: () -> Unit,
    onCollapse: () -> Unit,
    onSettings: () -> Unit,
) {
    var visible by remember { mutableStateOf(true) }
    var position by remember { mutableLongStateOf(0L) }
    var duration by remember { mutableLongStateOf(0L) }
    var buffered by remember { mutableLongStateOf(0L) }
    var playing by remember { mutableStateOf(player.isPlaying) }
    var scrubbing by remember { mutableStateOf<Float?>(null) }
    // A run of double-taps on one side: which side, how many seconds, when the last one was.
    var skip by remember { mutableStateOf<Triple<Boolean, Int, Long>?>(null) }
    var buffering by remember { mutableStateOf(false) }
    var ended by remember { mutableStateOf(false) }
    var lastTouch by remember { mutableLongStateOf(System.currentTimeMillis()) }

    LaunchedEffect(player) {
        while (true) {
            position = player.currentPosition
            duration = player.duration.coerceAtLeast(0)
            buffered = player.bufferedPosition
            playing = player.isPlaying || (player.playWhenReady && player.playbackState == Player.STATE_BUFFERING)
            buffering = player.playWhenReady && player.playbackState == Player.STATE_BUFFERING
            // With autoplay off the player pauses at the end of each video instead of moving on.
            ended = player.playbackState == Player.STATE_ENDED ||
                (duration > 0 && !player.playWhenReady && position >= duration - 600)
            if (visible && playing && scrubbing == null && System.currentTimeMillis() - lastTouch > 3_000) visible = false
            skip?.let { if (System.currentTimeMillis() - it.third > 800) skip = null }
            delay(200)
        }
    }

    BoxWithConstraints(Modifier.fillMaxSize().pointerInput(player) {
        detectTapGestures(
            onTap = { visible = !visible; lastTouch = System.currentTimeMillis() },
            onDoubleTap = { offset ->
                val forward = offset.x > size.width / 2
                player.seekTo((player.currentPosition + if (forward) SKIP_MS else -SKIP_MS).coerceIn(0, player.duration.coerceAtLeast(0)))
                val now = System.currentTimeMillis()
                val previous = skip?.takeIf { it.first == forward && now - it.third < 800 }
                skip = Triple(forward, (previous?.second ?: 0) + (SKIP_MS / 1000).toInt(), now)
                lastTouch = now
            },
        )
    }) {
        val width = constraints.maxWidth.toFloat()
        skip?.let { (forward, seconds, _) ->
            // YouTube's half-moon on the tapped side, with arrows and the running total.
            val shape = if (forward) androidx.compose.foundation.shape.RoundedCornerShape(topStartPercent = 50, bottomStartPercent = 50)
                        else androidx.compose.foundation.shape.RoundedCornerShape(topEndPercent = 50, bottomEndPercent = 50)
            Box(Modifier.fillMaxHeight().width(maxWidth / 2.4f).align(if (forward) Alignment.CenterEnd else Alignment.CenterStart)
                    .clip(shape).background(Color.White.copy(alpha = 0.16f)), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(if (forward) "▶▶▶" else "◀◀◀", color = Color.White, fontSize = 12.sp, letterSpacing = (-2).sp)
                    Spacer(Modifier.height(4.dp))
                    Text("$seconds seconds", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                }
            }
        }
        if (buffering) {
            androidx.compose.material3.CircularProgressIndicator(Modifier.align(Alignment.Center).size(44.dp), color = Color.White, strokeWidth = 3.dp)
        }
        AnimatedVisibility(visible, enter = fadeIn(), exit = fadeOut(), modifier = Modifier.fillMaxSize()) {
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f))) {
                Row(Modifier.fillMaxWidth().padding(4.dp).align(Alignment.TopStart)) {
                    IconButton(onClick = onCollapse) { Icon(Icons.Filled.KeyboardArrowDown, contentDescription = "Minimize", tint = Color.White) }
                    Spacer(Modifier.weight(1f))
                    IconButton(onClick = onSettings) { Icon(Icons.Outlined.Settings, contentDescription = "Settings", tint = Color.White) }
                }
                Row(Modifier.align(Alignment.Center), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(36.dp)) {
                    RoundControl(Icons.Filled.SkipPrevious, "Previous", 44.dp, enabled = hasPrevious) { player.seekToPreviousMediaItem(); lastTouch = System.currentTimeMillis() }
                    RoundControl(when { ended -> Icons.Filled.Replay; playing -> Icons.Filled.Pause; else -> Icons.Filled.PlayArrow },
                                 when { ended -> "Replay"; playing -> "Pause"; else -> "Play" }, 60.dp) {
                        if (player.isPlaying) player.pause() else {
                            if (player.playbackState == Player.STATE_ENDED) player.seekTo(0)
                            player.play()
                        }
                        lastTouch = System.currentTimeMillis()
                    }
                    RoundControl(Icons.Filled.SkipNext, "Next", 44.dp, enabled = hasNext) { player.seekToNextMediaItem(); lastTouch = System.currentTimeMillis() }
                }
                Row(Modifier.align(Alignment.BottomStart).fillMaxWidth().padding(start = 14.dp, end = 4.dp, bottom = if (fullscreen) 34.dp else 14.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    val shown = scrubbing?.let { (it * duration).toLong() } ?: position
                    Text("${Format.duration(shown)} / ${Format.duration(duration)}", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                    Spacer(Modifier.weight(1f))
                    IconButton(onClick = onFullscreen) {
                        Icon(if (fullscreen) Icons.Filled.FullscreenExit else Icons.Filled.Fullscreen, contentDescription = "Full screen", tint = Color.White)
                    }
                }
            }
        }
        if (ended && scrubbing == null) {
            DoneOverlay(nextTitle = nextTitle.takeIf { hasNext },
                onReplay = { player.seekTo(0); player.play() },
                onNext = { player.seekToNextMediaItem(); player.play() },
                onClose = onDone)
            return@BoxWithConstraints
        }
        // The seek bar: thin at the bottom edge, with a red scrubber while the controls show.
        val fraction = scrubbing ?: if (duration > 0) position.toFloat() / duration else 0f
        val bufferedFraction = if (duration > 0) buffered.toFloat() / duration else 0f
        Box(
            Modifier.align(Alignment.BottomStart).fillMaxWidth().height(24.dp)
                .offset { IntOffset(0, if (fullscreen) -(16.dp.roundToPx()) else 11.dp.roundToPx()) }
                .pointerInput(player, duration) {
                    detectHorizontalDragGestures(
                        onDragStart = { scrubbing = (it.x / width).coerceIn(0f, 1f); visible = true },
                        onHorizontalDrag = { change, _ -> scrubbing = (change.position.x / width).coerceIn(0f, 1f); lastTouch = System.currentTimeMillis() },
                        onDragEnd = { scrubbing?.let { player.seekTo((it * duration).toLong()) }; scrubbing = null },
                        onDragCancel = { scrubbing = null },
                    )
                }
                .pointerInput(player, duration) {
                    detectTapGestures { offset ->
                        if (visible) player.seekTo(((offset.x / width).coerceIn(0f, 1f) * duration).toLong()) else visible = true
                        lastTouch = System.currentTimeMillis()
                    }
                },
            contentAlignment = Alignment.BottomStart,
        ) {
            val barHeight = if (visible || scrubbing != null) 3.dp else 2.dp
            Box(Modifier.fillMaxWidth().height(barHeight).align(Alignment.CenterStart).background(Color.White.copy(alpha = 0.3f)))
            Box(Modifier.fillMaxWidth(bufferedFraction.coerceIn(0f, 1f)).height(barHeight).align(Alignment.CenterStart).background(Color.White.copy(alpha = 0.5f)))
            Box(Modifier.fillMaxWidth(fraction.coerceIn(0f, 1f)).height(barHeight).align(Alignment.CenterStart).background(ProgressRed))
            if (visible || scrubbing != null) {
                val dot = if (scrubbing != null) 16.dp else 12.dp
                Box(Modifier.align(Alignment.CenterStart)
                        .offset { IntOffset((fraction.coerceIn(0f, 1f) * width - dot.toPx() / 2).roundToInt(), 0) }
                        .size(dot).background(ProgressRed, CircleShape))
            }
        }
    }
}

/** The end of a video: no countdown into the next one, just a calm stop. */
@Composable
private fun DoneOverlay(nextTitle: String?, onReplay: () -> Unit, onNext: () -> Unit, onClose: () -> Unit) {
    Column(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.8f)).padding(16.dp),
           horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Icon(Icons.Filled.Check, contentDescription = null, tint = Color.White, modifier = Modifier.size(32.dp))
        Spacer(Modifier.height(6.dp))
        Text("You're done", color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.Medium)
        Spacer(Modifier.height(14.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            DarkPill("Replay", Icons.Filled.Replay, onReplay)
            DarkPill("Close", Icons.Filled.Close, onClose)
        }
        if (nextTitle != null) {
            Spacer(Modifier.height(10.dp))
            Text("Next: $nextTitle", color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp, maxLines = 1,
                 overflow = TextOverflow.Ellipsis, modifier = Modifier.clickable(onClick = onNext).padding(6.dp))
        }
    }
}

@Composable
private fun DarkPill(label: String, icon: androidx.compose.ui.graphics.vector.ImageVector, onClick: () -> Unit) {
    Row(Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.18f)).clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(6.dp))
        Text(label, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun RoundControl(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, size: androidx.compose.ui.unit.Dp,
                         enabled: Boolean = true, onClick: () -> Unit) {
    Box(Modifier.size(size).clip(CircleShape).background(Color.Black.copy(alpha = 0.35f))
            .clickable(enabled = enabled, onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, contentDescription = label, tint = if (enabled) Color.White else Color.White.copy(alpha = 0.3f), modifier = Modifier.size(size * 0.6f))
    }
}

/** The bar above the tabs while something plays: thumbnail, title, play/pause, close. */
@Composable
fun MiniPlayer(connection: PlayerConnection, item: VideoItem, onOpen: () -> Unit) {
    val playing by connection.isPlaying.collectAsStateCompat()
    val controller by connection.controller.collectAsStateCompat()
    var fraction by remember { mutableFloatStateOf(0f) }
    LaunchedEffect(controller) {
        while (true) {
            controller?.let { fraction = if (it.duration > 0) it.currentPosition.toFloat() / it.duration else 0f }
            delay(500)
        }
    }
    Column(Modifier.fillMaxWidth().background(Stow.colors.raised).clickable(onClick = onOpen)) {
        Row(Modifier.fillMaxWidth().height(60.dp), verticalAlignment = Alignment.CenterVertically) {
            if (!LocalCalm.current) {
                AsyncImage(model = item.video.thumbnailUrl, contentDescription = null, contentScale = ContentScale.Crop,
                           modifier = Modifier.fillMaxHeight().aspectRatio(16f / 9f).background(Color.Black))
            }
            Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                Text(item.video.title, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = Stow.colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(item.video.channelTitle, fontSize = 12.sp, color = Stow.colors.secondaryText, maxLines = 1)
            }
            IconButton(onClick = { connection.togglePlay() }) {
                Icon(if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, contentDescription = if (playing) "Pause" else "Play", tint = Stow.colors.text)
            }
            IconButton(onClick = { connection.stop() }) { Icon(Icons.Filled.Close, contentDescription = "Close", tint = Stow.colors.text) }
        }
        Box(Modifier.fillMaxWidth(fraction.coerceIn(0f, 1f)).height(2.dp).background(ProgressRed))
    }
}

@Composable
private fun <T> kotlinx.coroutines.flow.StateFlow<T>.collectAsStateCompat() = collectAsStateWithLifecycle()

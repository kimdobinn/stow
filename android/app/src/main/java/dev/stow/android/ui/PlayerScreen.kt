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
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.statusBars
import androidx.compose.runtime.Stable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.util.lerp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlin.math.abs

/** Each double-tap skips this far; taps in a row add up (5, 10, 15 s). */
private const val SKIP_MS = 5_000L

private val Speeds = listOf(0.25f, 0.5f, 0.75f, 1f, 1.25f, 1.5f, 1.75f, 2f)

/** How tall the mini player is, above the tabs. */
val MiniPlayerHeight = 60.dp

private val SheetSpring = spring<Float>(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = Spring.StiffnessMediumLow)

/**
 * Where the player is, like YouTube's: 1 is the full watch page, 0 the mini player above the
 * tabs, and anything between while it's dragged.
 */
@Stable
class PlayerSheetState(private val scope: CoroutineScope) {
    val progress = Animatable(0f)
    /** The mini player's sideways swipe (to close it), in pixels. */
    val swipe = Animatable(0f)
    val isExpanded: Boolean get() = progress.targetValue > 0.5f

    fun expand() { scope.launch { swipe.snapTo(0f) }; scope.launch { progress.animateTo(1f, SheetSpring) } }
    fun collapse() { scope.launch { progress.animateTo(0f, SheetSpring) } }
    /** Back to the mini position at once (nothing playing), so the next video slides up from it. */
    fun reset() { scope.launch { progress.snapTo(0f) }; scope.launch { swipe.snapTo(0f) } }

    internal fun dragBy(fraction: Float) {
        scope.launch { progress.snapTo((progress.value + fraction).coerceIn(0f, 1f)) }
    }

    /** Lets go of a drag: a flick decides, otherwise whichever end is nearer. `velocity` is in progress per second. */
    internal fun settle(velocity: Float) {
        val target = when {
            velocity > 1.5f -> 1f
            velocity < -1.5f -> 0f
            progress.value > 0.5f -> 1f
            else -> 0f
        }
        scope.launch { progress.animateTo(target, SheetSpring, initialVelocity = velocity) }
    }
}

@Composable
fun rememberPlayerSheetState(): PlayerSheetState {
    val scope = rememberCoroutineScope()
    return remember { PlayerSheetState(scope) }
}

/**
 * The player, drawn over the app while something plays. Expanded it's the watch page: the video
 * with YouTube-style controls (tap for controls, double-tap a side to skip 5 s, red seek bar, full
 * screen), the title and actions, then Up next. Drag the video down and it shrinks into the mini
 * player above the tabs (still playing); tap or drag that up to bring it back, swipe it sideways to
 * close. Swiping up on the video goes full screen; swiping down in full screen leaves it.
 */
@Composable
fun PlayerScreen(
    connection: PlayerConnection,
    current: VideoItem?,
    upNext: List<VideoItem>,
    channel: Channel?,
    actions: VideoActions,
    sheet: PlayerSheetState,
    /** The height of the tabs (and the navigation bar) under the mini player. */
    bottomInset: Dp,
) {
    val context = LocalContext.current
    val activity = context as? Activity
    val density = LocalDensity.current
    val controller by connection.controller.collectAsStateCompat()
    val playing by connection.isPlaying.collectAsStateCompat()
    var speedDialog by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    val uiScope = rememberCoroutineScope()
    val expanded = sheet.isExpanded
    val fullscreen = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE && expanded

    // Full screen: sideways, without the status and navigation bars.
    DisposableEffect(fullscreen) {
        val window = activity?.window
        if (window != null) {
            val insets = WindowCompat.getInsetsController(window, window.decorView)
            if (fullscreen) {
                insets.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                insets.hide(WindowInsetsCompat.Type.systemBars())
            } else {
                insets.show(WindowInsetsCompat.Type.systemBars())
            }
        }
        onDispose { window?.let { WindowCompat.getInsetsController(it, it.decorView).show(WindowInsetsCompat.Type.systemBars()) } }
    }
    // Shrinking the player (or closing it) gives rotation back to the phone.
    LaunchedEffect(expanded) { if (!expanded) activity?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED }
    DisposableEffect(Unit) { onDispose { activity?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED } }

    fun setFullscreen(on: Boolean) {
        activity?.requestedOrientation =
            if (on) ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE else ActivityInfo.SCREEN_ORIENTATION_USER_PORTRAIT
    }
    BackHandler(enabled = fullscreen || expanded) { if (fullscreen) setFullscreen(false) else sheet.collapse() }

    val player = controller
    val resolving = connection.resolving.collectAsStateCompat().value
    val streamError = connection.error.collectAsStateCompat().value
    val queue = connection.queue.collectAsStateCompat().value
    val index = queue.indexOf(current?.id)
    var fraction by remember { mutableFloatStateOf(0f) }
    LaunchedEffect(controller) {
        while (true) {
            controller?.let { fraction = if (it.duration > 0) it.currentPosition.toFloat() / it.duration else 0f }
            delay(500)
        }
    }

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val width = constraints.maxWidth.toFloat()
        val height = constraints.maxHeight.toFloat()
        val p = sheet.progress.value
        val statusTop = if (fullscreen) 0f else WindowInsets.statusBars.getTop(density).toFloat()
        val miniHeight = with(density) { MiniPlayerHeight.toPx() }
        val miniTop = height - with(density) { bottomInset.toPx() } - miniHeight
        val range = (miniTop - statusTop).coerceAtLeast(1f)
        // The video shrinks faster than it moves, like YouTube's.
        val sizeP = 1f - (1f - p) * (1f - p)
        val videoWidth = if (fullscreen) width else lerp(miniHeight * 16f / 9f, width, sizeP)
        val videoHeight = if (fullscreen) height else lerp(miniHeight, width * 9f / 16f, sizeP)
        val videoTop = if (fullscreen) 0f else lerp(miniTop, statusTop, p)
        val swipe = sheet.swipe.value
        val miniAlpha = ((1f - p * 4f) * (1f - abs(swipe) / width)).coerceIn(0f, 1f)

        // Drag up and down: follows the finger, then settles at the nearer end (or where it was flicked).
        val verticalDrag = Modifier.pointerInput(sheet, range, fullscreen) {
            val tracker = VelocityTracker()
            var total = 0f
            var pullUp = 0f
            detectVerticalDragGestures(
                onDragStart = { tracker.resetTracking(); total = 0f; pullUp = 0f },
                onVerticalDrag = { change, dy ->
                    total += dy
                    tracker.addPosition(change.uptimeMillis, Offset(0f, total))
                    when {
                        fullscreen -> {}
                        sheet.progress.value >= 1f && dy < 0 -> pullUp -= dy
                        else -> sheet.dragBy(-dy / range)
                    }
                },
                onDragEnd = {
                    val velocity = tracker.calculateVelocity().y
                    when {
                        fullscreen -> if (total > 80.dp.toPx() || velocity > 1500f) setFullscreen(false)
                        pullUp > 60.dp.toPx() -> setFullscreen(true)
                        else -> sheet.settle(-velocity / range)
                    }
                },
                onDragCancel = { if (!fullscreen) sheet.settle(0f) },
            )
        }
        // The mini player: swipe it sideways to close.
        val sideSwipe = Modifier.pointerInput(sheet, width) {
            detectHorizontalDragGestures(
                onHorizontalDrag = { _, dx -> if (sheet.progress.value < 0.01f) uiScope.launch { sheet.swipe.snapTo(sheet.swipe.value + dx) } },
                onDragEnd = {
                    uiScope.launch {
                        val gone = abs(sheet.swipe.value) > width * 0.35f
                        if (gone) {
                            sheet.swipe.animateTo(if (sheet.swipe.value > 0) width else -width)
                            connection.stop()
                        } else {
                            sheet.swipe.animateTo(0f)
                        }
                    }
                },
                onDragCancel = { uiScope.launch { sheet.swipe.animateTo(0f) } },
            )
        }
        fun Float.px() = with(density) { this@px.toDp() }

        // The watch page behind the video, fading in as it grows.
        if (p > 0.001f && !fullscreen) {
            Box(Modifier.offset { IntOffset(0, (videoTop - statusTop).roundToInt()) }.fillMaxSize()
                    .graphicsLayer { alpha = p }.background(Stow.colors.background))
            if (current != null) {
                LazyColumn(Modifier.offset { IntOffset(0, (videoTop + videoHeight).roundToInt()) }
                        .width(width.px()).height((height - videoTop - videoHeight).coerceAtLeast(0f).px())
                        .graphicsLayer { alpha = p }.navigationBarsPadding(),
                           userScrollEnabled = p > 0.99f) {
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

        // The mini player's bar: title, play/pause, close, and a thin progress line.
        if (miniAlpha > 0.001f && current != null && !fullscreen) {
            Column(Modifier.offset { IntOffset(swipe.roundToInt(), videoTop.roundToInt()) }
                    .width(width.px()).height(videoHeight.px()).graphicsLayer { alpha = miniAlpha }
                    .background(Stow.colors.raised)
                    .then(verticalDrag).then(sideSwipe)
                    .clickable(enabled = p < 0.01f) { sheet.expand() }) {
                Row(Modifier.fillMaxWidth().weight(1f), verticalAlignment = Alignment.CenterVertically) {
                    Spacer(Modifier.width(videoWidth.px()))
                    Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                        Text(current.video.title, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = Stow.colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(current.video.channelTitle, fontSize = 12.sp, color = Stow.colors.secondaryText, maxLines = 1)
                    }
                    IconButton(onClick = { connection.togglePlay() }) {
                        Icon(if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, contentDescription = if (playing) "Pause" else "Play", tint = Stow.colors.text)
                    }
                    IconButton(onClick = { connection.stop() }) { Icon(Icons.Filled.Close, contentDescription = "Close", tint = Stow.colors.text) }
                }
                Box(Modifier.fillMaxWidth(fraction.coerceIn(0f, 1f)).height(2.dp).background(ProgressRed))
            }
        }

        // The video itself: one player view, from full screen down to the mini player.
        Box(Modifier.offset { IntOffset(if (p < 0.01f) swipe.roundToInt() else 0, videoTop.roundToInt()) }
                .width(videoWidth.px()).height(videoHeight.px())
                .graphicsLayer { alpha = if (p < 0.01f) (1f - abs(swipe) / width).coerceIn(0f, 1f) else 1f }
                .background(Color.Black).then(verticalDrag).then(if (p < 0.01f) sideSwipe else Modifier)) {
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
            if (p < 0.99f) {
                // Shrunk: a tap brings the watch page back.
                Box(Modifier.fillMaxSize().clickable(enabled = p < 0.01f) { sheet.expand() })
                if (resolving != null) {
                    androidx.compose.material3.CircularProgressIndicator(Modifier.align(Alignment.Center).size(20.dp), color = Color.White, strokeWidth = 2.dp)
                }
            } else {
                if (player != null && resolving == null && streamError == null) {
                    PlayerControls(
                        player = player,
                        fullscreen = fullscreen,
                        hasPrevious = index > 0,
                        hasNext = index in 0 until queue.lastIndex,
                        nextTitle = upNext.firstOrNull()?.video?.title,
                        onDone = { connection.stop() },
                        onFullscreen = { setFullscreen(!fullscreen) },
                        onCollapse = { if (fullscreen) setFullscreen(false) else sheet.collapse() },
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
                    IconButton(onClick = { sheet.collapse() }, modifier = Modifier.align(Alignment.TopStart).padding(4.dp)) {
                        Icon(Icons.Filled.KeyboardArrowDown, contentDescription = "Minimize", tint = Color.White)
                    }
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

@Composable
private fun <T> kotlinx.coroutines.flow.StateFlow<T>.collectAsStateCompat() = collectAsStateWithLifecycle()

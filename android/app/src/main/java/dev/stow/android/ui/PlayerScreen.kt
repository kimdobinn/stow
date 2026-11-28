package dev.stow.android.ui

import android.app.Activity
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.view.ViewGroup
import androidx.activity.compose.BackHandler
import androidx.activity.compose.PredictiveBackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.FastOutLinearInEasing
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.scaleIn
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.togetherWith
import androidx.compose.ui.graphics.TransformOrigin
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.animation.core.tween
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.BoxWithConstraintsScope
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.ui.graphics.asImageBitmap
import kotlinx.coroutines.flow.conflate
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

/** What the video area shows besides the controls. */
private enum class StreamState { READY, FETCHING, FAILED }

/** A drag down this fast (dp per second) leaves full screen even when short. */
private const val FULLSCREEN_FLICK_DP_PER_SECOND = 500f

/** Each double-tap skips this far; taps in a row add up (5, 10, 15 s). */
private const val SKIP_MS = 5_000L
/** How fast the video plays while you hold the screen. */
private const val HOLD_SPEED = 2f

private val Speeds = listOf(0.25f, 0.5f, 0.75f, 1f, 1.25f, 1.5f, 1.75f, 2f)

/** How tall the mini player is, above the tabs. */
val MiniPlayerHeight = 60.dp

/**
 * Where the player is, like YouTube's: 1 is the full watch page, 0 the mini player above the
 * tabs, and anything between while it's dragged.
 */
@Stable
class PlayerSheetState(private val scope: CoroutineScope) {
    val progress = Animatable(0f, visibilityThreshold = 0.001f)
    /** The mini player's sideways swipe (to close it), in pixels. */
    val swipe = Animatable(0f)
    val isExpanded: Boolean get() = progress.targetValue > 0.5f

    // Opening and closing use the same firm spring as a let-go drag, so a tap and a flick feel alike.
    fun expand() { scope.launch { swipe.snapTo(0f) }; scope.launch { progress.animateTo(1f, Motion.Sheet) } }
    fun collapse() { scope.launch { progress.animateTo(0f, Motion.Sheet) } }
    /** Back to the mini position at once (nothing playing), so the next video slides up from it. */
    fun reset() { scope.launch { progress.snapTo(0f) }; scope.launch { swipe.snapTo(0f) } }

    /** A finger takes hold of the player: whatever it was doing (opening, closing) stops under it. */
    internal fun grab() {
        scope.launch(start = CoroutineStart.UNDISPATCHED) { progress.stop() }
        scope.launch(start = CoroutineStart.UNDISPATCHED) { swipe.stop() }
    }

    internal fun dragBy(fraction: Float) {
        // Undispatched: the move lands now, in order, instead of a frame later (when it could fight the finger).
        scope.launch(start = CoroutineStart.UNDISPATCHED) { progress.snapTo((progress.value + fraction).coerceIn(0f, 1f)) }
    }

    /**
     * Lets go of a drag: a flick decides, otherwise whichever end is nearer, and the spring starts
     * at the finger's speed. `velocity` is in pixels per second toward the watch page, `range` the
     * pixels from the mini player to the top, `flick` the speed that counts as a flick.
     */
    internal fun settle(velocity: Float, range: Float, flick: Float) {
        val target = Motion.sheetTarget(progress.value, velocity, flick)
        scope.launch { progress.animateTo(target, Motion.Sheet, initialVelocity = velocity / range) }
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
    /** The video's comments: saved ones unless `fresh`, else fetched. */
    loadComments: suspend (dev.stow.android.data.Video, Boolean) -> dev.stow.android.data.CommentsPage,
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
    // Back on the watch page follows the gesture (Android 14 and later): the page sinks toward the
    // mini player as the finger moves, comes back if the back is cancelled, and shrinks away when
    // it's done. Full screen can't follow a gesture (it's a rotation), so there back just leaves it.
    PredictiveBackHandler(enabled = expanded && !fullscreen) { events ->
        try {
            events.collect { event -> sheet.progress.snapTo(1f - event.progress * 0.25f) }
            sheet.collapse()
        } catch (e: CancellationException) {
            sheet.expand()
            throw e
        }
    }
    BackHandler(enabled = fullscreen) { setFullscreen(false) }

    val player = controller
    val resolving = connection.resolving.collectAsStateCompat().value
    val streamError = connection.error.collectAsStateCompat().value
    val queue = connection.queue.collectAsStateCompat().value
    val index = queue.indexOf(current?.id)
    // The full-screen video pulled down by a finger, in pixels.
    val fullscreenDrag = remember { Animatable(0f) }
    LaunchedEffect(fullscreen) { fullscreenDrag.snapTo(0f) }
    var fraction by remember { mutableFloatStateOf(0f) }
    LaunchedEffect(controller) {
        while (true) {
            controller?.let { fraction = if (it.duration > 0) it.currentPosition.toFloat() / it.duration else 0f }
            delay(500)
        }
    }

    // A finger is dragging the player up or down.
    var dragging by remember { mutableStateOf(false) }
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
        // In full screen, a drag down pulls the video with the finger; far enough (or flicked) leaves full screen.
        val verticalDrag = Modifier.pointerInput(sheet, range, fullscreen) {
            val tracker = VelocityTracker()
            var total = 0f
            var pullUp = 0f
            val flick = Motion.FLICK_DP_PER_SECOND.dp.toPx()
            // Ended without a let-go (the player went away under the finger): not dragging any more.
            try {
                detectVerticalDragGestures(
                    onDragStart = {
                        dragging = true
                        tracker.resetTracking(); total = 0f; pullUp = 0f
                        if (fullscreen) uiScope.launch(start = CoroutineStart.UNDISPATCHED) { fullscreenDrag.stop() } else sheet.grab()
                    },
                    onVerticalDrag = { change, dy ->
                        total += dy
                        tracker.addPosition(change.uptimeMillis, Offset(0f, total))
                        when {
                            fullscreen -> uiScope.launch(start = CoroutineStart.UNDISPATCHED) {
                                fullscreenDrag.snapTo((fullscreenDrag.value + dy).coerceAtLeast(0f))
                            }
                            sheet.progress.value >= 1f && dy < 0 -> pullUp -= dy
                            else -> sheet.dragBy(-dy / range)
                        }
                    },
                    onDragEnd = {
                        dragging = false
                        val velocity = tracker.calculateVelocity().y
                        when {
                            fullscreen -> {
                                val leave = total > 80.dp.toPx() || velocity > FULLSCREEN_FLICK_DP_PER_SECOND.dp.toPx()
                                if (leave) setFullscreen(false)
                                uiScope.launch { fullscreenDrag.animateTo(0f, Motion.Settle, initialVelocity = if (leave) 0f else velocity) }
                            }
                            pullUp > 60.dp.toPx() -> setFullscreen(true)
                            else -> sheet.settle(-velocity, range, flick)
                        }
                    },
                    onDragCancel = {
                        dragging = false
                        if (fullscreen) uiScope.launch { fullscreenDrag.animateTo(0f, Motion.Settle) } else sheet.settle(0f, range, flick)
                    },
                )
            } finally { dragging = false }
        }
        // The mini player: swipe it sideways to close. It follows the finger and fades; a flick
        // either way closes it even when short, carrying its speed off screen.
        val sideSwipe = Modifier.pointerInput(sheet, width) {
            val tracker = VelocityTracker()
            var total = 0f
            val flick = Motion.FLICK_DP_PER_SECOND.dp.toPx()
            detectHorizontalDragGestures(
                onDragStart = {
                    tracker.resetTracking(); total = 0f
                    uiScope.launch(start = CoroutineStart.UNDISPATCHED) { sheet.swipe.stop() }
                },
                onHorizontalDrag = { change, dx ->
                    total += dx
                    tracker.addPosition(change.uptimeMillis, Offset(total, 0f))
                    if (sheet.progress.value < 0.01f) {
                        uiScope.launch(start = CoroutineStart.UNDISPATCHED) { sheet.swipe.snapTo(sheet.swipe.value + dx) }
                    }
                },
                onDragEnd = {
                    val velocity = tracker.calculateVelocity().x
                    uiScope.launch {
                        if (Motion.swipeDismisses(sheet.swipe.value, velocity, width, flick)) {
                            sheet.swipe.animateTo(if (sheet.swipe.value > 0) width else -width, Motion.Fling, initialVelocity = velocity)
                            connection.stop()
                        } else {
                            sheet.swipe.animateTo(0f, Motion.SnapBack, initialVelocity = velocity)
                        }
                    }
                },
                onDragCancel = { uiScope.launch { sheet.swipe.animateTo(0f, Motion.SnapBack) } },
            )
        }
        fun Float.px() = with(density) { this@px.toDp() }

        // The watch page behind the video, fading in as it grows.
        if (p > 0.001f && !fullscreen) {
            Box(Modifier.offset { IntOffset(0, (videoTop - statusTop).roundToInt()) }.fillMaxSize()
                    .graphicsLayer { alpha = p }.background(Stow.colors.background))
            if (current != null) {
                // The page's text comes in over the last part of the way up (and goes early on the way
                // down), so the watch page and the feed under it never show two layers of text for long.
                LazyColumn(Modifier.offset { IntOffset(0, (videoTop + videoHeight).roundToInt()) }
                        .width(width.px()).height((height - videoTop - videoHeight).coerceAtLeast(0f).px())
                        .graphicsLayer { alpha = ((p - 0.4f) / 0.6f).coerceIn(0f, 1f) }.navigationBarsPadding(),
                           userScrollEnabled = p > 0.99f) {
        item(key = "about") {
            Column(Modifier.padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 10.dp)) {
                Text(current.video.title, style = StowType.title3, color = Stow.colors.text)
                Spacer(Modifier.height(4.dp))
                Text(listOf(Format.ago(current.video.publishedAt),
                            current.durationMs.takeIf { it > 0 }?.let(Format::duration) ?: "",
                            if (current.video.isMembersOnly) "Members only" else "")
                         .filter { it.isNotEmpty() }.joinToString(" · "),
                     style = StowType.footnote, color = Stow.colors.secondaryText)
            }
            Row(Modifier.fillMaxWidth().clickable { actions.openChannel(current.video.channelId) }
                    .padding(horizontal = 16.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                ChannelAvatar(channel?.avatarUrl ?: LocalChannelAvatars.current[current.video.channelId], 40.dp, name = current.video.channelTitle)
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(current.video.channelTitle, style = StowType.headline, fontSize = 16.sp, color = Stow.colors.text, maxLines = 1)
                    channel?.let {
                        Text(Format.count(it.recent.size, "recent video"), style = StowType.footnote, color = Stow.colors.secondaryText)
                    }
                }
            }
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PillButton(if (current.watched) "Watched" else "Mark Watched", if (current.watched) Icons.Filled.Check else null,
                           onClick = { actions.setWatched(current, !current.watched) })
                when {
                    current.isPlayable -> {}
                    current.isDownloading -> PillButton("Downloading ${current.local?.progress ?: 0}%", Icons.Outlined.Download, onClick = {})
                    else -> PillButton("Download", Icons.Outlined.Download, onClick = { actions.download(current) }, filled = true)
                }
                PillButton("Save", Icons.AutoMirrored.Outlined.PlaylistAdd, onClick = { actions.saveToPlaylist(current) })
                PillButton("Speed", Icons.Outlined.Speed, onClick = { speedDialog = true })
                if (current.isPlayable) PillButton("Delete", Icons.Outlined.Delete, onClick = { confirmDelete = true })
            }
            CommentsCard(current.video, loadComments)
        }
                    if (upNext.isNotEmpty()) {
                        item(key = "up-next") { SectionHeader("Up next", itemMotion()) }
                        items(upNext, key = { "n-" + it.id }) { VideoRow(it, actions, modifier = itemMotion()) }
                    }
                }
            }
        }

        // The mini player's bar: title, play/pause, close, and a thin progress line.
        // Kept while a drag that began on it lasts: taking it away as it fades would end the drag
        // halfway (the page would fall back to the mini player).
        if ((miniAlpha > 0.001f || dragging) && current != null && !fullscreen) {
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
                        SwapIcon(if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, contentDescription = if (playing) "Pause" else "Play",
                                 tint = Stow.colors.text, modifier = Modifier.size(24.dp))
                    }
                    IconButton(onClick = { connection.stop() }) { Icon(Icons.Filled.Close, contentDescription = "Close", tint = Stow.colors.text) }
                }
                Box(Modifier.fillMaxWidth(fraction.coerceIn(0f, 1f)).height(2.dp).background(Stow.colors.accent))
            }
        }

        // The video itself: one player view, from full screen down to the mini player.
        Box(Modifier.offset { IntOffset(if (p < 0.01f) swipe.roundToInt() else 0, videoTop.roundToInt()) }
                .width(videoWidth.px()).height(videoHeight.px())
                .graphicsLayer {
                    alpha = if (p < 0.01f) (1f - abs(swipe) / width).coerceIn(0f, 1f) else 1f
                    // Pulled down in full screen: the video moves and shrinks a little with the finger.
                    val pulled = fullscreenDrag.value
                    if (pulled > 0f) {
                        translationY = pulled
                        scaleX = 1f - pulled / height * 0.1f
                        scaleY = scaleX
                    }
                }
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
                // The controls fade in once the video is ready (and out while the next one is fetched).
                val shownPlayer = rememberLast(player)
                Appear(player != null && resolving == null && streamError == null, Modifier.fillMaxSize(),
                       enter = fadeIn(tween(200)), exit = fadeOut(tween(Motion.SHORT))) {
                    if (shownPlayer != null) PlayerControls(
                        player = shownPlayer,
                        fullscreen = fullscreen,
                        hasPrevious = index > 0,
                        hasNext = index in 0 until queue.lastIndex,
                        nextTitle = upNext.firstOrNull()?.video?.title,
                        onDone = { connection.stop() },
                        onFullscreen = { setFullscreen(!fullscreen) },
                        onCollapse = { if (fullscreen) setFullscreen(false) else sheet.collapse() },
                        onSettings = { speedDialog = true },
                        filePath = current?.local?.filePath,
                    )
                }
                // Fetching, failed or playing: each crossfades into the next instead of cutting.
                val shownError = rememberLast(streamError)
                AnimatedContent(when { streamError != null -> StreamState.FAILED; resolving != null -> StreamState.FETCHING; else -> StreamState.READY },
                                Modifier.align(Alignment.Center), contentAlignment = Alignment.Center,
                                transitionSpec = { fadeIn(tween(200)) togetherWith fadeOut(tween(Motion.SHORT)) }, label = "stream") { state ->
                    when (state) {
                        StreamState.FAILED -> Column(Modifier.padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(shownError.orEmpty(), color = Color.White, fontSize = 13.sp, maxLines = 4, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                            Spacer(Modifier.height(12.dp))
                            if (current != null) PillButton("Try again", null, onClick = { connection.play(listOf(current), current) })
                        }
                        StreamState.FETCHING -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            androidx.compose.material3.CircularProgressIndicator(Modifier.size(40.dp), color = Color.White, strokeWidth = 3.dp)
                            Spacer(Modifier.height(10.dp))
                            Text("Getting the video from YouTube…", color = Color.White.copy(alpha = 0.8f), fontSize = 12.sp)
                        }
                        StreamState.READY -> {}
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
    /** The downloaded file, for the frames shown while scrubbing (none while streaming). */
    filePath: String? = null,
) {
    var visible by remember { mutableStateOf(true) }
    var position by remember { mutableLongStateOf(0L) }
    var duration by remember { mutableLongStateOf(0L) }
    var buffered by remember { mutableLongStateOf(0L) }
    var playing by remember { mutableStateOf(player.isPlaying) }
    var scrubbing by remember { mutableStateOf<Float?>(null) }
    // A run of double-taps on one side.
    var skip by remember { mutableStateOf<SkipRun?>(null) }
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
            skip?.let { if (System.currentTimeMillis() - it.at > 800) skip = null }
            delay(200)
        }
    }

    val haptics = androidx.compose.ui.platform.LocalHapticFeedback.current
    // Held down: the video plays at 2x until you let go.
    var holding by remember { mutableStateOf(false) }
    BoxWithConstraints(Modifier.fillMaxSize().pointerInput(player) {
        // A tap shows or hides the controls at once (not after waiting to rule out a double tap);
        // a second tap soon after on one side skips instead and puts the controls back as they were.
        var lastTap: Pair<Long, Boolean>? = null
        var visibleBeforeTap = visible
        awaitEachGesture {
            val down = awaitFirstDown()
            var cancelled = false
            val up = withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) {
                waitForUpOrCancellation().also { if (it == null) cancelled = true }
            }
            if (cancelled) return@awaitEachGesture
            if (up == null) {
                val previous = player.playbackParameters
                val wasPlaying = player.playWhenReady
                holding = true
                visible = false
                haptics.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.LongPress)
                player.setPlaybackSpeed(HOLD_SPEED)
                player.play()
                try {
                    waitForUpOrCancellation()
                } finally {
                    player.playbackParameters = previous
                    if (!wasPlaying) player.pause()
                    holding = false
                    lastTap = null
                }
                return@awaitEachGesture
            }
            val now = System.currentTimeMillis()
            val forward = down.position.x > size.width / 2
            val skipping = skip?.let { it.forward == forward && now - it.at < 800 } == true
            val doubleTap = lastTap?.let { (at, side) -> side == forward && now - at < viewConfiguration.doubleTapTimeoutMillis } == true
            if (skipping || doubleTap) {
                if (doubleTap && !skipping) visible = visibleBeforeTap
                player.seekTo((player.currentPosition + if (forward) SKIP_MS else -SKIP_MS).coerceIn(0, player.duration.coerceAtLeast(0)))
                val previous = skip?.takeIf { it.forward == forward && now - it.at < 800 }
                skip = SkipRun(forward, (previous?.seconds ?: 0) + (SKIP_MS / 1000).toInt(), now, down.position)
                lastTap = null
            } else {
                visibleBeforeTap = visible
                visible = !visible
                lastTap = now to forward
            }
            lastTouch = now
        }
    }) {
        val width = constraints.maxWidth.toFloat()
        // YouTube's half-moon on the tapped side: a ripple from the finger, chevrons and the running total.
        SkipOverlay(skip)
        // Held down: a dark "2x" pill at the top with chevrons running, quickly in and out.
        Appear(holding, Modifier.align(Alignment.TopCenter).padding(top = 14.dp),
               enter = fadeIn(tween(Motion.SHORT)) + slideInVertically(Motion.enter(200)) { -it / 2 },
               exit = fadeOut(tween(Motion.SHORT))) {
            Row(Modifier.background(Color.Black.copy(alpha = 0.55f), androidx.compose.foundation.shape.RoundedCornerShape(50))
                    .padding(start = 12.dp, end = 8.dp, top = 5.dp, bottom = 5.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("2x", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.width(4.dp))
                SeekChevrons(forward = true, size = 14.dp)
            }
        }
        // Only a stall longer than a moment shows the spinner (the delay is in the fade), so quick
        // rebuffers don't flash it; it fades out when playback goes on.
        Appear(buffering, Modifier.align(Alignment.Center),
               enter = fadeIn(tween(Motion.SHORT, delayMillis = 300)), exit = fadeOut(tween(100))) {
            androidx.compose.material3.CircularProgressIndicator(Modifier.size(44.dp), color = Color.White, strokeWidth = 3.dp)
        }
        // The controls fade in quickly and out a little slower, like YouTube's.
        AnimatedVisibility(visible, enter = fadeIn(tween(Motion.SHORT, easing = LinearOutSlowInEasing)),
                           exit = fadeOut(tween(220, easing = FastOutLinearInEasing)), modifier = Modifier.fillMaxSize()) {
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f))) {
                Row(Modifier.fillMaxWidth().padding(4.dp).align(Alignment.TopStart)) {
                    IconButton(onClick = onCollapse) { Icon(Icons.Filled.KeyboardArrowDown, contentDescription = "Minimize", tint = Color.White) }
                    Spacer(Modifier.weight(1f))
                    IconButton(onClick = onSettings) { Icon(Icons.Outlined.Settings, contentDescription = "Settings", tint = Color.White) }
                }
                // Scrubbing: the middle buttons and the time fade away for the frame preview, and come back after.
                Appear(scrubbing == null, Modifier.align(Alignment.Center),
                       enter = fadeIn(tween(Motion.SHORT)), exit = fadeOut(tween(100))) {
                    Row(verticalAlignment = Alignment.CenterVertically,
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
                }
                Appear(scrubbing == null, Modifier.align(Alignment.BottomStart).fillMaxWidth(),
                       enter = fadeIn(tween(Motion.SHORT)), exit = fadeOut(tween(100))) {
                    Row(Modifier.fillMaxWidth().padding(start = 14.dp, end = 4.dp, bottom = if (fullscreen) 34.dp else 14.dp),
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
        }
        // The end of the video: the calm stop fades in rather than cutting in.
        val done = ended && scrubbing == null
        Appear(done, Modifier.fillMaxSize(), enter = fadeIn(Motion.enter(Motion.MEDIUM)), exit = fadeOut(tween(Motion.SHORT))) {
            DoneOverlay(nextTitle = nextTitle.takeIf { hasNext },
                onReplay = { player.seekTo(0); player.play() },
                onNext = { player.seekToNextMediaItem(); player.play() },
                onClose = onDone)
        }
        if (done) return@BoxWithConstraints
        // The seek bar: thin at the bottom edge, with a red scrubber while the controls show.
        val fraction = scrubbing ?: if (duration > 0) position.toFloat() / duration else 0f
        // While scrubbing: the frame and its time above the finger, growing in from the bar.
        val shownScrub = rememberLast(scrubbing)
        Appear(scrubbing != null,
               Modifier.align(Alignment.BottomStart).offset(x = scrubPreviewX(maxWidth, shownScrub ?: 0f, fullscreen))
                   .padding(bottom = if (fullscreen) 52.dp else 20.dp),
               enter = fadeIn(tween(100)) + scaleIn(tween(Motion.SHORT), initialScale = 0.9f, transformOrigin = TransformOrigin(0.5f, 1f)),
               exit = fadeOut(tween(100))) {
            shownScrub?.let { at -> ScrubPreview(filePath, (at * duration).toLong(), fullscreen) }
        }
        val bufferedFraction = if (duration > 0) buffered.toFloat() / duration else 0f
        Box(
            Modifier.align(Alignment.BottomStart).fillMaxWidth().height(24.dp)
                .offset { IntOffset(0, if (fullscreen) -(16.dp.roundToPx()) else 11.dp.roundToPx()) }
                .pointerInput(player, duration) {
                    // Like YouTube: a drag moves from where the video is, not from where the finger lands.
                    detectHorizontalDragGestures(
                        onDragStart = {
                            scrubbing = if (duration > 0) (player.currentPosition.toFloat() / duration).coerceIn(0f, 1f) else 0f
                            visible = true
                        },
                        onHorizontalDrag = { change, dragAmount ->
                            change.consume()
                            scrubbing = ((scrubbing ?: 0f) + dragAmount / width).coerceIn(0f, 1f)
                            lastTouch = System.currentTimeMillis()
                        },
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
            // The bar thickens and the red dot grows in with the controls (and more while it's held),
            // and both go back as the controls fade, instead of snapping.
            val barHeight by animateDpAsState(if (visible || scrubbing != null) 3.dp else 2.dp, tween(Motion.SHORT), label = "bar")
            val dotScale by animateFloatAsState(when { scrubbing != null -> 16f / 12f; visible -> 1f; else -> 0f },
                                                tween(Motion.SHORT, easing = Motion.Standard), label = "dot")
            Box(Modifier.fillMaxWidth().height(barHeight).align(Alignment.CenterStart).background(Color.White.copy(alpha = 0.3f)))
            Box(Modifier.fillMaxWidth(bufferedFraction.coerceIn(0f, 1f)).height(barHeight).align(Alignment.CenterStart).background(Color.White.copy(alpha = 0.5f)))
            Box(Modifier.fillMaxWidth(fraction.coerceIn(0f, 1f)).height(barHeight).align(Alignment.CenterStart).background(Stow.colors.accent))
            Box(Modifier.align(Alignment.CenterStart)
                    .offset { IntOffset((fraction.coerceIn(0f, 1f) * width - 6.dp.toPx()).roundToInt(), 0) }
                    .size(12.dp)
                    .graphicsLayer { scaleX = dotScale; scaleY = dotScale; alpha = dotScale.coerceAtMost(1f) }
                    .background(Stow.colors.accent, CircleShape))
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
    val interaction = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }
    Row(Modifier.pressScale(interaction).clip(CircleShape).background(Color.White.copy(alpha = 0.18f))
            .clickable(interactionSource = interaction, indication = androidx.compose.foundation.LocalIndication.current, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(6.dp))
        Text(label, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun RoundControl(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, size: androidx.compose.ui.unit.Dp,
                         enabled: Boolean = true, onClick: () -> Unit) {
    val interaction = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }
    Box(Modifier.size(size).pressScale(interaction).clip(CircleShape).background(Color.Black.copy(alpha = 0.35f))
            .clickable(interactionSource = interaction, indication = androidx.compose.foundation.LocalIndication.current,
                       enabled = enabled, onClick = onClick), contentAlignment = Alignment.Center) {
        // Play, pause and replay change into each other with a quick crossfade.
        SwapIcon(icon, contentDescription = label, tint = if (enabled) Color.White else Color.White.copy(alpha = 0.3f), modifier = Modifier.size(size * 0.6f))
    }
}

@Composable
private fun <T> kotlinx.coroutines.flow.StateFlow<T>.collectAsStateCompat() = collectAsStateWithLifecycle()

private fun scrubPreviewWidth(fullscreen: Boolean) = if (fullscreen) 200.dp else 150.dp

/** Where the scrub preview sits: centred over the finger, kept inside the video. */
private fun scrubPreviewX(maxWidth: Dp, fraction: Float, fullscreen: Boolean): Dp {
    val boxWidth = scrubPreviewWidth(fullscreen)
    return (maxWidth * fraction - boxWidth / 2).coerceIn(8.dp, (maxWidth - boxWidth - 8.dp).coerceAtLeast(8.dp))
}

/** While scrubbing: the frame at that point (from the downloaded file) and its time, above the bar. */
@Composable
private fun ScrubPreview(filePath: String?, timeMs: Long, fullscreen: Boolean) {
    val frame = rememberScrubFrame(filePath, timeMs)
    val boxWidth = scrubPreviewWidth(fullscreen)
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        if (filePath != null) {
            Box(Modifier.width(boxWidth).aspectRatio(16f / 9f).clip(androidx.compose.foundation.shape.RoundedCornerShape(8.dp))
                    .background(Color.Black).border(1.5.dp, Color.White, androidx.compose.foundation.shape.RoundedCornerShape(8.dp))) {
                frame?.let {
                    androidx.compose.foundation.Image(it, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                }
            }
            Spacer(Modifier.height(4.dp))
        }
        Text(Format.duration(timeMs), color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
             modifier = Modifier.width(boxWidth), textAlign = androidx.compose.ui.text.style.TextAlign.Center,
             style = androidx.compose.ui.text.TextStyle(shadow = androidx.compose.ui.graphics.Shadow(Color.Black.copy(alpha = 0.7f), blurRadius = 6f)))
    }
}

/**
 * The frame nearest `timeMs` in the file (its closest keyframe, which is quick), read one at a
 * time on a background thread; while the finger moves, only the latest position is read next.
 */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
@Composable
private fun rememberScrubFrame(filePath: String?, timeMs: Long): androidx.compose.ui.graphics.ImageBitmap? {
    var frame by remember(filePath) { mutableStateOf<androidx.compose.ui.graphics.ImageBitmap?>(null) }
    val target by androidx.compose.runtime.rememberUpdatedState(timeMs)
    LaunchedEffect(filePath) {
        if (filePath == null) return@LaunchedEffect
        val reader = kotlinx.coroutines.Dispatchers.IO.limitedParallelism(1)
        val retriever = android.media.MediaMetadataRetriever()
        try {
            kotlinx.coroutines.withContext(reader) { retriever.setDataSource(filePath) }
            androidx.compose.runtime.snapshotFlow { target }
                .conflate()
                .collect { at ->
                    val bitmap = kotlinx.coroutines.withContext(reader) {
                        runCatching {
                            retriever.getScaledFrameAtTime(at * 1000, android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 384, 216)
                        }.getOrNull()
                    }
                    if (bitmap != null) frame = bitmap.asImageBitmap()
                }
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
        } finally {
            kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable + reader) { runCatching { retriever.release() } }
        }
    }
    return frame
}



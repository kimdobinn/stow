package dev.stow.android.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.draw.drawBehind
import kotlinx.coroutines.launch
import kotlin.math.abs
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Alarm
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Forward5
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay5
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.outlined.VideoLibrary
import androidx.compose.material.icons.outlined.WifiOff
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.SliderState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import coil3.compose.AsyncImage
import dev.stow.android.remote.AlarmPhase
import dev.stow.android.remote.AlarmState
import dev.stow.android.remote.AlarmVideo
import dev.stow.android.remote.RemoteModel
import dev.stow.android.remote.RemoteUi
import kotlinx.coroutines.delay
import kotlin.math.roundToInt

/** Each double-tap on the picture seeks this far on the Mac; taps in a row add up (10, 20, 30 s). */
private const val REMOTE_SKIP_SECONDS = 5

private const val SAME_WIFI = "Phone and Mac must be on the same Wi-Fi."

/**
 * The phone as the Mac's alarm remote: what's playing, seek, pause, next, the speaker's volume,
 * "I'm awake", and other videos to switch to. Polls the Mac only while it's on screen.
 */
@Composable
fun RemoteScreen(model: RemoteModel, macName: String?, onBack: () -> Unit) {
    val ui by model.ui.collectAsStateWithLifecycle()
    val notice by model.notice.collectAsStateWithLifecycle()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(lifecycle) { lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) { model.poll() } }
    var choosing by remember { mutableStateOf(false) }
    val name = (ui as? RemoteUi.Live)?.state?.macName ?: macName

    Column(Modifier.fillMaxSize()) {
        BackTopBar(name?.let { "Alarm on $it" } ?: "Alarm remote", onBack)
        // Searching, unreachable, live and ended crossfade into each other (live updates themselves don't).
        AnimatedContent(ui, Modifier.weight(1f), contentKey = { it::class }, transitionSpec = {
            fadeIn(tween(200)) togetherWith fadeOut(tween(Motion.SHORT))
        }, label = "remote") { shown ->
            Box(Modifier.fillMaxSize()) {
                when (val state = shown) {
                    RemoteUi.NotPaired -> Message(Icons.Filled.Alarm, "Pair with the Mac first",
                                                  "On the Mac: Stow › Phone › Pair a Phone, then scan the code with this app.")
                    RemoteUi.Searching -> Message(null, "Looking for the Mac…", SAME_WIFI, busy = true)
                    is RemoteUi.Unreachable -> Message(Icons.Outlined.WifiOff, "Can't reach the Mac",
                                                       state.reason ?: "$SAME_WIFI\nThe remote works while an alarm is running.",
                                                       action = "Retry" to model::retry)
                    RemoteUi.Ended -> Message(Icons.Filled.Check, "Alarm finished", "Good morning.", action = "Back" to onBack)
                    is RemoteUi.Live -> Live(state.state, model, onChoose = { choosing = true; model.loadChoices() })
                }
            }
        }
        // The notice rises from the bottom and folds away, keeping its text while it goes.
        val lastNotice = rememberLast(notice)
        Appear(notice != null, enter = expandVertically(Motion.enter(), expandFrom = Alignment.Top) + fadeIn(tween(Motion.SHORT)),
               exit = shrinkVertically(Motion.exit(), shrinkTowards = Alignment.Top) + fadeOut(tween(Motion.SHORT))) {
            Text(lastNotice.orEmpty(), color = Color.White, fontSize = 14.sp, modifier = Modifier.fillMaxWidth().background(Color(0xFF323232))
                .navigationBarsPadding().padding(horizontal = 16.dp, vertical = 12.dp))
        }
    }

    if (choosing) {
        val choices by model.choices.collectAsStateWithLifecycle()
        ChoicesSheet(choices, onPick = { model.playVideo(it.id) }, onDismiss = { choosing = false })
    }
}

@Composable
private fun Message(icon: ImageVector?, title: String, text: String, busy: Boolean = false, action: Pair<String, () -> Unit>? = null) {
    Column(Modifier.fillMaxSize().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally,
           verticalArrangement = Arrangement.Center) {
        if (busy) CircularProgressIndicator(Modifier.size(40.dp), color = Stow.colors.text, strokeWidth = 3.dp)
        icon?.let {
            Box(Modifier.size(56.dp).clip(CircleShape).background(Stow.colors.chip), contentAlignment = Alignment.Center) {
                Icon(it, contentDescription = null, tint = Stow.colors.text, modifier = Modifier.size(30.dp))
            }
        }
        Spacer(Modifier.height(14.dp))
        Text(title, fontSize = 18.sp, fontWeight = FontWeight.Bold, color = Stow.colors.text, textAlign = TextAlign.Center)
        Spacer(Modifier.height(6.dp))
        Text(text, fontSize = 14.sp, color = Stow.colors.secondaryText, textAlign = TextAlign.Center)
        action?.let { (label, onClick) ->
            Spacer(Modifier.height(16.dp))
            PillButton(label, null, onClick, filled = true)
        }
    }
}

@Composable
private fun Live(state: AlarmState, model: RemoteModel, onChoose: () -> Unit) {
    val player = state.phase.hasPlayer
    LazyColumn(Modifier.fillMaxSize()) {
        item(key = "picture") {
            if (player) Picture(state, onSeek = model::seekBy) else Waiting(state.phase)
        }
        if (player) {
            item(key = "info") {
                Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
                    Text(state.video?.title ?: "Starting…", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = Stow.colors.text,
                         maxLines = 2, overflow = TextOverflow.Ellipsis, lineHeight = 23.sp)
                    Spacer(Modifier.height(2.dp))
                    Text(listOfNotNull(state.video?.channelTitle, "${state.index + 1} of ${state.count}".takeIf { state.count > 0 })
                             .joinToString(" · "), fontSize = 13.sp, color = Stow.colors.secondaryText, maxLines = 1)
                }
            }
            item(key = "progress") { Progress(state, onSeekTo = model::seekTo) }
            item(key = "controls") {
                Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), horizontalArrangement = Arrangement.SpaceEvenly,
                    verticalAlignment = Alignment.CenterVertically) {
                    Control(Icons.Filled.Replay5, "Back 5 seconds", 48.dp) { model.seekBy(-REMOTE_SKIP_SECONDS) }
                    Control(if (state.isPaused) Icons.Filled.PlayArrow else Icons.Filled.Pause,
                            if (state.isPaused) "Play" else "Pause", 68.dp, filled = true, onClick = model::togglePaused)
                    Control(Icons.Filled.Forward5, "Forward 5 seconds", 48.dp) { model.seekBy(REMOTE_SKIP_SECONDS) }
                    Control(Icons.Filled.SkipNext, "Next", 48.dp, onClick = model::next)
                }
            }
        }
        item(key = "volume") { Volume(state, model) }
        item(key = "awake") {
            Box(Modifier.fillMaxWidth().padding(16.dp).height(64.dp).clip(RoundedCornerShape(32.dp)).background(StowGradient)
                    .clickable(onClick = model::stop), contentAlignment = Alignment.Center) {
                Text("I'm awake", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            }
        }
        if (player) {
            item(key = "else") {
                Row(Modifier.padding(horizontal = 16.dp)) { PillButton("Play something else", Icons.Outlined.VideoLibrary, onChoose) }
            }
            if (state.playlist.isNotEmpty()) {
                item(key = "up-next") { SectionHeader("Up next") }
                itemsIndexed(state.playlist, key = { index, video -> "$index-${video.id}" }) { index, video ->
                    VideoLine(video, current = index == state.index, onClick = { model.playIndex(index) }, modifier = itemMotion())
                }
            }
        }
        item(key = "end") { Spacer(Modifier.navigationBarsPadding().height(16.dp)) }
    }
}

/** The video's picture: double-tap the left or right half to seek, like the player. */
@Composable
private fun Picture(state: AlarmState, onSeek: (Int) -> Unit) {
    // A run of double-taps on one side.
    var skip by remember { mutableStateOf<SkipRun?>(null) }
    LaunchedEffect(skip) { if (skip != null) { delay(800); skip = null } }
    BoxWithConstraints(Modifier.fillMaxWidth().aspectRatio(16f / 9f).background(Color.Black).pointerInput(Unit) {
        detectTapGestures(onDoubleTap = { offset ->
            val forward = offset.x > size.width / 2
            onSeek(if (forward) REMOTE_SKIP_SECONDS else -REMOTE_SKIP_SECONDS)
            val now = System.currentTimeMillis()
            val previous = skip?.takeIf { it.forward == forward && now - it.at < 800 }
            skip = SkipRun(forward, (previous?.seconds ?: 0) + REMOTE_SKIP_SECONDS, now, offset)
        })
    }) {
        if (!LocalCalm.current) {
            AsyncImage(model = state.video?.thumbnailUrl, contentDescription = null, contentScale = ContentScale.Crop,
                       modifier = Modifier.fillMaxSize())
        }
        if (state.isLoading) {
            CircularProgressIndicator(Modifier.align(Alignment.Center).size(44.dp), color = Color.White, strokeWidth = 3.dp)
        }
        // The paused mark fades and grows in, and fades out when it plays again.
        Appear(state.isPaused && !state.isLoading, Modifier.align(Alignment.Center),
               enter = fadeIn(tween(Motion.SHORT)) + scaleIn(tween(Motion.SHORT), initialScale = 0.8f), exit = fadeOut(tween(Motion.SHORT))) {
            Icon(Icons.Filled.Pause, contentDescription = "Paused", tint = Color.White,
                 modifier = Modifier.size(52.dp).background(Color.Black.copy(alpha = 0.45f), CircleShape).padding(10.dp))
        }
        // The same double-tap feedback as the player's.
        SkipOverlay(skip)
    }
}

/** Before the videos start, or when the Mac fell back to its alarm sound. */
@Composable
private fun Waiting(phase: AlarmPhase) {
    Column(Modifier.fillMaxWidth().aspectRatio(16f / 9f).background(Stow.colors.chip),
           horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        if (phase == AlarmPhase.PREPARING) {
            CircularProgressIndicator(Modifier.size(40.dp), color = Stow.colors.text, strokeWidth = 3.dp)
        } else {
            Icon(Icons.Filled.Alarm, contentDescription = null, tint = Stow.colors.text, modifier = Modifier.size(48.dp))
        }
        Spacer(Modifier.height(12.dp))
        Text(if (phase == AlarmPhase.PREPARING) "Getting the alarm ready…" else "Alarm sound playing",
             fontSize = 17.sp, fontWeight = FontWeight.Medium, color = Stow.colors.text)
    }
}

/** The red bar with position / duration; tap it to jump there. */
@Composable
private fun Progress(state: AlarmState, onSeekTo: (Double) -> Unit) {
    val duration = state.duration?.takeIf { it > 0 }
    val fraction = duration?.let { (state.position / it).toFloat().coerceIn(0f, 1f) } ?: 0f
    // The Mac reports the position once a second: the bar glides evenly between reports (so it
    // moves like a playing video's) and jumps only for a seek, a pause or a new video.
    val shown = remember { Animatable(fraction) }
    LaunchedEffect(fraction, state.isPaused) {
        val jumpSeconds = abs(fraction - shown.value) * (duration ?: 0.0)
        if (state.isPaused || jumpSeconds > 2.5) shown.snapTo(fraction)
        else shown.animateTo(fraction, tween(1000, easing = LinearEasing))
    }
    val accent = Stow.colors.accent
    Column(Modifier.padding(horizontal = 16.dp)) {
        Box(Modifier.fillMaxWidth().height(20.dp).pointerInput(duration) {
            detectTapGestures { offset -> duration?.let { onSeekTo((offset.x / size.width).coerceIn(0f, 1f) * it) } }
        }, contentAlignment = Alignment.CenterStart) {
            Box(Modifier.fillMaxWidth().height(3.dp).background(Stow.colors.divider))
            // Drawn from the animation, so gliding redraws the bar without recomposing the screen.
            Box(Modifier.fillMaxWidth().height(3.dp).drawBehind {
                drawRect(accent, size = size.copy(width = size.width * shown.value.coerceIn(0f, 1f)))
            })
        }
        Row {
            Text(Format.duration((state.position * 1000).toLong()), fontSize = 12.sp, color = Stow.colors.secondaryText)
            Spacer(Modifier.weight(1f))
            duration?.let { Text(Format.duration((it * 1000).toLong()), fontSize = 12.sp, color = Stow.colors.secondaryText) }
        }
    }
}

@Composable
private fun Volume(state: AlarmState, model: RemoteModel) {
    Column(Modifier.padding(horizontal = 8.dp, vertical = 4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = model::toggleMuted) {
                Icon(if (state.isMuted) Icons.AutoMirrored.Filled.VolumeOff else Icons.AutoMirrored.Filled.VolumeUp,
                     contentDescription = if (state.isMuted) "Unmute" else "Mute", tint = Stow.colors.text)
            }
            val volume = state.volume
            if (volume != null) {
                val slider = remember { SliderState(volume.toFloat(), 0, 0f..100f) }
                LaunchedEffect(volume) { if (!slider.isDragging) slider.value = volume.toFloat() }
                Slider(slider, onValueChange = { model.setVolume(it.roundToInt()) }, modifier = Modifier.weight(1f),
                       colors = SliderDefaults.colors(thumbColor = Stow.colors.text, activeTrackColor = Stow.colors.text,
                                                      inactiveTrackColor = Stow.colors.chip))
                Text("$volume", fontSize = 14.sp, color = Stow.colors.text, textAlign = TextAlign.End,
                     modifier = Modifier.width(44.dp).padding(end = 8.dp))
            } else {
                Text("The Mac can't read this speaker's volume.", fontSize = 13.sp, color = Stow.colors.secondaryText)
            }
        }
        Text(listOfNotNull(state.outputName, "Volume keys change the Mac's volume here".takeIf { state.volume != null })
                 .joinToString(" · "), fontSize = 12.sp, color = Stow.colors.secondaryText, modifier = Modifier.padding(horizontal = 12.dp))
    }
}

@Composable
private fun Control(icon: ImageVector, label: String, size: androidx.compose.ui.unit.Dp, filled: Boolean = false, onClick: () -> Unit) {
    val interaction = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }
    Box(Modifier.size(size).pressScale(interaction).clip(CircleShape).background(if (filled) Stow.colors.chipSelected else Stow.colors.chip)
            .clickable(interactionSource = interaction, indication = androidx.compose.foundation.LocalIndication.current, onClick = onClick),
        contentAlignment = Alignment.Center) {
        SwapIcon(icon, contentDescription = label, tint = if (filled) Stow.colors.chipSelectedText else Stow.colors.text,
                 modifier = Modifier.size(size * 0.55f))
    }
}

@Composable
private fun VideoLine(video: AlarmVideo, current: Boolean, onClick: () -> Unit, subtitle: String = video.channelTitle,
                      modifier: Modifier = Modifier) {
    // "Now playing" moves to the next row with a quick fade of the highlight.
    val highlight by animateColorAsState(if (current) Stow.colors.chip else Color.Transparent, tween(Motion.SHORT), label = "now")
    Row(modifier.fillMaxWidth().drawBehind { drawRect(highlight) }.clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        if (!LocalCalm.current) {
            AsyncImage(model = video.thumbnailUrl, contentDescription = null, contentScale = ContentScale.Crop,
                       modifier = Modifier.width(128.dp).aspectRatio(16f / 9f).clip(RoundedCornerShape(8.dp)).background(Stow.colors.chip))
            Spacer(Modifier.width(12.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(video.title, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = Stow.colors.text, maxLines = 2,
                 overflow = TextOverflow.Ellipsis, lineHeight = 19.sp)
            Text(if (current) "Now playing" else subtitle, fontSize = 12.sp,
                 color = if (current) Stow.colors.accent else Stow.colors.secondaryText, maxLines = 1)
        }
    }
}

/** "Play something else": the Mac's Inbox and channels' recent videos, newest first. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ChoicesSheet(choices: List<AlarmVideo>?, onPick: (AlarmVideo) -> Unit, onDismiss: () -> Unit) {
    val sheet = rememberModalBottomSheetState()
    val scope = rememberCoroutineScope()
    // Picking a video slides the sheet down (with its scrim) before it goes, like any other dismiss.
    fun pick(video: AlarmVideo) {
        onPick(video)
        scope.launch { sheet.hide() }.invokeOnCompletion { if (!sheet.isVisible) onDismiss() }
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheet, containerColor = Stow.colors.raised) {
        Text("Play something else", fontSize = 16.sp, fontWeight = FontWeight.Bold, color = Stow.colors.text,
             modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp))
        when {
            choices == null -> Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(Modifier.size(32.dp), color = Stow.colors.text, strokeWidth = 3.dp)
            }
            choices.isEmpty() -> EmptyState("Nothing else to play.")
            else -> LazyColumn(Modifier.fillMaxWidth()) {
                itemsIndexed(choices, key = { _, video -> video.id }) { _, video ->
                    val ago = video.publishedAt?.let { runCatching { java.util.Date.from(java.time.Instant.parse(it)) }.getOrNull() }
                    VideoLine(video, current = false, onClick = { pick(video) },
                              subtitle = listOfNotNull(video.channelTitle, ago?.let(Format::ago)).joinToString(" · "))
                }
                item { Spacer(Modifier.navigationBarsPadding().height(16.dp)) }
            }
        }
    }
}

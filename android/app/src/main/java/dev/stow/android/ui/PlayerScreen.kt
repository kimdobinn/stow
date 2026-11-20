package dev.stow.android.ui

import android.app.Activity
import android.content.ComponentName
import android.content.res.Configuration
import android.net.Uri
import android.view.ViewGroup
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import androidx.media3.ui.PlayerView
import dev.stow.android.data.VideoItem
import dev.stow.android.player.PlaybackService
import kotlinx.coroutines.delay
import java.io.File

/**
 * Plays a downloaded video through PlaybackService, so it keeps going with the screen off or
 * the app in the background. Turn the phone sideways for full screen. Leaving the screen stops it.
 */
@Composable
fun PlayerScreen(
    item: VideoItem,
    onPosition: (positionMs: Long, durationMs: Long) -> Unit,
    onWatched: () -> Unit,
    onSetWatched: (Boolean) -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val landscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
    var controller by remember { mutableStateOf<MediaController?>(null) }
    val filePath = item.local?.filePath ?: return

    DisposableEffect(item.id) {
        val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
        val future = MediaController.Builder(context, token).buildAsync()
        future.addListener({
            val connected = runCatching { future.get() }.getOrNull() ?: return@addListener
            if (connected.currentMediaItem?.mediaId != item.id) {
                val media = MediaItem.Builder()
                    .setMediaId(item.id)
                    .setUri(Uri.fromFile(File(filePath)))
                    .setMediaMetadata(MediaMetadata.Builder()
                        .setTitle(item.remote.title)
                        .setArtist(item.remote.channelTitle)
                        .setArtworkUri(item.remote.thumbnailUrl?.let(Uri::parse))
                        .build())
                    .build()
                // Start where you left off, unless you'd nearly finished.
                val saved = item.local.positionMs
                val duration = item.local.durationMs
                val start = if (duration > 0 && saved > duration * 0.95) 0 else saved
                connected.setMediaItem(media, start)
                connected.prepare()
            }
            connected.play()
            controller = connected
        }, ContextCompat.getMainExecutor(context))
        onDispose {
            controller?.let { onPosition(it.currentPosition, it.duration.coerceAtLeast(0)) }
            controller?.stop()
            controller?.clearMediaItems()
            MediaController.releaseFuture(future)
            controller = null
        }
    }

    // Save the position now and then, and mark the video watched at 90%.
    LaunchedEffect(controller) {
        val player = controller ?: return@LaunchedEffect
        var markedWatched = item.remote.watched
        while (true) {
            delay(2_000)
            val duration = player.duration
            val position = player.currentPosition
            if (duration > 0) {
                onPosition(position, duration)
                if (!markedWatched && (position >= duration * 0.9 || player.playbackState == Player.STATE_ENDED)) {
                    markedWatched = true
                    onWatched()
                }
            }
        }
    }

    // Full screen when sideways: hide the status and navigation bars.
    val window = (context as? Activity)?.window
    DisposableEffect(landscape) {
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

    BackHandler(onBack = onClose)

    val video: @Composable (Modifier) -> Unit = { modifier ->
        AndroidView(
            factory = { ctx ->
                PlayerView(ctx).apply {
                    layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                    setShowNextButton(false)
                    setShowPreviousButton(false)
                    keepScreenOn = true
                }
            },
            update = { view -> view.player = controller },
            modifier = modifier.background(Color.Black),
        )
    }

    if (landscape) {
        Box(Modifier.fillMaxSize().background(Color.Black)) { video(Modifier.fillMaxSize()) }
    } else {
        Column(Modifier.fillMaxSize().statusBarsPadding()) {
            video(Modifier.fillMaxWidth().aspectRatio(16f / 9f))
            Column(Modifier.padding(16.dp)) {
                Text(item.remote.title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(4.dp))
                Text(
                    listOf(item.remote.channelTitle, Format.ago(item.remote.publishedAt)).filter { it.isNotEmpty() }.joinToString(" · "),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(16.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = { onSetWatched(!item.remote.watched) }) {
                        Text(if (item.remote.watched) "Mark as unwatched" else "Mark as watched")
                    }
                    OutlinedButton(onClick = onClose) { Text("Close") }
                }
            }
        }
    }
}

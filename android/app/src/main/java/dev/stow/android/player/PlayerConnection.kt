package dev.stow.android.player

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import androidx.core.content.ContextCompat
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import dev.stow.android.data.Repository
import dev.stow.android.data.VideoItem
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.io.File

/**
 * The app's one connection to PlaybackService, shared by the player screen and the mini-player.
 * Saves where you are in each video and marks it watched at 90%, wherever it's playing from.
 */
class PlayerConnection(private val context: Context, private val repository: Repository) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private val _controller = MutableStateFlow<MediaController?>(null)
    val controller: StateFlow<MediaController?> = _controller.asStateFlow()

    /** The video playing (or paused), null when nothing is loaded. */
    private val _current = MutableStateFlow<String?>(null)
    val current: StateFlow<String?> = _current.asStateFlow()

    /** Video ids in play order. */
    private val _queue = MutableStateFlow<List<String>>(emptyList())
    val queue: StateFlow<List<String>> = _queue.asStateFlow()

    private val _isPlaying = MutableStateFlow(false)
    val isPlaying: StateFlow<Boolean> = _isPlaying.asStateFlow()

    private val markedWatched = mutableSetOf<String>()

    init {
        val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
        val future = MediaController.Builder(context, token).buildAsync()
        future.addListener({
            val controller = runCatching { future.get() }.getOrNull() ?: return@addListener
            controller.addListener(object : Player.Listener {
                override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                    savePosition()
                    _current.value = mediaItem?.mediaId
                }

                override fun onIsPlayingChanged(isPlaying: Boolean) {
                    _isPlaying.value = isPlaying
                    if (!isPlaying) savePosition()
                }
            })
            _current.value = controller.currentMediaItem?.mediaId
            _queue.value = (0 until controller.mediaItemCount).map { controller.getMediaItemAt(it).mediaId }
            _isPlaying.value = controller.isPlaying
            _controller.value = controller
        }, ContextCompat.getMainExecutor(context))

        scope.launch {
            while (true) {
                delay(2_000)
                track()
            }
        }
    }

    /** Plays `items` (the downloaded ones) from `start`, resuming where you left off. */
    fun play(items: List<VideoItem>, start: VideoItem) {
        val controller = _controller.value ?: return
        val playable = items.filter { it.isPlayable }.ifEmpty { listOf(start) }
        val index = playable.indexOfFirst { it.id == start.id }.coerceAtLeast(0)
        if (_current.value == start.id && _queue.value == playable.map { it.id }) {
            controller.play()
            return
        }
        savePosition()
        val local = playable[index].local
        val resume = local?.positionMs?.takeIf { local.durationMs <= 0 || it < local.durationMs * 0.95 } ?: 0
        controller.setMediaItems(playable.map(::mediaItem), index, resume)
        controller.prepare()
        controller.play()
        _queue.value = playable.map { it.id }
        _current.value = start.id
    }

    fun togglePlay() {
        val controller = _controller.value ?: return
        if (controller.isPlaying) controller.pause() else {
            if (controller.playbackState == Player.STATE_ENDED) controller.seekTo(0)
            controller.play()
        }
    }

    fun setSpeed(speed: Float) {
        _controller.value?.playbackParameters = PlaybackParameters(speed)
    }

    /** Stops playback and closes the mini-player. */
    fun stop() {
        savePosition()
        _controller.value?.run {
            stop()
            clearMediaItems()
        }
        _current.value = null
        _queue.value = emptyList()
    }

    private fun mediaItem(item: VideoItem): MediaItem = MediaItem.Builder()
        .setMediaId(item.id)
        .setUri(Uri.fromFile(File(item.local?.filePath ?: "")))
        .setMediaMetadata(MediaMetadata.Builder()
            .setTitle(item.video.title)
            .setArtist(item.video.channelTitle)
            .setArtworkUri(item.video.thumbnailUrl?.let(Uri::parse))
            .build())
        .build()

    private fun savePosition() {
        val controller = _controller.value ?: return
        val id = controller.currentMediaItem?.mediaId ?: return
        repository.savePosition(id, controller.currentPosition, controller.duration.coerceAtLeast(0))
    }

    private fun track() {
        val controller = _controller.value ?: return
        val id = controller.currentMediaItem?.mediaId ?: return
        val duration = controller.duration
        if (duration <= 0) return
        if (controller.isPlaying) savePosition()
        val ended = controller.playbackState == Player.STATE_ENDED
        if (id !in markedWatched && (controller.currentPosition >= duration * 0.9 || ended)) {
            markedWatched += id
            if (repository.item(id)?.watched == false) repository.setWatched(id, true)
        }
    }
}

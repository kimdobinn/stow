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
import dev.stow.android.sync.YtDlp
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

    /** The video whose stream is being looked up (a few seconds), if any. */
    private val _resolving = MutableStateFlow<String?>(null)
    val resolving: StateFlow<String?> = _resolving.asStateFlow()

    /** Why the last stream couldn't start; cleared by the next play. */
    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()
    private var lastTick = 0L

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

    /**
     * Plays `items` (the downloaded ones) from `start`, resuming where you left off. A video
     * that isn't downloaded streams on its own.
     */
    fun play(items: List<VideoItem>, start: VideoItem) {
        val controller = _controller.value ?: return
        _error.value = null
        if (!start.isPlayable) return stream(start)
        _resolving.value = null
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

    /** Looks the stream up with yt-dlp, then plays video and audio straight from YouTube. */
    private fun stream(item: VideoItem) {
        val controller = _controller.value ?: return
        if (_current.value == item.id && controller.currentMediaItem?.mediaId == item.id) {
            controller.play()
            return
        }
        savePosition()
        controller.stop()
        controller.clearMediaItems()
        _current.value = item.id
        _queue.value = listOf(item.id)
        _resolving.value = item.id
        scope.launch {
            val cookies = if (item.video.isMembersOnly) repository.cookiesFile() else null
            try {
                val stream = YtDlp.stream(context, item.video, cookies)
                if (_resolving.value != item.id) return@launch
                val media = MediaItem.Builder()
                    .setMediaId(item.id)
                    .setUri(stream.videoUrl)
                    .setMediaMetadata(metadata(item))
                    .setRequestMetadata(MediaItem.RequestMetadata.Builder()
                        .setExtras(StreamSourceFactory.extras(stream.audioUrl, stream.headers)).build())
                    .build()
                controller.setMediaItem(media, item.local?.positionMs ?: 0)
                controller.prepare()
                controller.play()
            } catch (e: Exception) {
                if (_resolving.value == item.id) _error.value = "Couldn't stream this video. ${e.message.orEmpty()}".trim()
            } finally {
                cookies?.delete()
                if (_resolving.value == item.id) _resolving.value = null
            }
        }
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
        _resolving.value = null
        _error.value = null
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
        .setMediaMetadata(metadata(item))
        .build()

    private fun metadata(item: VideoItem) = MediaMetadata.Builder()
        .setTitle(item.video.title)
        .setArtist(item.video.channelTitle)
        .setArtworkUri(item.video.thumbnailUrl?.let(Uri::parse))
        .build()

    private fun savePosition() {
        val controller = _controller.value ?: return
        val id = controller.currentMediaItem?.mediaId ?: return
        repository.savePosition(id, controller.currentPosition, controller.duration.coerceAtLeast(0))
    }

    /** Wall-clock time actually spent watching, per channel, for the weekly report. */
    private fun countWatchTime(controller: MediaController, id: String) {
        val now = System.currentTimeMillis()
        val elapsed = if (lastTick == 0L) 0L else (now - lastTick).coerceAtMost(5_000)
        lastTick = now
        if (!controller.isPlaying || elapsed <= 0) return
        repository.item(id)?.video?.channelId?.takeIf { it.isNotEmpty() }?.let { repository.stats.addSeconds(it, elapsed / 1000) }
    }

    private fun track() {
        val controller = _controller.value ?: return
        val id = controller.currentMediaItem?.mediaId ?: return
        countWatchTime(controller, id)
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

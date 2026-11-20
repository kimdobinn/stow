package dev.stow.android.player

import android.content.Context
import android.os.Bundle
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.drm.DrmSessionManagerProvider
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import org.json.JSONObject

/**
 * Plays streamed videos: YouTube serves HD video and audio as separate files, so an item whose
 * extras carry [AUDIO_URL] plays both, merged. Downloaded files go to the default factory.
 */
@OptIn(UnstableApi::class)
class StreamSourceFactory(context: Context) : MediaSource.Factory {
    private val default = DefaultMediaSourceFactory(context)

    override fun createMediaSource(mediaItem: MediaItem): MediaSource {
        val extras = mediaItem.requestMetadata.extras
        if (extras?.getBoolean(STREAM) != true) return default.createMediaSource(mediaItem)
        val headers = extras.getString(HEADERS)?.let { json ->
            val o = JSONObject(json)
            o.keys().asSequence().associateWith { o.getString(it) }
        }.orEmpty()
        val http = DefaultHttpDataSource.Factory()
            .setDefaultRequestProperties(headers)
            .setUserAgent(headers["User-Agent"])
            .setAllowCrossProtocolRedirects(true)
        val progressive = ProgressiveMediaSource.Factory(http)
        // The video source keeps the original item, so the player reports its id and title.
        val video = progressive.createMediaSource(mediaItem)
        val audioUrl = extras.getString(AUDIO_URL) ?: return video
        return MergingMediaSource(video, progressive.createMediaSource(MediaItem.fromUri(audioUrl)))
    }

    override fun setDrmSessionManagerProvider(provider: DrmSessionManagerProvider) = apply { default.setDrmSessionManagerProvider(provider) }
    override fun setLoadErrorHandlingPolicy(policy: LoadErrorHandlingPolicy) = apply { default.setLoadErrorHandlingPolicy(policy) }
    override fun getSupportedTypes(): IntArray = intArrayOf(C.CONTENT_TYPE_OTHER)

    companion object {
        const val STREAM = "stow.stream"
        const val AUDIO_URL = "stow.audioUrl"
        const val HEADERS = "stow.headers"

        fun extras(audioUrl: String?, headers: Map<String, String>) = Bundle().apply {
            putBoolean(STREAM, true)
            audioUrl?.let { putString(AUDIO_URL, it) }
            putString(HEADERS, JSONObject(headers).toString())
        }
    }
}

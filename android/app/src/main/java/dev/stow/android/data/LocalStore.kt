package dev.stow.android.data

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Download state, files and playback positions per video, saved as JSON in app storage. */
class LocalStore(context: Context) {
    private val file = File(context.filesDir, "videos.json")
    private val _videos = MutableStateFlow(load())
    val videos: StateFlow<Map<String, LocalVideo>> = _videos.asStateFlow()

    operator fun get(id: String): LocalVideo? = _videos.value[id]

    fun update(id: String, change: (LocalVideo?) -> LocalVideo?) {
        _videos.update { videos ->
            val updated = change(videos[id])?.copy(updatedAt = System.currentTimeMillis())
            if (updated == null) videos - id else videos + (id to updated)
        }
        save()
    }

    fun clear() {
        _videos.value = emptyMap()
        save()
    }

    @Synchronized
    private fun save() {
        val array = JSONArray()
        for (video in _videos.value.values) {
            array.put(JSONObject().apply {
                put("id", video.id)
                put("state", video.state.name)
                put("progress", video.progress)
                put("error", video.error)
                put("filePath", video.filePath)
                put("sizeBytes", video.sizeBytes)
                put("durationMs", video.durationMs)
                put("positionMs", video.positionMs)
                put("sentAt", video.sentAt)
                put("downloadedAt", video.downloadedAt)
                put("updatedAt", video.updatedAt)
            })
        }
        val temp = File(file.parentFile, "videos.json.tmp")
        temp.writeText(array.toString())
        temp.renameTo(file)
    }

    private fun load(): Map<String, LocalVideo> {
        if (!file.exists()) return emptyMap()
        return runCatching {
            val array = JSONArray(file.readText())
            (0 until array.length()).map { array.getJSONObject(it) }.associate { o ->
                val id = o.getString("id")
                id to LocalVideo(
                    id = id,
                    state = runCatching { DownloadState.valueOf(o.getString("state")) }.getOrDefault(DownloadState.QUEUED),
                    progress = o.optInt("progress"),
                    error = o.optString("error").takeIf { o.has("error") && !o.isNull("error") },
                    filePath = o.optString("filePath").takeIf { o.has("filePath") && !o.isNull("filePath") },
                    sizeBytes = o.optLong("sizeBytes"),
                    durationMs = o.optLong("durationMs"),
                    positionMs = o.optLong("positionMs"),
                    sentAt = o.optLong("sentAt"),
                    downloadedAt = o.optLong("downloadedAt"),
                    updatedAt = o.optLong("updatedAt"),
                )
            }
        }.getOrDefault(emptyMap())
    }
}

package dev.stow.android.data

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/** Your playlists, saved as JSON on the phone. */
class PlaylistStore(context: Context) {
    private val file = File(context.filesDir, "playlists.json")
    private val _playlists = MutableStateFlow(load())
    /** Newest first. */
    val playlists: StateFlow<List<Playlist>> = _playlists.asStateFlow()

    fun create(name: String, firstVideo: String? = null): Playlist {
        val playlist = Playlist(UUID.randomUUID().toString(), name.trim().ifEmpty { "Playlist" }, listOfNotNull(firstVideo), System.currentTimeMillis())
        change { listOf(playlist) + it }
        return playlist
    }

    fun rename(id: String, name: String) = edit(id) { it.copy(name = name.trim().ifEmpty { it.name }) }
    fun delete(id: String) = change { list -> list.filter { it.id != id } }
    fun add(id: String, videoId: String) = edit(id) { if (videoId in it.videoIds) it else it.copy(videoIds = it.videoIds + videoId) }
    fun remove(id: String, videoId: String) = edit(id) { it.copy(videoIds = it.videoIds - videoId) }

    /** Moves a video one place up (-1) or down (+1). */
    fun move(id: String, videoId: String, by: Int) = edit(id) { playlist ->
        val ids = playlist.videoIds.toMutableList()
        val from = ids.indexOf(videoId)
        val to = (from + by).coerceIn(0, ids.lastIndex)
        if (from < 0 || from == to) playlist else playlist.copy(videoIds = ids.apply { add(to, removeAt(from)) })
    }

    private fun edit(id: String, transform: (Playlist) -> Playlist) = change { list -> list.map { if (it.id == id) transform(it) else it } }

    private fun change(transform: (List<Playlist>) -> List<Playlist>) {
        _playlists.update(transform)
        save()
    }

    @Synchronized
    private fun save() {
        val array = JSONArray()
        for (playlist in _playlists.value) {
            array.put(JSONObject().apply {
                put("id", playlist.id)
                put("name", playlist.name)
                put("videoIds", JSONArray(playlist.videoIds))
                put("createdAt", playlist.createdAt)
            })
        }
        val temp = File(file.parentFile, "playlists.json.tmp")
        temp.writeText(array.toString())
        temp.renameTo(file)
    }

    private fun load(): List<Playlist> = runCatching {
        val array = JSONArray(file.readText())
        (0 until array.length()).map { array.getJSONObject(it) }.map { o ->
            val ids = o.getJSONArray("videoIds")
            Playlist(o.getString("id"), o.getString("name"), (0 until ids.length()).map(ids::getString), o.optLong("createdAt"))
        }
    }.getOrDefault(emptyList())
}

package dev.stow.android.remote

import org.json.JSONArray
import org.json.JSONObject

/** Where the Mac's alarm run is. Only "stop" and "setVolume" work while preparing or sounding. */
enum class AlarmPhase(val wire: String) {
    PREPARING("preparing"), STARTING("starting"), PLAYING("playing"), ALARM_SOUND("alarmSound"), ENDED("ended");

    /** The video controls apply (the Mac answers 409 to them otherwise). */
    val hasPlayer: Boolean get() = this == STARTING || this == PLAYING

    companion object {
        fun from(wire: String?): AlarmPhase = entries.firstOrNull { it.wire == wire } ?: STARTING
    }
}

data class AlarmVideo(
    val id: String,
    val title: String,
    val channelTitle: String,
    val thumbnailUrl: String?,
    val publishedAt: String? = null,
)

/** GET /v1/state, also the answer to every action. */
data class AlarmState(
    val active: Boolean,
    val phase: AlarmPhase,
    val macName: String,
    val index: Int,
    val count: Int,
    val video: AlarmVideo?,
    val isLoading: Boolean,
    val isPaused: Boolean,
    val position: Double,
    val duration: Double?,
    /** The alarm speaker's volume, 0–100; null when the Mac can't read it. */
    val volume: Int?,
    val outputName: String?,
    val isMuted: Boolean,
    val playlist: List<AlarmVideo>,
) {
    val finished: Boolean get() = !active || phase == AlarmPhase.ENDED

    companion object {
        fun parse(json: JSONObject) = AlarmState(
            active = json.optBoolean("active", false),
            phase = AlarmPhase.from(json.text("phase")),
            macName = json.text("macName") ?: "the Mac",
            index = json.optInt("index", 0),
            count = json.optInt("count", 0),
            video = json.optJSONObject("video")?.let(::video),
            isLoading = json.optBoolean("isLoading", false),
            isPaused = json.optBoolean("isPaused", false),
            position = json.optDouble("position", 0.0).takeUnless { it.isNaN() } ?: 0.0,
            duration = if (json.isNull("duration")) null else json.optDouble("duration").takeUnless { it.isNaN() },
            volume = if (json.isNull("volume")) null else json.optInt("volume"),
            outputName = json.text("outputName"),
            isMuted = json.optBoolean("isMuted", false),
            playlist = videos(json.optJSONArray("playlist")),
        )

        /** Without blanks or repeats: the list is keyed by id. */
        fun choices(json: JSONObject): List<AlarmVideo> =
            videos(json.optJSONArray("videos")).filter { it.id.isNotEmpty() }.distinctBy { it.id }

        private fun videos(array: JSONArray?): List<AlarmVideo> =
            (0 until (array?.length() ?: 0)).mapNotNull { array?.optJSONObject(it)?.let(::video) }

        private fun video(json: JSONObject) = AlarmVideo(
            id = json.text("id").orEmpty(),
            title = json.text("title").orEmpty(),
            channelTitle = json.text("channelTitle").orEmpty(),
            thumbnailUrl = json.text("thumbnailURL"),
            publishedAt = json.text("publishedAt"),
        )

        /** org.json turns JSON null into the string "null"; this keeps it null. */
        private fun JSONObject.text(name: String): String? = if (isNull(name)) null else optString(name)
    }
}

package dev.stow.android.standalone

import dev.stow.android.data.ChannelGroup
import dev.stow.android.data.GroupChannel
import dev.stow.android.data.Video
import dev.stow.android.data.VideoJson
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** A channel this phone follows. */
data class FollowedChannel(val id: String, val title: String, val handle: String? = null, val avatarUrl: String? = null, val addedAt: Long = 0)

/** A channel's video as last read from its feeds, with when Stow first saw it. */
data class RecentEntry(val video: Video, val foundAt: Long)

/** YouTube's Home and Subscriptions as last read with the phone's sign-in. */
data class StoredFeeds(
    val recommended: List<Video> = emptyList(),
    val subscriptions: List<Video> = emptyList(),
    val channelAvatars: Map<String, String> = emptyMap(),
    val loadedAt: Long = 0,
)

/** The phone's YouTube sign-in, without its cookies (those stay in the vault). `source` is "web" or "file". */
data class AccountInfo(
    val state: AccountState = AccountState.SIGNED_OUT,
    val since: Long = 0,
    val source: String? = null,
    val lastProbeAt: Long = 0,
)

/** How the last check went. */
data class CheckRecord(
    val trigger: String, val startedAt: Long, val finishedAt: Long, val channelsChecked: Int, val errors: List<String>,
    /** Most channels couldn't be reached (no network): the check doesn't make the next one wait. */
    val offline: Boolean = false,
)

/** Everything standalone mode keeps (`files/standalone.json`). Dates are epoch milliseconds. */
data class StandaloneState(
    val channels: List<FollowedChannel> = emptyList(),
    val fetchedAt: Map<String, FetchedAt> = emptyMap(),
    val recentVideos: Map<String, List<RecentEntry>> = emptyMap(),
    val groups: List<ChannelGroup> = emptyList(),
    val memberAccess: Map<String, MemberAccess> = emptyMap(),
    val nonMemberChannels: Map<String, Long> = emptyMap(),
    val noMembersPlaylist: Map<String, Long> = emptyMap(),
    val accountFeeds: StoredFeeds? = null,
    val channelAvatars: Map<String, String> = emptyMap(),
    val account: AccountInfo = AccountInfo(),
    val syncWatchedWithYouTube: Boolean = true,
    val youTubeHistory: List<String> = emptyList(),
    val pendingYouTubeWatched: List<String> = emptyList(),
    val lastWatchSync: Long = 0,
    val lastCheck: CheckRecord? = null,
    val lastPullAt: Long = 0,
    val failedCheckStreak: Int = 0,
    val backoffUntil: Long = 0,
    val backoffMinutes: Int = 0,
    val channelErrors: Map<String, String> = emptyMap(),
    /** Keys a newer version wrote, kept as they were. */
    val unknown: Map<String, Any?> = emptyMap(),
) {
    fun isFollowed(id: String) = channels.any { it.id == id }
}

/** Loads and saves standalone.json atomically (temp file, then rename). */
class StandaloneStore(private val file: File) {
    fun load(): StandaloneState {
        if (!file.exists()) return StandaloneState()
        return runCatching { StandaloneJson.decode(file.readText()) }.getOrElse {
            Logs.w("standalone.json can't be read; starting over", it)
            StandaloneState()
        }
    }

    @Synchronized
    fun save(state: StandaloneState) {
        file.parentFile?.mkdirs()
        val temp = File(file.parentFile, "${file.name}.tmp")
        temp.writeText(StandaloneJson.encode(state))
        if (!temp.renameTo(file)) {
            file.delete()
            temp.renameTo(file)
        }
    }

    fun delete() {
        file.delete()
    }

    val exists: Boolean get() = file.exists()
}

/** standalone.json's schema (version 1), the same on both phones. */
object StandaloneJson {
    const val VERSION = 1
    private val KNOWN = setOf("version", "channels", "fetchedAt", "recentVideos", "groups", "memberAccess", "nonMemberChannels",
                              "noMembersPlaylist", "accountFeeds", "channelAvatars", "account", "syncWatchedWithYouTube",
                              "youTubeHistory", "pendingYouTubeWatched", "lastWatchSync", "lastCheck", "lastPullAt",
                              "failedCheckStreak", "backoffUntil", "backoffMinutes", "channelErrors")

    fun encode(s: StandaloneState): String {
        val root = JSONObject()
        for ((key, value) in s.unknown) root.put(key, value ?: JSONObject.NULL)
        root.put("version", VERSION)
        root.put("channels", JSONArray().apply {
            s.channels.forEach { c ->
                put(JSONObject().put("id", c.id).put("title", c.title).put("handle", c.handle ?: JSONObject.NULL)
                        .put("avatarURL", c.avatarUrl ?: JSONObject.NULL).put("addedAt", c.addedAt))
            }
        })
        root.put("fetchedAt", JSONObject().apply {
            s.fetchedAt.forEach { (id, f) -> put(id, JSONObject().put("uploads", f.uploads).put("streams", f.streams).put("members", f.members)) }
        })
        root.put("recentVideos", JSONObject().apply {
            s.recentVideos.forEach { (id, list) ->
                put(id, JSONArray().apply { list.forEach { put(VideoJson.encode(it.video).put("foundAt", it.foundAt)) } })
            }
        })
        root.put("groups", JSONArray().apply {
            s.groups.forEach { g ->
                put(JSONObject().put("id", g.id).put("name", g.name).put("channels", JSONArray().apply {
                    g.channels.forEach { put(JSONObject().put("id", it.id).put("title", it.title)) }
                }))
            }
        })
        root.put("memberAccess", JSONObject().apply { s.memberAccess.forEach { (id, a) -> put(id, a.stored) } })
        root.put("nonMemberChannels", longs(s.nonMemberChannels))
        root.put("noMembersPlaylist", longs(s.noMembersPlaylist))
        root.put("accountFeeds", s.accountFeeds?.let { f ->
            JSONObject().put("recommended", videos(f.recommended)).put("subscriptions", videos(f.subscriptions))
                .put("channelAvatars", strings(f.channelAvatars)).put("loadedAt", f.loadedAt)
        } ?: JSONObject.NULL)
        root.put("channelAvatars", strings(s.channelAvatars))
        root.put("account", JSONObject().put("state", s.account.state.key).put("since", s.account.since)
            .put("source", s.account.source ?: JSONObject.NULL).put("lastProbeAt", s.account.lastProbeAt))
        root.put("syncWatchedWithYouTube", s.syncWatchedWithYouTube)
        root.put("youTubeHistory", JSONArray(s.youTubeHistory))
        root.put("pendingYouTubeWatched", JSONArray(s.pendingYouTubeWatched))
        root.put("lastWatchSync", s.lastWatchSync)
        root.put("lastCheck", s.lastCheck?.let { c ->
            JSONObject().put("trigger", c.trigger).put("startedAt", c.startedAt).put("finishedAt", c.finishedAt)
                .put("channelsChecked", c.channelsChecked).put("errors", JSONArray(c.errors))
                .apply { if (c.offline) put("offline", true) }
        } ?: JSONObject.NULL)
        root.put("lastPullAt", s.lastPullAt)
        root.put("failedCheckStreak", s.failedCheckStreak)
        root.put("backoffUntil", s.backoffUntil)
        root.put("backoffMinutes", s.backoffMinutes)
        root.put("channelErrors", strings(s.channelErrors))
        return root.toString()
    }

    fun decode(text: String): StandaloneState {
        val root = JSONObject(text)
        fun obj(key: String) = root.optJSONObject(key)
        return StandaloneState(
            channels = list(root.optJSONArray("channels")) { o ->
                val id = o.optString("id").takeIf { it.isNotEmpty() } ?: return@list null
                FollowedChannel(id, o.optString("title").ifEmpty { id }, opt(o, "handle"), opt(o, "avatarURL"), o.optLong("addedAt"))
            },
            fetchedAt = map(obj("fetchedAt")) { o, key ->
                o.optJSONObject(key)?.let { FetchedAt(it.optLong("uploads"), it.optLong("streams"), it.optLong("members")) }
            },
            recentVideos = map(obj("recentVideos")) { o, key ->
                list(o.optJSONArray(key)) { v -> VideoJson.decode(v)?.let { RecentEntry(it, v.optLong("foundAt")) } }
            },
            groups = list(root.optJSONArray("groups")) { g ->
                val id = g.optString("id").takeIf { it.isNotEmpty() } ?: return@list null
                ChannelGroup(id, g.optString("name"), list(g.optJSONArray("channels")) { c ->
                    c.optString("id").takeIf { it.isNotEmpty() }?.let { GroupChannel(it, c.optString("title")) }
                })
            },
            memberAccess = map(obj("memberAccess")) { o, key -> MemberAccess.parse(o.optString(key)) },
            nonMemberChannels = longMap(obj("nonMemberChannels")),
            noMembersPlaylist = longMap(obj("noMembersPlaylist")),
            accountFeeds = obj("accountFeeds")?.let { f ->
                StoredFeeds(videoList(f.optJSONArray("recommended")), videoList(f.optJSONArray("subscriptions")),
                            stringMap(f.optJSONObject("channelAvatars")), f.optLong("loadedAt"))
            },
            channelAvatars = stringMap(obj("channelAvatars")),
            account = obj("account")?.let { a ->
                AccountInfo(AccountState.of(opt(a, "state")), a.optLong("since"), opt(a, "source"), a.optLong("lastProbeAt"))
            } ?: AccountInfo(),
            syncWatchedWithYouTube = root.optBoolean("syncWatchedWithYouTube", true),
            youTubeHistory = stringList(root.optJSONArray("youTubeHistory")),
            pendingYouTubeWatched = stringList(root.optJSONArray("pendingYouTubeWatched")),
            lastWatchSync = root.optLong("lastWatchSync"),
            lastCheck = obj("lastCheck")?.let { c ->
                CheckRecord(c.optString("trigger"), c.optLong("startedAt"), c.optLong("finishedAt"), c.optInt("channelsChecked"),
                            stringList(c.optJSONArray("errors")), c.optBoolean("offline"))
            },
            lastPullAt = root.optLong("lastPullAt"),
            failedCheckStreak = root.optInt("failedCheckStreak"),
            backoffUntil = root.optLong("backoffUntil"),
            backoffMinutes = root.optInt("backoffMinutes"),
            channelErrors = stringMap(obj("channelErrors")),
            unknown = root.keys().asSequence().filter { it !in KNOWN }.associateWith { root.opt(it) },
        )
    }

    private fun opt(o: JSONObject, key: String): String? = o.optString(key).takeIf { o.has(key) && !o.isNull(key) && it.isNotEmpty() }
    private fun <T> list(array: JSONArray?, item: (JSONObject) -> T?): List<T> =
        if (array == null) emptyList() else (0 until array.length()).mapNotNull { array.optJSONObject(it)?.let(item) }
    private fun <T> map(o: JSONObject?, value: (JSONObject, String) -> T?): Map<String, T> =
        o?.keys()?.asSequence()?.mapNotNull { key -> value(o, key)?.let { key to it } }?.toMap().orEmpty()
    private fun longMap(o: JSONObject?) = map(o) { obj, key -> obj.optLong(key) }
    private fun stringMap(o: JSONObject?) = map(o) { obj, key -> opt(obj, key) }
    private fun stringList(array: JSONArray?) =
        if (array == null) emptyList() else (0 until array.length()).mapNotNull { array.optString(it).takeIf { s -> s.isNotEmpty() } }
    private fun videoList(array: JSONArray?) = list(array) { VideoJson.decode(it) }
    private fun videos(list: List<Video>) = JSONArray().apply { list.forEach { put(VideoJson.encode(it)) } }
    private fun longs(map: Map<String, Long>) = JSONObject().apply { map.forEach { (k, v) -> put(k, v) } }
    private fun strings(map: Map<String, String>) = JSONObject().apply { map.forEach { (k, v) -> put(k, v) } }
}

package dev.stow.android.data

import android.content.Context
import android.os.Build
import android.provider.Settings
import android.util.Log
import dev.stow.android.sync.Downloads
import dev.stow.android.sync.YtDlp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import dev.stow.android.sync.SyncWorker
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.io.File

sealed interface PairState {
    data class Unpaired(val message: String? = null) : PairState
    data object Pairing : PairState
    data object Paired : PairState
}

/** The app's state: pairing, the Mac's channels and sent videos, and what this phone downloaded. */
class Repository(private val context: Context) {
    val prefs = Prefs(context)
    val local = LocalStore(context)
    val remote = Remote()
    val playlistStore = PlaylistStore(context)
    val stats = WatchStats(context)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var observing: Job? = null

    private val _pairState = MutableStateFlow<PairState>(
        if (prefs.pairedProject != null && remote.uid != null) PairState.Paired else PairState.Unpaired()
    )
    val pairState: StateFlow<PairState> = _pairState.asStateFlow()

    private val sent = MutableStateFlow<List<SentVideo>>(emptyList())
    private val _channels = MutableStateFlow<List<Channel>>(emptyList())
    /** In the Mac's order. */
    val channels: StateFlow<List<Channel>> = _channels.asStateFlow()
    val playlists: StateFlow<List<Playlist>> get() = playlistStore.playlists
    private val _youtubeFeeds = MutableStateFlow(YouTubeFeeds())
    /** YouTube's own Home and Subscriptions, shared by the Mac. */
    val youtubeFeeds: StateFlow<YouTubeFeeds> = _youtubeFeeds.asStateFlow()

    private val _shared = MutableStateFlow(Remote.Shared(emptyList(), null, null))
    /** Your channel groups, shared with the Mac. */
    val groups: StateFlow<List<ChannelGroup>> = _shared.map { it.groups }.stateIn(scope, SharingStarted.Eagerly, emptyList())

    /** Videos found by searching YouTube on the phone, newest search last (this run of the app only). */
    private val searched = MutableStateFlow<Map<String, Video>>(emptyMap())
    private val youtubeVideos = combine(_youtubeFeeds, searched) { feeds, searched -> feeds to searched }

    /**
     * Every known video (sent to the phone, recent on a channel, in YouTube's feeds or found by a
     * search), by id. No Shorts.
     */
    val items: StateFlow<Map<String, VideoItem>> = combine(sent, _channels, local.videos, prefs.watchedHere, youtubeVideos) { sent, channels, local, watchedHere, (feeds, searched) ->
        val result = LinkedHashMap<String, VideoItem>()
        for (video in feeds.recommended + feeds.subscriptions) {
            if (video.id in result) continue
            result[video.id] = VideoItem(video, null, local[video.id], video.id in watchedHere, onlyInYouTubeFeeds = true)
        }
        for (video in searched.values) {
            if (video.id in result) continue
            result[video.id] = VideoItem(video, null, local[video.id], video.id in watchedHere, onlyInYouTubeFeeds = true, fromSearch = true)
        }
        // YouTube's feeds know the length of videos the Mac's channel list doesn't.
        fun Video.withFeedDuration() = if (durationSeconds == null) copy(durationSeconds = result[id]?.video?.durationSeconds) else this
        for (channel in channels) {
            for (recent in channel.recent) {
                result[recent.video.id] = VideoItem(recent.video.withFeedDuration(), null, local[recent.video.id], recent.watched || recent.video.id in watchedHere)
            }
        }
        for (video in sent) {
            val watchedOnMac = result[video.video.id]?.watchedOnMac ?: false
            result[video.video.id] = VideoItem(video.video.withFeedDuration(), video, local[video.video.id], watchedOnMac)
        }
        result.values.removeAll { it.video.isShort && it.local?.state != DownloadState.DOWNLOADED }
        result
    }.stateIn(scope, SharingStarted.Eagerly, emptyMap())

    val isPaired: Boolean get() = _pairState.value == PairState.Paired

    /** Debug builds: `files/demo` shows sample channels instead of Firebase (downloads stay real). */
    val demo = dev.stow.android.BuildConfig.DEBUG && File(context.filesDir, "demo").exists()

    fun start() {
        if (demo) {
            _pairState.value = PairState.Paired
            _channels.value = DemoData.channels
            _youtubeFeeds.value = DemoData.youtubeFeeds
            onSentVideos(DemoData.sent)
            return
        }
        if (isPaired) observe()
    }

    fun item(id: String): VideoItem? = items.value[id]
    fun channel(id: String): Channel? = _channels.value.firstOrNull { it.id == id }

    // Pairing

    /** Pairs with the Mac from the QR code's text (stow://pair?…). */
    fun pair(qrText: String) {
        val invite = remote.parseInvite(qrText)
        if (invite == null) {
            _pairState.value = PairState.Unpaired("That isn't a Stow pairing code. Open Stow › Phone › Pair a Phone on the Mac.")
            return
        }
        if (_pairState.value == PairState.Pairing) return
        _pairState.value = PairState.Pairing
        scope.launch {
            try {
                remote.pair(invite, deviceName())
                prefs.savePairing(invite.projectId, invite.key)
                _pairState.value = PairState.Paired
                observe()
            } catch (e: Exception) {
                Log.w(TAG, "Pairing failed", e)
                _pairState.value = PairState.Unpaired(e.message ?: "Pairing failed.")
            }
        }
    }

    /** Forgets the pairing on this phone. Downloads stay until deleted. */
    fun unpair(message: String? = null) {
        observing?.cancel()
        observing = null
        prefs.clearPairing()
        remote.signOut()
        sent.value = emptyList()
        _channels.value = emptyList()
        _youtubeFeeds.value = YouTubeFeeds()
        _shared.value = Remote.Shared(emptyList(), null, null)
        _pairState.value = PairState.Unpaired(message)
    }

    private fun deviceName(): String =
        Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() }
            ?: "${Build.MANUFACTURER} ${Build.MODEL}"

    fun onNewPushToken(token: String) {
        if (!isPaired) return
        scope.launch { runCatching { remote.updatePushToken(token) }.onFailure { Log.w(TAG, "Token update failed", it) } }
    }

    // Sync

    private fun observe() {
        if (observing?.isActive == true) return
        observing = scope.launch {
            // The token can change or arrive late (Play services was busy while pairing).
            launch { runCatching { remote.refreshPushToken() }.onFailure { Log.w(TAG, "Token refresh failed", it) } }
            launch { listen { remote.channels().collect { _channels.value = it } } }
            launch { listen { remote.accountFeeds().collect { _youtubeFeeds.value = openFeeds(it) } } }
            launch { listen { remote.shared().collect { _shared.value = it } } }
            listen { remote.videos().collect { onSentVideos(it) } }
        }
    }

    /** Keeps a listener alive across network trouble; stops when the Mac unpaired this phone. */
    private suspend fun listen(block: suspend () -> Unit) {
        while (true) {
            try {
                block()
                return
            } catch (e: Remote.NotPaired) {
                // A listener can also be refused briefly; ask the server before giving up.
                if (runCatching { remote.isMember() }.getOrDefault(true)) {
                    delay(10_000)
                } else {
                    unpair("The Mac unpaired this phone.")
                    return
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "Listener failed; retrying", e)
                delay(15_000)
            }
        }
    }

    private fun openFeeds(sealed: String?): YouTubeFeeds {
        val key = prefs.pairingKey ?: return YouTubeFeeds()
        if (sealed == null) return YouTubeFeeds()
        return runCatching {
            YouTubeFeeds.parse(String(Crypto.open(android.util.Base64.decode(sealed, android.util.Base64.DEFAULT), key)))
        }.onFailure { Log.w(TAG, "Couldn't open YouTube's feeds", it) }.getOrDefault(YouTubeFeeds())
    }

    /** New videos get downloaded; ones sent again after a failure or delete are retried. */
    fun onSentVideos(videos: List<SentVideo>) {
        sent.value = videos
        for (video in videos) {
            val id = video.video.id
            val sentAt = video.sentAt?.time ?: 0
            val existing = local[id]
            when {
                existing == null -> queue(id, sentAt)
                existing.state in setOf(DownloadState.FAILED, DownloadState.DELETED) && sentAt > existing.sentAt -> queue(id, sentAt)
                existing.state == DownloadState.QUEUED || existing.state == DownloadState.DOWNLOADING ->
                    Downloads.enqueue(context, id, prefs.wifiOnly.value)
                existing.state == DownloadState.DOWNLOADED && existing.filePath?.let { File(it).exists() } != true ->
                    queue(id, sentAt)
            }
        }
    }

    /** Searches all of YouTube; the results join [items] (so they play and download like any video). Returns their ids. */
    suspend fun searchYouTube(query: String): List<String> {
        val videos = YouTubeSearch.parse(YtDlp.search(context, query, SEARCH_RESULTS))
        prefs.addRecentSearch(query)
        searched.value = LinkedHashMap(searched.value).apply {
            videos.forEach { remove(it.id); put(it.id, it) }
            // Keep the latest few searches' videos, not every one since the app started.
            while (size > SEARCH_KEEP) remove(keys.first())
        }
        return videos.map { it.id }
    }

    /** The video to download, from what's loaded or (in a background job) from the server. */
    suspend fun findVideo(id: String): Video? =
        items.value[id]?.video ?: remote.fetchVideos().firstOrNull { it.video.id == id }?.video

    private fun queue(id: String, sentAt: Long) {
        local.update(id) {
            LocalVideo(id = id, state = DownloadState.QUEUED, sentAt = sentAt, positionMs = it?.positionMs ?: 0,
                       durationMs = it?.durationMs ?: 0)
        }
        Downloads.enqueue(context, id, prefs.wifiOnly.value)
    }

    // Actions

    /** Downloads any video: retries a sent one, or asks for one picked from a channel page. */
    fun download(item: VideoItem) {
        if (item.isPlayable || item.isDownloading) return
        val sentAt = item.sent?.sentAt?.time ?: System.currentTimeMillis()
        queue(item.id, sentAt)
        if (demo) {
            sent.value = sent.value + SentVideo(item.video, java.util.Date(), "phone", false)
            return
        }
        if (item.sent == null) {
            scope.launch { runCatching { remote.requestDownload(item.video) }.onFailure { Log.w(TAG, "requestDownload failed", it) } }
        }
    }

    fun setWatched(id: String, watched: Boolean) {
        val item = item(id)
        if (watched && item?.watched == false) item.video.channelId.takeIf { it.isNotEmpty() }?.let(stats::addFinished)
        if (item?.sent == null) {
            // Streamed without ever being sent: remember it here only.
            prefs.setWatchedHere(id, watched)
            return
        }
        if (demo) {
            sent.value = sent.value.map { if (it.video.id == id) it.copy(watched = watched) else it }
            return
        }
        scope.launch { runCatching { remote.setWatched(id, watched) }.onFailure { Log.w(TAG, "setWatched failed", it) } }
    }

    fun savePosition(id: String, positionMs: Long, durationMs: Long) {
        local.update(id) { it?.copy(positionMs = positionMs, durationMs = if (durationMs > 0) durationMs else it.durationMs) }
    }

    fun retry(id: String) {
        queue(id, local[id]?.sentAt ?: 0)
    }

    fun deleteDownload(id: String) {
        Downloads.cancel(context, id)
        local[id]?.filePath?.let { File(it).delete() }
        YtDlp.deleteFiles(context, id)
        local.update(id) { it?.copy(state = DownloadState.DELETED, filePath = null, sizeBytes = 0, progress = 0, error = null) }
        if (item(id)?.sent != null) scope.launch { runCatching { remote.reportDownload(id, "deleted") } }
    }

    /** Videos downloaded, downloading or waiting to download. */
    fun downloadIds(): List<String> = items.value.values
        .filter { it.state == DownloadState.QUEUED || it.state == DownloadState.DOWNLOADING || it.state == DownloadState.DOWNLOADED }
        .map { it.id }

    /** Deletes every download, stops the ones under way, and clears out anything left in the folder. */
    fun deleteAllDownloads() {
        downloadIds().forEach(::deleteDownload)
        YtDlp.downloadDir(context).listFiles()?.forEach { it.deleteRecursively() }
    }

    /** The YouTube cookies (members-only videos) as a temporary cookies.txt; the caller deletes it. */
    suspend fun cookiesFile(): File? {
        val key = prefs.pairingKey ?: return null
        val data = runCatching { remote.cookies(key) }.onFailure { Log.w(TAG, "No cookies", it) }.getOrNull() ?: return null
        return File(context.cacheDir, "cookies-${java.util.UUID.randomUUID()}.txt").apply { writeBytes(data) }
    }

    // Comments

    private val commentsDir get() = File(context.filesDir, "comments")

    /**
     * The video's top comments: the saved copy unless `fresh` (downloaded videos keep theirs, to
     * read offline), else fetched with yt-dlp and saved.
     */
    suspend fun comments(video: Video, fresh: Boolean = false): CommentsPage = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
        val file = File(commentsDir, "${video.id}.json")
        if (!fresh) runCatching { Comments.parse(file.readText()) }.getOrNull()?.let { return@withContext it }
        val cookies = if (video.isMembersOnly) cookiesFile() else null
        try {
            val json = YtDlp.comments(context, video.id, cookies)
            commentsDir.mkdirs()
            file.writeText(json)
            pruneComments()
            Comments.parse(json)
        } finally {
            cookies?.delete()
        }
    }

    /** Saved comments of videos that aren't downloaded go after a week. */
    private fun pruneComments() {
        val keep = downloadIds().toSet()
        val cutoff = System.currentTimeMillis() - 7 * 24 * 60 * 60 * 1000L
        commentsDir.listFiles()?.filter { it.nameWithoutExtension !in keep && it.lastModified() < cutoff }?.forEach { it.delete() }
    }

    // Pull to refresh

    enum class RefreshResult { DONE, NO_ANSWER, FAILED }

    /** Asks the Mac to check every channel and YouTube's feeds now, and waits for it (up to 2 minutes). */
    suspend fun refreshFromMac(): RefreshResult {
        SyncWorker.runNow(context)
        if (demo) {
            delay(800)
            return RefreshResult.DONE
        }
        val requested = try {
            remote.requestRefresh()
        } catch (e: Exception) {
            Log.w(TAG, "Refresh request failed", e)
            return RefreshResult.FAILED
        }
        val answered = kotlinx.coroutines.withTimeoutOrNull(REFRESH_TIMEOUT_MS) {
            // The Mac answers with the request's time (to the millisecond).
            _shared.first { (it.refreshHandledAt?.time ?: 0) >= requested.time - 1_000 }
        }
        return if (answered != null) RefreshResult.DONE else RefreshResult.NO_ANSWER
    }

    // Channel groups

    private fun editGroups(change: (List<ChannelGroup>) -> List<ChannelGroup>) {
        val shared = _shared.value
        _shared.value = shared.copy(groups = change(shared.groups))
        if (demo) return
        scope.launch {
            runCatching { remote.editGroups(change) }.onFailure { Log.w(TAG, "Saving groups failed", it) }
        }
    }

    fun createGroup(name: String, with: GroupChannel? = null): ChannelGroup {
        val group = ChannelGroup(java.util.UUID.randomUUID().toString(), name.trim(), listOfNotNull(with))
        editGroups { it + group }
        return group
    }

    fun renameGroup(id: String, name: String) = editGroups { groups -> groups.map { if (it.id == id) it.copy(name = name.trim()) else it } }

    fun deleteGroup(id: String) = editGroups { groups -> groups.filterNot { it.id == id } }

    fun setInGroup(groupId: String, channel: GroupChannel, included: Boolean) = editGroups { groups ->
        groups.map { group ->
            if (group.id != groupId) group
            else group.copy(channels = group.channels.filterNot { it.id == channel.id } + listOfNotNull(channel.takeIf { included }))
        }
    }

    fun moveGroup(id: String, by: Int) = editGroups { groups ->
        val from = groups.indexOfFirst { it.id == id }
        val to = from + by
        if (from < 0 || to !in groups.indices) groups
        else groups.toMutableList().apply { add(to, removeAt(from)) }
    }

    // Playlists

    /** Adding a video that isn't downloaded yet downloads it. */
    fun addToPlaylist(playlistId: String, item: VideoItem) {
        playlistStore.add(playlistId, item.id)
        download(item)
    }

    fun createPlaylist(name: String, with: VideoItem? = null): Playlist {
        val playlist = playlistStore.create(name, with?.id)
        with?.let(::download)
        return playlist
    }

    /** Re-queues waiting downloads under the new network rule. */
    fun setWifiOnly(on: Boolean) {
        prefs.setWifiOnly(on)
        local.videos.value.values.filter { it.state == DownloadState.QUEUED }.forEach {
            Downloads.enqueue(context, it.id, on, replace = true)
        }
    }

    fun storageUsedBytes(): Long = YtDlp.downloadDir(context).walkTopDown().filter { it.isFile }.sumOf { it.length() }

    companion object {
        const val TAG = "Stow"
        const val REFRESH_TIMEOUT_MS = 120_000L
        const val SEARCH_RESULTS = 40
        const val SEARCH_KEEP = 400
    }
}

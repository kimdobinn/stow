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
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import java.io.File
import dev.stow.android.BuildConfig
import dev.stow.android.account.AccountNotification
import dev.stow.android.account.CookieVault
import dev.stow.android.standalone.AccountState
import dev.stow.android.standalone.AppMode
import dev.stow.android.standalone.ChannelInfo
import dev.stow.android.standalone.CheckWorker
import dev.stow.android.standalone.ModeSwitch
import dev.stow.android.standalone.Standalone
import dev.stow.android.standalone.StandaloneStore
import dev.stow.android.standalone.Trigger
import dev.stow.android.standalone.YouTubeWeb
import dev.stow.android.standalone.YtDlpTool
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

sealed interface PairState {
    data class Unpaired(val message: String? = null) : PairState
    data object Pairing : PairState
    data object Paired : PairState
}

/**
 * The app's state: the mode, pairing, the channels and videos (the Mac's, or this phone's own in
 * standalone mode) and what this phone downloaded.
 */
class Repository(private val context: Context) {
    val prefs = Prefs(context)
    val local = LocalStore(context)
    val playlistStore = PlaylistStore(context)
    val stats = WatchStats(context)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var observing: Job? = null

    /** Debug builds: `files/demo` shows sample channels instead of Firebase (downloads stay real). */
    val demo = BuildConfig.DEBUG && File(context.filesDir, "demo").exists()

    private val _mode = MutableStateFlow(initialMode())
    /** With the Mac, on its own, or not chosen yet. Worked out from the preferences alone (never Firebase). */
    val mode: StateFlow<AppMode> = _mode.asStateFlow()
    val isStandalone: Boolean get() = _mode.value == AppMode.STANDALONE
    private val era = dev.stow.android.standalone.ModeEra()
    /** Bumped on every mode change: Mac-mode work started in one era stops at the next ([stillPaired]). */
    val modeEra: Int get() = era.value

    /** Still paired, in the Mac mode `era` was read in: Firebase work started then may go on. */
    fun stillPaired(era: Int): Boolean = this.era.isCurrent(era) && isPaired

    private fun initialMode(): AppMode {
        if (demo) return AppMode.MAC
        val stored = prefs.appMode
        val resolved = AppMode.resolve(stored, prefs.pairedProject != null)
        if (AppMode.needsStoring(stored, resolved)) prefs.appMode = resolved.stored
        return resolved
    }

    private val remoteInstance = lazy { Remote() }
    /** Firebase: only ever created in Mac mode (debug builds stop anything else from touching it). */
    val remote: Remote
        get() {
            if (BuildConfig.DEBUG && _mode.value != AppMode.MAC) {
                Log.e(TAG, "FIREBASE TOUCHED in standalone")
                throw IllegalStateException("Firebase used while the app isn't in Mac mode (${_mode.value})")
            }
            return remoteInstance.value
        }

    private val _pairState = MutableStateFlow<PairState>(
        if (_mode.value == AppMode.MAC && prefs.pairedProject != null && remote.uid != null) PairState.Paired else PairState.Unpaired()
    )
    val pairState: StateFlow<PairState> = _pairState.asStateFlow()

    /** The YouTube cookies standalone mode signs in with (encrypted; the only copy). */
    val vault = CookieVault(context)

    /** Standalone mode's engine (idle in Mac mode). */
    val standalone = Standalone(
        StandaloneStore(File(context.filesDir, "standalone.json")), vault, YouTubeWeb(), YtDlpTool(context, prefs),
        object : Standalone.Host {
            override fun watchedHere() = prefs.watchedHere.value
            override fun addWatchedHere(ids: Collection<String>) = prefs.addWatchedHere(ids)
            override fun downloadedIds() = local.videos.value.filterValues { it.state == DownloadState.DOWNLOADED }.keys
            override fun onSignedOutByYouTube() {
                prefs.setExpiredBannerDismissed(false)
                AccountNotification.show(context)
            }
            override fun clearWebData() = dev.stow.android.ui.SignInWeb.clearAll()
        },
        scope,
    )
    private var standaloneJob: Job? = null

    private val _messages = MutableSharedFlow<String>(extraBufferCapacity = 8)
    /** Short confirmations from the Repository itself ("Following … too"), shown as snackbars. */
    val messages: SharedFlow<String> = _messages.asSharedFlow()

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
    private val youtubeVideos = combine(_youtubeFeeds, searched, _mode) { feeds, searched, mode -> Triple(feeds, searched, mode) }

    /**
     * Every known video (sent to the phone, recent on a channel, in YouTube's feeds or found by a
     * search), by id. No Shorts.
     */
    val items: StateFlow<Map<String, VideoItem>> = combine(sent, _channels, local.videos, prefs.watchedHere, youtubeVideos) { sent, channels, local, watchedHere, (feeds, searched, mode) ->
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
        // Downloads nothing else mentions (standalone, or their channel was removed) stay listed.
        // Standalone: so do older ones that don't know what they are yet, until they're looked up.
        for (download in local.values) {
            if (download.state == DownloadState.DELETED || download.id in result) continue
            val video = download.video ?: DownloadBackfill.placeholder(download.id).takeIf { mode == AppMode.STANDALONE } ?: continue
            result[download.id] = VideoItem(video, null, download, download.id in watchedHere, onlyInYouTubeFeeds = true, fromSearch = true)
        }
        result.values.removeAll { it.video.isShort && it.local?.state != DownloadState.DOWNLOADED }
        result
    }.stateIn(scope, SharingStarted.Eagerly, emptyMap())

    val isPaired: Boolean get() = _pairState.value == PairState.Paired && _mode.value == AppMode.MAC

    init {
        // Downloads made before 0.9.0 don't carry their video: take it from whatever lists it
        // (the Mac's sent videos and channels, feeds, searches), so they stay listed without the Mac.
        scope.launch { items.collect { all -> backfillDownloads(all.values.map { it.video }) } }
    }

    private fun backfillDownloads(known: Iterable<Video>) {
        local.fillVideos(DownloadBackfill.fill(local.videos.value, known))
    }

    private var recovering: Job? = null

    /**
     * Standalone: downloads that nothing describes (made before 0.9.0 and no longer sent) are
     * looked up on YouTube, one at a time, until one fails to be reached. Until then they show as
     * "Downloaded video".
     */
    private fun recoverOrphanDownloads() {
        if (recovering?.isActive == true) return
        recovering = scope.launch(Dispatchers.IO) {
            val listed = (standalone.channels.value.flatMap { c -> c.recent.map { it.video.id } } +
                          standalone.youtubeFeeds.value.let { f -> (f.recommended + f.subscriptions).map { it.id } }).toSet()
            for (id in DownloadBackfill.orphans(local.videos.value, listed)) {
                if (_mode.value != AppMode.STANDALONE) return@launch
                val video = try {
                    YouTubeListing.video(YtDlp.videoInfo(context, id))
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (e: Exception) {
                    val message = e.message.orEmpty()
                    Log.w(TAG, "Couldn't look up download $id: ${message.lineSequence().firstOrNull()}")
                    // Offline: try the rest next time. Gone from YouTube: it keeps its plain title.
                    if (dev.stow.android.standalone.YouTubeFailure.classify(message) == dev.stow.android.standalone.YouTubeFailure.Kind.NETWORK) return@launch
                    null
                } ?: continue
                local.fillVideos(mapOf(id to video))
                Log.i(TAG, "Download $id is ${video.title}")
            }
        }
    }

    fun start() {
        if (demo) {
            if (File(context.filesDir, "standalone").exists()) Log.w(TAG, "files/standalone ignored: demo mode wins")
            _pairState.value = PairState.Paired
            _channels.value = DemoData.channels
            _youtubeFeeds.value = DemoData.youtubeFeeds
            onSentVideos(DemoData.sent)
            return
        }
        applyDebugModeFiles()
        when (_mode.value) {
            AppMode.MAC -> if (isPaired) {
                // Paired installs fetch and refresh their push token as before (it's off by default in the manifest).
                runCatching { com.google.firebase.messaging.FirebaseMessaging.getInstance().isAutoInitEnabled = true }
                observe()
            }
            AppMode.STANDALONE -> startStandalone()
            AppMode.CHOOSING -> {}
        }
    }

    // Modes

    /** Welcome › Use with my Mac: the pair screen. */
    fun chooseMac() {
        setMode(AppMode.MAC)
        _pairState.value = PairState.Unpaired()
    }

    /** Welcome › Use on its own, or the pair screen's "Use on its own instead" (nothing to copy). */
    fun chooseStandalone() {
        if (_mode.value == AppMode.STANDALONE) return
        // Unpaired earlier (here or by the Mac), or a code scanned: FCM may still be told to keep a token.
        stopPushes(always = false)
        SyncWorker.stopNow(context)
        prefs.clearAlarm()
        setMode(AppMode.STANDALONE)
        startStandalone()
        scope.launch { standalone.checkIfDue(Trigger.LAUNCH) }
    }

    /**
     * Settings › Mac › Use on its own: keeps the Mac's channels and groups here (`keepChannels`),
     * its watched videos as watched here, unpairs as Unpair does, stops the Mac's pushes and checks.
     * The Mac's YouTube sign-in isn't carried over (a second IP risks YouTube rotating it).
     */
    fun switchToStandalone(keepChannels: Boolean) {
        // Older downloads learn what they are from the Mac's lists before those go with the pairing.
        backfillDownloads(ModeSwitch.macVideos(sent.value, _channels.value) + _youtubeFeeds.value.let { it.recommended + it.subscriptions })
        standalone.load()
        if (keepChannels) standalone.adoptMac(_channels.value, _shared.value.groups)
        prefs.addWatchedHere(ModeSwitch.macWatched(sent.value, _channels.value))
        unpair()
        SyncWorker.stopNow(context)
        // The last Firebase call this install makes: the Mac's pushes stop waking the phone.
        stopPushes(always = true)
        prefs.clearAlarm()
        prefs.setSignInPrompt(true)
        setMode(AppMode.STANDALONE)
        startStandalone(load = false)
        scope.launch {
            standalone.flush()
            // The Mac's channels count as read just now; the others (from an earlier standalone
            // stay) are checked when due, like at launch, instead of every channel at once.
            standalone.checkIfDue(Trigger.LAUNCH)
        }
    }

    /**
     * Settings › Mac › Use with my Mac (or a pairing link): signs out of YouTube here and stops the
     * checks. The channels, groups and check state stay in standalone.json for coming back.
     */
    fun switchToMac() {
        if (_mode.value != AppMode.STANDALONE) return chooseMac()
        stopStandalone()
        standalone.signOut()
        scope.launch { standalone.flush() }
        prefs.setSignInPrompt(false)
        _channels.value = emptyList()
        _youtubeFeeds.value = YouTubeFeeds()
        _shared.value = Remote.Shared(emptyList(), null, null)
        setMode(AppMode.MAC)
        _pairState.value = PairState.Unpaired()
    }

    /**
     * FCM saves "auto-init on" in its own preferences, over the manifest's off: once set (paired,
     * or a code scanned), every start would fetch and refresh a token against the Mac's project.
     * Leaving Mac mode turns it off and deletes the token (best effort). Unless `always`, nothing
     * happens (no Firebase call at all) when FCM was never turned on.
     */
    private fun stopPushes(always: Boolean) {
        if (!always && !fcmAutoInitOn()) return
        runCatching {
            val messaging = com.google.firebase.messaging.FirebaseMessaging.getInstance()
            messaging.isAutoInitEnabled = false
            messaging.deleteToken()
        }.onFailure { Log.w(TAG, "Couldn't delete the push token", it) }
    }

    /** FCM's own saved auto-init flag, read without starting Firebase. */
    private fun fcmAutoInitOn(): Boolean =
        context.getSharedPreferences(FCM_PREFS, Context.MODE_PRIVATE).getBoolean(FCM_AUTO_INIT, false)

    private fun setMode(mode: AppMode) {
        era.change(_mode.value, mode)
        prefs.appMode = mode.stored
        _mode.value = mode
    }

    private fun startStandalone(load: Boolean = true) {
        if (load) standalone.load()
        standaloneJob?.cancel()
        standaloneJob = scope.launch {
            launch { standalone.channels.collect { _channels.value = it } }
            launch { standalone.youtubeFeeds.collect { _youtubeFeeds.value = it } }
            launch { standalone.groups.collect { _shared.value = Remote.Shared(it, null, null) } }
        }
        CheckWorker.schedule(context)
        applyDebugStandaloneFiles()
        recoverOrphanDownloads()
    }

    private fun stopStandalone() {
        standaloneJob?.cancel()
        standaloneJob = null
        CheckWorker.cancel(context)
    }

    /** Debug builds: files in filesDir that set the mode at start (see android/README.md). */
    private fun applyDebugModeFiles() {
        if (!BuildConfig.DEBUG) return
        val dir = context.filesDir
        val paired = prefs.pairedProject != null
        File(dir, "standalone-reset").takeIf { it.exists() }?.let {
            it.delete()
            File(dir, "standalone.json").delete()
            runCatching { vault.save(null) }
            File(dir, "youtube").deleteRecursively()
            Log.i(TAG, "Debug: standalone.json and the YouTube sign-in deleted")
        }
        File(dir, "choose-mode").takeIf { it.exists() }?.let {
            it.delete()
            if (paired) Log.w(TAG, "files/choose-mode ignored: paired") else {
                prefs.appMode = null
                _mode.value = AppMode.CHOOSING
            }
        }
        if (File(dir, "standalone").exists() && _mode.value != AppMode.STANDALONE) {
            if (paired) Log.w(TAG, "files/standalone ignored: paired") else setMode(AppMode.STANDALONE)
        }
    }

    /** Debug builds, in standalone: `files/debug-cookies.txt` (imported unverified, then deleted) and `files/standalone-channels`. */
    private fun applyDebugStandaloneFiles() {
        if (!BuildConfig.DEBUG) return
        val cookies = File(context.filesDir, "debug-cookies.txt").takeIf { it.exists() }?.let { file ->
            runCatching { file.readText() }.getOrNull().also { file.delete() }
        }
        val channels = File(context.filesDir, "standalone-channels").takeIf { it.exists() }?.let { file ->
            runCatching { file.readLines() }.getOrNull().orEmpty().map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith("#") }
                .also { file.delete() }
        }
        if (cookies == null && channels == null) return
        scope.launch {
            cookies?.let { Log.i(TAG, "Debug cookies: ${standalone.signIn(it, Standalone.SOURCE_FILE, verify = false)}") }
            for (reference in channels.orEmpty()) {
                runCatching { standalone.addChannel(reference) }
                    .onSuccess { Log.i(TAG, "Debug: following ${it.title}") }
                    .onFailure { Log.w(TAG, "Debug: couldn't follow $reference: ${it.message}") }
            }
        }
    }

    // Standalone: channels

    /** Follows a channel from its page or a video's menu (standalone). */
    fun follow(id: String, title: String, avatarUrl: String? = null, handle: String? = null) {
        if (id.isEmpty()) return
        if (standalone.follow(ChannelInfo(id, title, handle, avatarUrl))) _messages.tryEmit("Following $title")
    }

    fun unfollow(id: String) {
        standalone.unfollow(id)?.let { _messages.tryEmit("Removed $it") }
    }

    fun item(id: String): VideoItem? = items.value[id]
    fun channel(id: String): Channel? = _channels.value.firstOrNull { it.id == id }

    // Pairing

    /** Pairs with the Mac from the QR code's text (stow://pair?…). From standalone, ask first (it switches to Mac mode). */
    fun pair(qrText: String) {
        when (_mode.value) {
            AppMode.STANDALONE -> switchToMac()
            AppMode.CHOOSING -> chooseMac()
            AppMode.MAC -> {}
        }
        val invite = remote.parseInvite(qrText)
        if (invite == null) {
            _pairState.value = PairState.Unpaired("That isn't a Stow pairing code. Open Stow › Phone › Pair a Phone on the Mac.")
            return
        }
        if (_pairState.value == PairState.Pairing) return
        // Pushes reach a paired phone: the token comes with the pairing (only for a real code).
        runCatching { com.google.firebase.messaging.FirebaseMessaging.getInstance().isAutoInitEnabled = true }
        _pairState.value = PairState.Pairing
        val pairingEra = modeEra
        scope.launch {
            try {
                remote.pair(invite, deviceName())
                // Switched to standalone while pairing: that pairing isn't wanted any more.
                if (!era.isCurrent(pairingEra) || _mode.value != AppMode.MAC) {
                    Log.i(TAG, "Pairing finished after leaving Mac mode; not kept")
                    _pairState.value = PairState.Unpaired()
                    return@launch
                }
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
        launchForMac("Token update") { remote.updatePushToken(token) }
    }

    // Sync

    private fun observe() {
        if (observing?.isActive == true) return
        val era = modeEra
        observing = scope.launch {
            // The token can change or arrive late (Play services was busy while pairing).
            launch { if (stillPaired(era)) runCatching { remote.refreshPushToken() }.onFailure { Log.w(TAG, "Token refresh failed", it) } }
            // Unpairing cancels these; a value already on its way when the mode changed is dropped.
            launch { listen(era) { remote.channels().collect { if (stillPaired(era)) _channels.value = it } } }
            launch { listen(era) { remote.accountFeeds().collect { if (stillPaired(era)) _youtubeFeeds.value = openFeeds(it) } } }
            launch { listen(era) { remote.shared().collect { if (stillPaired(era)) _shared.value = it } } }
            listen(era) { remote.videos().collect { if (stillPaired(era)) onSentVideos(it) } }
        }
    }

    /**
     * Keeps a listener alive across network trouble; stops when the Mac unpaired this phone, and
     * for good once the mode or pairing it started in is over (no Firebase call after that).
     */
    private suspend fun listen(era: Int, block: suspend () -> Unit) {
        while (stillPaired(era)) {
            try {
                block()
                return
            } catch (e: Remote.NotPaired) {
                if (!stillPaired(era)) return
                // A listener can also be refused briefly; ask the server before giving up.
                if (runCatching { remote.isMember() }.getOrDefault(true)) {
                    delay(10_000)
                } else {
                    if (stillPaired(era)) unpair("The Mac unpaired this phone.")
                    return
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                if (!stillPaired(era)) return
                Log.w(TAG, "Listener failed; retrying", e)
                delay(15_000)
            }
        }
    }

    /** Firebase work for the pairing it was asked in: skipped when the mode changed (or the phone was unpaired) before it ran. */
    private fun launchForMac(what: String, block: suspend () -> Unit) {
        val era = modeEra
        scope.launch {
            if (!stillPaired(era)) return@launch
            runCatching { block() }.onFailure { Log.w(TAG, "$what failed", it) }
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
                existing == null -> queue(id, sentAt, video.video)
                existing.state in setOf(DownloadState.FAILED, DownloadState.DELETED) && sentAt > existing.sentAt -> queue(id, sentAt, video.video)
                existing.state == DownloadState.QUEUED || existing.state == DownloadState.DOWNLOADING ->
                    Downloads.enqueue(context, id, prefs.wifiOnly.value)
                existing.state == DownloadState.DOWNLOADED && existing.filePath?.let { File(it).exists() } != true ->
                    queue(id, sentAt, video.video)
            }
        }
    }

    /** Searches all of YouTube; the results join [items] (so they play and download like any video). Returns their ids. */
    suspend fun searchYouTube(query: String): List<String> {
        val videos = YouTubeListing.parse(YtDlp.search(context, query, SEARCH_RESULTS))
        prefs.addRecentSearch(query)
        addFound(videos)
        return videos.map { it.id }
    }

    /** Videos from searches and channel pages, for [items]. */
    private fun addFound(videos: List<Video>) {
        searched.value = LinkedHashMap(searched.value).apply {
            videos.forEach { remove(it.id); put(it.id, it) }
            // Keep the latest few lists' videos, not every one since the app started.
            while (size > SEARCH_KEEP) remove(keys.first())
        }
    }

    private val _channelPages = MutableStateFlow<Map<String, ChannelPage>>(emptyMap())
    /** Channel pages loaded on the phone (this run of the app), by channel id. */
    val channelPages: StateFlow<Map<String, ChannelPage>> = _channelPages.asStateFlow()

    /**
     * Loads a channel's latest uploads and past streams from YouTube; they join [items] like
     * search results. Skipped when loaded in the last half hour.
     */
    suspend fun loadChannelPage(channelId: String) {
        val known = _channelPages.value[channelId]
        if (known != null && System.currentTimeMillis() - known.loadedAt < CHANNEL_PAGE_FRESH_MS) return
        val (uploadsJson, streamsJson) = kotlinx.coroutines.coroutineScope {
            val uploads = async { YtDlp.channelTab(context, channelId, "videos", CHANNEL_PAGE_VIDEOS) }
            val streams = async { runCatching { YtDlp.channelTab(context, channelId, "streams", CHANNEL_PAGE_STREAMS) }.getOrNull() }
            uploads.await() to streams.await()
        }
        val uploads = YouTubeListing.parse(uploadsJson)
        val streams = streamsJson?.let(YouTubeListing::parse).orEmpty().filter { it.isPastStream }
        addFound(uploads + streams)
        val page = ChannelPage(YouTubeListing.channelTitle(uploadsJson).orEmpty(), YouTubeListing.channelAvatar(uploadsJson),
                               uploads.map { it.id }, streams.map { it.id }, System.currentTimeMillis(), YouTubeListing.channelHandle(uploadsJson))
        _channelPages.value = _channelPages.value + (channelId to page)
    }

    /** The video to download: what's loaded, the download's own copy, or (paired, in a background job) the server's. */
    suspend fun findVideo(id: String): Video? =
        items.value[id]?.video ?: local[id]?.video ?: if (isPaired) remote.fetchVideos().firstOrNull { it.video.id == id }?.video else null

    private fun queue(id: String, sentAt: Long, video: Video? = null) {
        local.update(id) {
            LocalVideo(id = id, state = DownloadState.QUEUED, sentAt = sentAt, positionMs = it?.positionMs ?: 0,
                       durationMs = it?.durationMs ?: 0, video = video ?: it?.video ?: items.value[id]?.video)
        }
        Downloads.enqueue(context, id, prefs.wifiOnly.value)
    }

    /** Tells the Mac how a download went (paired only). */
    suspend fun reportDownload(id: String, state: String, error: String? = null) {
        if (!isPaired || demo) return
        runCatching { remote.reportDownload(id, state, error) }
    }

    // Actions

    /** Downloads any video: retries a sent one, or asks for one picked from a channel page. */
    fun download(item: VideoItem) {
        if (item.isPlayable || item.isDownloading) return
        val sentAt = item.sent?.sentAt?.time ?: System.currentTimeMillis()
        queue(item.id, sentAt, item.video)
        // Standalone: the phone downloads it itself; nothing to tell anyone.
        if (_mode.value != AppMode.MAC) return
        if (demo) {
            sent.value = sent.value + SentVideo(item.video, java.util.Date(), "phone", false)
            return
        }
        if (item.sent == null) launchForMac("requestDownload") { remote.requestDownload(item.video) }
    }

    fun setWatched(id: String, watched: Boolean) {
        val item = item(id)
        if (watched && item?.watched == false) item.video.channelId.takeIf { it.isNotEmpty() }?.let(stats::addFinished)
        if (_mode.value == AppMode.STANDALONE) {
            // The one place watched state lives; it also goes to YouTube's history when synced.
            prefs.setWatchedHere(id, watched)
            standalone.onWatched(id, watched)
            return
        }
        if (item?.sent == null) {
            // Streamed without ever being sent: remember it here only.
            prefs.setWatchedHere(id, watched)
            return
        }
        if (demo) {
            sent.value = sent.value.map { if (it.video.id == id) it.copy(watched = watched) else it }
            return
        }
        launchForMac("setWatched") { remote.setWatched(id, watched) }
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
        if (item(id)?.sent != null && isPaired) launchForMac("reportDownload") { remote.reportDownload(id, "deleted") }
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

    /**
     * The YouTube cookies (members-only videos) as a temporary cookies.txt; the caller deletes it.
     * Standalone: this phone's own sign-in. Mac mode: the Mac's, from Firebase.
     */
    suspend fun cookiesFile(): File? {
        when (_mode.value) {
            AppMode.STANDALONE -> return standalone.cookies()?.let { YtDlpTool.writeCookies(context, it) }
            AppMode.CHOOSING -> return null
            AppMode.MAC -> {}
        }
        if (!isPaired && !demo) return null
        val key = prefs.pairingKey ?: return null
        val data = runCatching { remote.cookies(key) }.onFailure { Log.w(TAG, "No cookies", it) }.getOrNull() ?: return null
        return YtDlpTool.writeCookies(context, String(data, Charsets.UTF_8))
    }

    /** Standalone: whether YouTube's sign-in works (members-only downloads), for the error a failed one shows. */
    val youTubeAccount: AccountState get() = standalone.account.value.state

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

    enum class RefreshResult { DONE, NO_ANSWER, FAILED, YOUTUBE_FAILED, SLOWED_DOWN }

    /** Pull to refresh: standalone checks the channels here; Mac mode asks the Mac. */
    suspend fun refresh(): RefreshResult = when (_mode.value) {
        AppMode.STANDALONE -> when (standalone.refresh()) {
            Standalone.Outcome.DONE, Standalone.Outcome.NOT_DUE -> RefreshResult.DONE
            Standalone.Outcome.NETWORK -> RefreshResult.YOUTUBE_FAILED
            Standalone.Outcome.SLOWED_DOWN -> RefreshResult.SLOWED_DOWN
        }
        AppMode.MAC -> refreshFromMac()
        AppMode.CHOOSING -> RefreshResult.DONE
    }

    /** Asks the Mac to check every channel and YouTube's feeds now, and waits for it (up to 2 minutes). */
    suspend fun refreshFromMac(): RefreshResult {
        if (demo) {
            SyncWorker.runNow(context)
            delay(800)
            return RefreshResult.DONE
        }
        // Unpaired, or switched to standalone, while this waited: the pull is over (no Firebase after that).
        val era = modeEra
        if (!stillPaired(era)) return RefreshResult.FAILED
        SyncWorker.runNow(context)
        val requested = try {
            remote.requestRefresh()
        } catch (e: Exception) {
            Log.w(TAG, "Refresh request failed", e)
            return RefreshResult.FAILED
        }
        // `_mode` and `_pairState` are in it so a switch ends the wait at once.
        val changes = combine(_shared, _mode, _pairState) { shared, _, _ -> shared }
        return when (MacPull.await(changes, requested.time, REFRESH_TIMEOUT_MS) { stillPaired(era) }) {
            MacPull.Answer.ANSWERED -> RefreshResult.DONE
            MacPull.Answer.NO_ANSWER -> RefreshResult.NO_ANSWER
            MacPull.Answer.STOPPED -> RefreshResult.FAILED
        }
    }

    // Channel groups

    private fun editGroups(change: (List<ChannelGroup>) -> List<ChannelGroup>) {
        if (_mode.value == AppMode.STANDALONE) {
            // Kept on the phone; a channel put in a group that isn't followed gets followed (the Mac's rule).
            val before = standalone.state.value.groups
            val followed = standalone.editGroupsLocally(change)
            if (before != standalone.groups.value) _shared.value = Remote.Shared(standalone.groups.value, null, null)
            followed.forEach { _messages.tryEmit("Following ${it.title} too") }
            return
        }
        val shared = _shared.value
        _shared.value = shared.copy(groups = change(shared.groups))
        if (demo) return
        launchForMac("Saving groups") { remote.editGroups(change) }
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
        const val CHANNEL_PAGE_VIDEOS = 30
        const val CHANNEL_PAGE_STREAMS = 15
        const val CHANNEL_PAGE_FRESH_MS = 30 * 60 * 1000L
        /** Where FCM keeps its auto-init flag (firebase-messaging's own SharedPreferences). */
        private const val FCM_PREFS = "com.google.firebase.messaging"
        private const val FCM_AUTO_INIT = "auto_init"
    }
}

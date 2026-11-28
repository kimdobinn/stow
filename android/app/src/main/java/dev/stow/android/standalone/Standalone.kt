package dev.stow.android.standalone

import dev.stow.android.account.NetscapeCookies
import dev.stow.android.account.SecretStore
import dev.stow.android.data.Channel
import dev.stow.android.data.ChannelGroup
import dev.stow.android.data.GroupChannel
import dev.stow.android.data.RecentVideo
import dev.stow.android.data.Video
import dev.stow.android.data.YouTubeFeeds
import dev.stow.android.data.YouTubeListing
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Standalone mode's engine: the Mac's jobs on the phone. It follows channels, checks them for new
 * videos (RSS, plus yt-dlp for streams and members-only), reads YouTube's Home and Subscriptions
 * with the phone's own sign-in, and syncs watched videos with YouTube's history. No Firebase:
 * everything is in standalone.json and the cookie vault. Plain Kotlin (the Android parts come in
 * through [Host], [YouTubeTool], [WebClient] and [SecretStore]), so it's tested on the JVM.
 */
class Standalone(
    private val store: StandaloneStore,
    private val vault: SecretStore,
    private val web: WebClient,
    private val tool: YouTubeTool,
    private val host: Host,
    private val scope: CoroutineScope,
    private val clock: () -> Long = System::currentTimeMillis,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) {
    /** What the engine needs from the rest of the app. */
    interface Host {
        /** Videos watched on this phone (`prefs.watchedHere`). */
        fun watchedHere(): Set<String>
        fun addWatchedHere(ids: Collection<String>)
        /** Videos downloaded on this phone (for the watch history). */
        fun downloadedIds(): Set<String>
        /** YouTube no longer accepts the sign-in: once per expiry (notification, banner). */
        fun onSignedOutByYouTube()
        /** Deletes whatever the sign-in web view left (cookies, storage). */
        fun clearWebData()
    }

    data class CheckStatus(
        val isChecking: Boolean = false,
        val lastCheck: CheckRecord? = null,
        val channelErrors: Map<String, String> = emptyMap(),
        val backoffUntil: Long = 0,
        val failedCheckStreak: Int = 0,
        val channelCount: Int = 0,
        /**
         * When the followed channels were last read: the last check, or a later seed (a channel
         * just added) or the Mac's channels just adopted. 0 = never.
         */
        val lastReadAt: Long = 0,
    )

    /** How a check went, for pull-to-refresh. */
    enum class Outcome { DONE, NETWORK, SLOWED_DOWN, NOT_DUE }

    sealed interface SignInResult {
        data object Done : SignInResult
        data class Failed(val message: String) : SignInResult
    }

    private val checker = ChannelChecker(web, tool)
    private val resolver = ChannelResolver(web, tool)
    private val lock = Any()

    private val _state = MutableStateFlow(StandaloneState())
    val state: StateFlow<StandaloneState> = _state.asStateFlow()
    private val _channels = MutableStateFlow<List<Channel>>(emptyList())
    /** The followed channels as the screens show them, in order, with their visible recent videos. */
    val channels: StateFlow<List<Channel>> = _channels.asStateFlow()
    private val _youtubeFeeds = MutableStateFlow(YouTubeFeeds())
    val youtubeFeeds: StateFlow<YouTubeFeeds> = _youtubeFeeds.asStateFlow()
    private val _groups = MutableStateFlow<List<ChannelGroup>>(emptyList())
    val groups: StateFlow<List<ChannelGroup>> = _groups.asStateFlow()
    private val _account = MutableStateFlow(AccountInfo())
    val account: StateFlow<AccountInfo> = _account.asStateFlow()
    private val _checkStatus = MutableStateFlow(CheckStatus())
    val checkStatus: StateFlow<CheckStatus> = _checkStatus.asStateFlow()
    private val _followedIds = MutableStateFlow<Set<String>>(emptySet())
    val followedIds: StateFlow<Set<String>> = _followedIds.asStateFlow()
    private val _watchSyncError = MutableStateFlow<String?>(null)
    val watchSyncError: StateFlow<String?> = _watchSyncError.asStateFlow()
    private val checking = AtomicInteger(0)

    /** Reads standalone.json (entering standalone mode, or at launch in it). */
    fun load() {
        val loaded = synchronized(lock) {
            _state.value = store.load()
            publish(_state.value)
            _state.value
        }
        deleteLeftoverSignIn(loaded)
    }

    /**
     * A sign-in nothing uses: standalone.json says signed out, yet files/youtube/ or its
     * AndroidKeyStore key is still there (a sign-out that didn't finish, standalone.json lost or
     * restored from an older backup). It goes, so no cookies sit on the phone unused.
     */
    private fun deleteLeftoverSignIn(s: StandaloneState) {
        if (s.account.state != AccountState.SIGNED_OUT) return
        val leftover = runCatching { vault.hasItem() }.getOrDefault(false)
        if (!leftover) return
        runCatching { vault.save(null) }
            .onSuccess { Logs.i("Deleted a YouTube sign-in left from before") }
            .onFailure { Logs.w("Couldn't delete a leftover YouTube sign-in", it) }
    }

    // State

    private fun edit(change: (StandaloneState) -> StandaloneState): StandaloneState {
        val updated = synchronized(lock) {
            val next = change(_state.value)
            if (next === _state.value) return next
            _state.value = next
            publish(next)
            next
        }
        requestSave()
        return updated
    }

    private fun publish(s: StandaloneState) {
        _channels.value = s.channels.mapIndexed { index, c ->
            val recent = Merge.visible(s.recentVideos[c.id].orEmpty().map { it.video }, s.memberAccess).map { RecentVideo(it, false) }
            Channel(c.id, c.title, c.handle, c.avatarUrl, index, recent)
        }
        _youtubeFeeds.value = s.accountFeeds?.let { f ->
            val avatars = HashMap<String, String>()
            for (v in f.recommended + f.subscriptions) {
                if (v.channelId.isEmpty() || v.channelId in avatars) continue
                (s.channels.firstOrNull { it.id == v.channelId }?.avatarUrl ?: f.channelAvatars[v.channelId] ?: s.channelAvatars[v.channelId])
                    ?.let { avatars[v.channelId] = it }
            }
            YouTubeFeeds(Merge.visible(f.recommended, s.memberAccess), Merge.visible(f.subscriptions, s.memberAccess), avatars)
        } ?: YouTubeFeeds()
        _groups.value = s.groups
        _account.value = s.account
        _followedIds.value = s.channels.mapTo(HashSet()) { it.id }
        publishStatus(s)
    }

    private fun publishStatus(s: StandaloneState = _state.value) {
        val lastRead = maxOf(s.lastCheck?.takeUnless { it.offline }?.finishedAt ?: 0,
                             s.channels.maxOfOrNull { s.fetchedAt[it.id]?.uploads ?: 0 } ?: 0)
        _checkStatus.value = CheckStatus(checking.get() > 0, s.lastCheck, s.channelErrors, s.backoffUntil, s.failedCheckStreak, s.channels.size, lastRead)
    }

    private val saveLock = Mutex()
    private val dirty = AtomicBoolean(false)

    /** Saves in the background, coalescing bursts of edits. */
    private fun requestSave() {
        dirty.set(true)
        scope.launch(io) { flush() }
    }

    /** Writes standalone.json now if anything changed. */
    suspend fun flush() = saveLock.withLock {
        if (dirty.getAndSet(false)) runCatching { store.save(_state.value) }.onFailure { Logs.w("Saving standalone.json failed", it) }
    }

    // Checks

    private val runLock = Mutex()
    @Volatile private var running: Deferred<Outcome>? = null
    @Volatile private var runningTrigger: Trigger? = null
    @Volatile private var lastPull: Pair<Long, Outcome>? = null

    /** An automatic check (launch, back on screen, background) when one is due; otherwise joins the running one or does nothing. */
    suspend fun checkIfDue(trigger: Trigger): Outcome {
        running?.takeIf { it.isActive }?.let { return it.await() }
        val s = _state.value
        if (!CheckPlan.isDue(trigger, clock(), s.lastCheck, s.backoffUntil)) {
            Logs.i("Check (${trigger.key}): not due")
            return Outcome.NOT_DUE
        }
        return start(trigger, null).await()
    }

    /** Pull to refresh: waits for a check under way, then checks (ignoring backoff). A pull within a minute of the last one returns its result. */
    suspend fun refresh(): Outcome {
        val last = lastPull
        val lastAt = maxOf(last?.first ?: 0, _state.value.lastPullAt)
        val current = running?.takeIf { it.isActive }
        if (current != null && runningTrigger == Trigger.PULL) return current.await()
        if (current == null && clock() - lastAt < PULL_REUSE_MS) return last?.second ?: Outcome.DONE
        return start(Trigger.PULL, null).await()
    }

    /** A check now, due or not (after switching to standalone). */
    suspend fun checkNow(trigger: Trigger): Outcome {
        running?.takeIf { it.isActive }?.let { return it.await() }
        return start(trigger, null).await()
    }

    /** One check at a time: later ones wait their turn. `only` limits it to newly added channels (a seed). */
    private fun start(trigger: Trigger, only: Set<String>?): Deferred<Outcome> {
        val job = scope.async { runLock.withLock { perform(trigger, only) } }
        if (only == null) {
            running = job
            runningTrigger = trigger
        }
        return job
    }

    private suspend fun perform(trigger: Trigger, only: Set<String>?): Outcome {
        checking.incrementAndGet()
        publishStatus()
        try {
            return check(trigger, only)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Logs.w("Check (${trigger.key}) failed", e)
            return Outcome.NETWORK
        } finally {
            checking.decrementAndGet()
            publishStatus()
            flush()
        }
    }

    private suspend fun check(trigger: Trigger, only: Set<String>?): Outcome {
        val startedAt = clock()
        var cookies = cookiesForCheck()
        var s = _state.value
        fun input() = _state.value.let { st ->
            CheckPlan.Input(trigger, clock(), st.channels.map { it.id }.filter { only == null || it in only }, st.fetchedAt, st.account.state,
                            st.nonMemberChannels, st.noMembersPlaylist, st.accountFeeds?.loadedAt ?: 0, st.syncWatchedWithYouTube,
                            st.lastWatchSync, st.pendingYouTubeWatched.size, st.account.lastProbeAt)
        }
        var plan = CheckPlan.plan(input())
        if (plan.probe && cookies != null) {
            probe(cookies)
            plan = CheckPlan.plan(input())
        }
        if (_state.value.account.state != AccountState.SIGNED_IN) cookies = null
        s = _state.value
        val channels = plan.channels.keys.mapNotNull { id -> s.channels.firstOrNull { it.id == id } }

        val stop = AtomicBoolean(false)
        val permits = Semaphore(MAX_CONCURRENT_CHANNELS)
        val fetches = coroutineScope {
            channels.map { channel ->
                async {
                    permits.withPermit {
                        if (stop.get()) return@withPermit null
                        val feeds = plan.channels[channel.id].orEmpty()
                        val fetch = checker.fetch(channel, feeds, if (FeedKind.MEMBERS in feeds) cookies else null)
                        if (fetch.slowDown) stop.set(true)
                        apply(channel, fetch, feeds)
                        fetch
                    }
                }
            }.awaitAll().filterNotNull()
        }
        val errors = fetches.flatMap { it.errors }.toMutableList()
        if (fetches.any { it.authExpired }) markExpired()
        updateMembership()
        var slowDown = stop.get()

        if (!slowDown && cookies != null && _state.value.account.state == AccountState.SIGNED_IN) {
            if (plan.feeds) {
                try {
                    readFeeds(cookies)
                } catch (e: SlowDown) {
                    slowDown = true
                    errors += "YouTube's Home and Subscriptions: ${e.message}"
                } catch (e: SignedOutByYouTube) {
                    markExpired()
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    errors += "YouTube's Home and Subscriptions: ${e.message}"
                }
            }
            if (!slowDown && plan.accessChecks && _state.value.account.state == AccountState.SIGNED_IN) checkMemberAccess(cookies)
        }
        if (!slowDown && plan.history) syncWatched()

        val now = clock()
        val networkFailures = fetches.count { it.networkFailed }
        val offline = channels.isNotEmpty() && networkFailures * 2 > channels.size
        val record = CheckRecord(trigger.key, startedAt, now, channels.size, errors.toList(), offline)
        if (only == null) {
            edit { st ->
                val streak = if (errors.isEmpty()) 0 else st.failedCheckStreak + 1
                val backoffMinutes = when {
                    slowDown -> CheckPlan.nextBackoffMinutes(st.backoffMinutes)
                    errors.isEmpty() -> 0
                    else -> st.backoffMinutes
                }
                st.copy(
                    lastCheck = record,
                    failedCheckStreak = streak,
                    backoffMinutes = backoffMinutes,
                    backoffUntil = if (slowDown) now + backoffMinutes * CheckPlan.MINUTE else if (errors.isEmpty()) 0 else st.backoffUntil,
                    lastPullAt = if (trigger == Trigger.PULL) now else st.lastPullAt,
                )
            }
        } else if (slowDown) {
            // A seed covers only the new channels: it isn't "the last check", but YouTube slowing down still counts.
            edit { st ->
                val minutes = CheckPlan.nextBackoffMinutes(st.backoffMinutes)
                st.copy(backoffMinutes = minutes, backoffUntil = now + minutes * CheckPlan.MINUTE)
            }
        }
        Logs.i("Check (${trigger.key}): ${channels.size} channels, ${errors.size} errors, ${now - startedAt} ms")
        errors.forEach { Logs.w(it) }
        val outcome = when {
            slowDown -> Outcome.SLOWED_DOWN
            offline -> Outcome.NETWORK
            else -> Outcome.DONE
        }
        if (trigger == Trigger.PULL) lastPull = now to outcome
        return outcome
    }

    /** One channel's results into the state: recent videos, when each feed was read, errors. Dropped when the channel was removed meanwhile. */
    private fun apply(channel: FollowedChannel, fetch: ChannelFetch, asked: Set<FeedKind>) {
        val now = clock()
        var watchedAlready: List<String> = emptyList()
        edit { s ->
            val current = s.channels.firstOrNull { it.id == channel.id } ?: return@edit s
            val stored = s.recentVideos[channel.id].orEmpty()
            val fetched = fetch.sources.values.flatten()
            val storedIds = stored.mapTo(HashSet()) { it.video.id }
            // Watched on YouTube before Stow found it.
            val history = s.youTubeHistory.toHashSet()
            watchedAlready = fetched.map { it.id }.filter { it !in storedIds && it in history }
            var fetchedAt = s.fetchedAt[channel.id] ?: FetchedAt()
            for (kind in fetch.sources.keys) fetchedAt = fetchedAt.with(kind, now)
            if (fetch.noMembersPlaylist) fetchedAt = fetchedAt.with(FeedKind.MEMBERS, now)
            val errors = when {
                fetch.notFound -> s.channelErrors + (channel.id to "Channel not found")
                FeedKind.UPLOADS in asked && FeedKind.UPLOADS in fetch.sources -> s.channelErrors - channel.id
                else -> s.channelErrors
            }
            s.copy(
                recentVideos = if (fetched.isEmpty()) s.recentVideos else s.recentVideos + (channel.id to Merge.recent(stored, fetched, current, now, fetch.approximateDates)),
                fetchedAt = s.fetchedAt + (channel.id to fetchedAt),
                channelErrors = errors,
                noMembersPlaylist = if (fetch.noMembersPlaylist) s.noMembersPlaylist + (channel.id to now) else s.noMembersPlaylist,
            )
        }
        if (watchedAlready.isNotEmpty()) host.addWatchedHere(watchedAlready)
    }

    // YouTube's Home and Subscriptions

    private suspend fun readFeeds(cookies: String) {
        val (recommended, subscriptions) = coroutineScope {
            val rec = async { tool.flat(":ytrec", FEEDS_LIMIT, cookies) }
            val subs = async { tool.flat(":ytsubs", FEEDS_LIMIT, cookies) }
            rec.await() to subs.await()
        }.let { (rec, subs) ->
            if (rec.cookiesRejected || subs.cookiesRejected) throw SignedOutByYouTube()
            YouTubeListing.parse(rec.json).distinctBy { it.id } to YouTubeListing.parse(subs.json).distinctBy { it.id }
        }
        // A video without a date takes the one its channel's feed gave.
        val known = _state.value.recentVideos.values.flatten().associate { it.video.id to it.video.publishedAt }
        fun dated(list: List<Video>) = list.map { v -> if (v.publishedAt == null) v.copy(publishedAt = known[v.id]) else v }
        val rec = dated(recommended)
        val subs = dated(subscriptions)
        val avatars = lookUpAvatars(rec + subs)
        val now = clock()
        edit { s ->
            var cache = s.channelAvatars
            if (cache.size + avatars.size > AVATAR_CACHE) {
                val current = (rec + subs).mapTo(HashSet()) { it.channelId }
                cache = cache.filterKeys { it in current }
            }
            cache = cache + avatars
            val feedAvatars = (rec + subs).mapNotNull { v -> cache[v.channelId]?.let { v.channelId to it } }.toMap()
            s.copy(accountFeeds = StoredFeeds(rec, subs, feedAvatars, now), channelAvatars = cache)
        }
    }

    /** Pictures of channels in the feeds Stow doesn't know yet, from their pages: at most 20 per read, 3 at a time. */
    private suspend fun lookUpAvatars(videos: List<Video>): Map<String, String> {
        val s = _state.value
        val missing = videos.map { it.channelId }.filter { it.isNotEmpty() && !s.isFollowed(it) && it !in s.channelAvatars }
            .distinct().take(AVATAR_LOOKUPS)
        if (missing.isEmpty()) return emptyMap()
        val permits = Semaphore(3)
        return coroutineScope {
            missing.map { id ->
                async {
                    permits.withPermit {
                        runCatching { web.get(ChannelResolver.channelUrl(id)) }.getOrNull()
                            ?.takeIf { it.status == 200 }?.let { ChannelPageParser.parse(it.body)?.avatarUrl }?.let { id to it }
                    }
                }
            }.awaitAll().filterNotNull().toMap()
        }
    }

    // Members-only

    /** Which members-only videos the account's level can watch: at most 15 lookups per pass. */
    private suspend fun checkMemberAccess(cookies: String) {
        val s = _state.value
        val candidates = (s.recentVideos.values.flatten().map { it.video } + s.accountFeeds?.let { it.recommended + it.subscriptions }.orEmpty())
            .filter { it.isMembersOnly && s.memberAccess[it.id] == null }.map { it.id }.distinct().take(ACCESS_LOOKUPS)
        if (candidates.isEmpty()) return
        for (id in candidates) {
            if (_state.value.account.state != AccountState.SIGNED_IN) break
            val access = try {
                MemberAccess.fromLookup(tool.run(listOf("--no-warnings", "-J", "--skip-download", "--no-playlist", "--",
                                                        "https://www.youtube.com/watch?v=$id"), cookies).json)
            } catch (e: ToolFailure) {
                MemberAccess.fromError(e.stderr) ?: run {
                    if (e.kind == YouTubeFailure.Kind.AUTH) {
                        markExpired()
                        return
                    }
                    null
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                null
            } ?: continue
            edit { it.copy(memberAccess = it.memberAccess + (id to access)) }
        }
        updateMembership()
        // Forget videos that are gone everywhere.
        edit { st ->
            val known = st.recentVideos.values.flatten().mapTo(HashSet()) { it.video.id } +
                st.accountFeeds?.let { f -> (f.recommended + f.subscriptions).map { it.id } }.orEmpty()
            val kept = st.memberAccess.filterKeys { it in known }
            if (kept.size == st.memberAccess.size) st else st.copy(memberAccess = kept)
        }
    }

    /**
     * A channel whose checked members-only videos are all "join this channel" isn't one the account
     * is a member of: its members feeds wait a week. One watchable video makes it a member's again.
     */
    private fun updateMembership() {
        val now = clock()
        edit { s ->
            var nonMember = s.nonMemberChannels
            val members = s.recentVideos.values.flatten().map { it.video }.filter { it.isMembersOnly }.groupBy { it.channelId }
            for ((channelId, videos) in members) {
                val access = videos.mapNotNull { s.memberAccess[it.id] }
                if (MemberAccess.Watchable in access) {
                    nonMember = nonMember - channelId
                } else if (MemberAccess.Locked(null) in access) {
                    val at = nonMember[channelId]
                    if (at == null || now - at >= CheckPlan.MEMBERS_SKIP) nonMember = nonMember + (channelId to now)
                }
            }
            if (nonMember == s.nonMemberChannels) s else s.copy(nonMemberChannels = nonMember)
        }
    }

    // Watched

    private val syncLock = Mutex()

    /** Videos watched here go to YouTube (10 at a time, oldest first); YouTube's history comes back as watched here. */
    suspend fun syncWatched() {
        val s = _state.value
        if (!s.syncWatchedWithYouTube || s.account.state != AccountState.SIGNED_IN) return
        syncLock.withLock { runWatchSync() }
    }

    private suspend fun runWatchSync() {
        val cookies = vault.load() ?: return
        try {
            for (id in _state.value.pendingYouTubeWatched.take(WatchSync.PUSHES_PER_SYNC)) {
                try {
                    if (tool.markWatched(id, cookies).cookiesRejected) throw SignedOutByYouTube()
                } catch (e: ToolFailure) {
                    when (e.kind) {
                        YouTubeFailure.Kind.UNAVAILABLE -> Logs.w("Couldn't mark $id watched on YouTube: it's unavailable.")
                        YouTubeFailure.Kind.AUTH -> throw SignedOutByYouTube()
                        else -> throw e
                    }
                }
                edit { it.copy(pendingYouTubeWatched = it.pendingYouTubeWatched - id) }
            }
            val output = tool.flat(":ythistory", WatchSync.HISTORY_LIMIT, cookies)
            if (output.cookiesRejected) throw SignedOutByYouTube()
            val history = WatchSync.parseHistory(output.json)
            val s = _state.value
            if (!s.syncWatchedWithYouTube || s.account.state != AccountState.SIGNED_IN) return
            val newly = WatchSync.newlyWatched(history, s.youTubeHistory)
            val known = s.recentVideos.values.flatten().mapTo(HashSet()) { it.video.id } +
                s.accountFeeds?.let { f -> (f.recommended + f.subscriptions).map { it.id } }.orEmpty() + host.downloadedIds()
            val watched = host.watchedHere()
            newly.filter { it in known && it !in watched }.takeIf { it.isNotEmpty() }?.let(host::addWatchedHere)
            edit { it.copy(youTubeHistory = history, lastWatchSync = clock()) }
            _watchSyncError.value = null
        } catch (e: SignedOutByYouTube) {
            markExpired()
            _watchSyncError.value = "YouTube signed you out."
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (e is ToolFailure && e.kind == YouTubeFailure.Kind.AUTH) markExpired()
            Logs.w("Couldn't sync watched videos with YouTube: ${e.message}")
            _watchSyncError.value = e.message ?: "Couldn't reach YouTube."
        }
    }

    /** Marked watched or unwatched on the phone: watched ones queue for YouTube (it can't unwatch). */
    fun onWatched(id: String, watched: Boolean) {
        val s = _state.value
        if (watched) {
            if (s.account.state != AccountState.SIGNED_IN || !s.syncWatchedWithYouTube) return
            if (id !in s.pendingYouTubeWatched) edit { it.copy(pendingYouTubeWatched = it.pendingYouTubeWatched + id) }
            scope.launch { syncWatched() }
        } else if (id in s.pendingYouTubeWatched) {
            edit { it.copy(pendingYouTubeWatched = it.pendingYouTubeWatched - id) }
        }
    }

    fun setSyncWatched(on: Boolean) {
        edit { it.copy(syncWatchedWithYouTube = on, pendingYouTubeWatched = if (on) it.pendingYouTubeWatched else emptyList()) }
        if (on) scope.launch { syncWatched() } else _watchSyncError.value = null
    }

    // The YouTube account

    /** The vault's cookies when the account may be used; signs out when the vault lost them, and notices a LOGIN_INFO past its date. */
    private fun cookiesForCheck(): String? {
        val s = _state.value
        if (s.account.state == AccountState.SIGNED_OUT) return null
        val text = vault.load()
        if (text == null) {
            Logs.w("The YouTube sign-in is gone from the vault; signed out")
            edit { it.copy(account = AccountInfo()) }
            return null
        }
        if (s.account.state == AccountState.SIGNED_IN) {
            val expiry = NetscapeCookies.loginInfoExpiry(NetscapeCookies.parse(text))
            if (expiry != null && expiry * 1000 <= clock()) markExpired()
        }
        return text
    }

    /** Signed out by YouTube; sticks until a probe is accepted or you sign in or out. */
    fun markExpired() {
        var changed = false
        edit { s ->
            if (s.account.state != AccountState.SIGNED_IN) s
            else {
                changed = true
                s.copy(account = s.account.copy(state = AccountState.EXPIRED, lastProbeAt = clock()))
            }
        }
        if (changed) {
            Logs.w("YouTube signed this phone out")
            host.onSignedOutByYouTube()
        }
    }

    /** While signed out by YouTube, at most hourly: are the cookies accepted again? */
    private suspend fun probe(cookies: String) {
        edit { it.copy(account = it.account.copy(lastProbeAt = clock())) }
        val accepted = try {
            !tool.flat(":ytsubs", 1, cookies).cookiesRejected
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            false
        }
        if (accepted) {
            edit { s -> if (s.account.state == AccountState.EXPIRED) s.copy(account = s.account.copy(state = AccountState.SIGNED_IN)) else s }
            Logs.i("YouTube sign-in works again")
        }
    }

    /**
     * Signs in with cookies.txt text (from the web view or a file): it must hold a YouTube session,
     * and (unless `verify` is off, for debug cookies) YouTube must accept it. A network failure
     * still stores it; the next check tells.
     */
    suspend fun signIn(cookiesText: String, source: String, verify: Boolean = true): SignInResult {
        val now = clock()
        val cookies = NetscapeCookies.parse(cookiesText)
        if (!NetscapeCookies.isSignedIn(cookies, now)) {
            return SignInResult.Failed(if (source == SOURCE_FILE) NO_SIGN_IN_IN_FILE else "YouTube didn't sign you in. Try again.")
        }
        val text = NetscapeCookies.format(cookies, now)
        if (verify) {
            val rejected = try {
                tool.flat(":ytsubs", 1, text).cookiesRejected
            } catch (e: ToolFailure) {
                e.kind == YouTubeFailure.Kind.AUTH
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                false
            }
            if (rejected) return SignInResult.Failed(REJECTED)
        }
        try {
            vault.save(text)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Logs.w("Couldn't keep the sign-in", e)
            return SignInResult.Failed(NOT_KEPT)
        }
        edit { it.copy(account = AccountInfo(AccountState.SIGNED_IN, now, source, 0)) }
        _watchSyncError.value = null
        Logs.i("Signed in to YouTube (${if (source == SOURCE_FILE) "cookies.txt" else "web"})")
        // The check reads the feeds and syncs watched videos too.
        scope.launch { start(Trigger.SIGN_IN, null).await() }
        return SignInResult.Done
    }

    /** Deletes the sign-in and everything read with it. Members-only recent videos hide again (access unknown); downloads stay. */
    fun signOut() {
        runCatching { vault.save(null) }.onFailure { Logs.w("Couldn't delete the YouTube sign-in", it) }
        runCatching { host.clearWebData() }
        edit {
            it.copy(account = AccountInfo(), accountFeeds = null, memberAccess = emptyMap(), nonMemberChannels = emptyMap(),
                    noMembersPlaylist = emptyMap(), youTubeHistory = emptyList(), pendingYouTubeWatched = emptyList(), lastWatchSync = 0)
        }
        _watchSyncError.value = null
    }

    /** The cookies.txt text for a yt-dlp call (members-only downloads), when signed in or signed out by YouTube. */
    fun cookies(): String? = if (_state.value.account.state == AccountState.SIGNED_OUT) null else vault.load()

    // Channels

    /** A pasted URL, @handle or channel id. Throws [ChannelInputException] with the message to show. */
    suspend fun addChannel(input: String): FollowedChannel {
        val info = resolver.resolve(input)
        _state.value.channels.firstOrNull { it.id == info.id }?.let { throw ChannelResolver.alreadyAdded(it.title) }
        follow(info)
        return _state.value.channels.first { it.id == info.id }
    }

    /** Follows a channel and fetches it right away. Returns false when it's already followed. */
    fun follow(info: ChannelInfo): Boolean {
        val added = addFollowed(listOf(info))
        if (added.isEmpty()) return false
        seed(added)
        return true
    }

    /** Follows the picked channels (skipping ones already followed) and fetches them, 3 at a time. Returns how many were added. */
    fun addChannels(picked: List<ChannelInfo>): Int {
        val added = addFollowed(picked)
        if (added.isNotEmpty()) seed(added)
        return added.size
    }

    private fun addFollowed(infos: List<ChannelInfo>): List<ChannelInfo> {
        val now = clock()
        var added: List<ChannelInfo> = emptyList()
        edit { s ->
            val ids = s.channels.mapTo(HashSet()) { it.id }
            added = infos.filter { ids.add(it.id) }
            if (added.isEmpty()) s
            else s.copy(channels = s.channels + added.map { FollowedChannel(it.id, it.title, it.handle, it.avatarUrl, now) },
                        channelErrors = s.channelErrors - added.map { it.id }.toSet())
        }
        added.forEach { Logs.i("Following ${it.title} (${it.id})") }
        return added
    }

    private fun seed(added: List<ChannelInfo>) {
        scope.launch { start(Trigger.CHANNEL_ADDED, added.mapTo(HashSet()) { it.id }).await() }
        // Followed from a video or a group: only the id and title are known.
        val bare = added.filter { it.avatarUrl == null || it.handle == null }
        if (bare.isNotEmpty()) scope.launch {
            val permits = Semaphore(3)
            coroutineScope { bare.map { launch { permits.withPermit { lookUp(it.id) } } } }
        }
    }

    private suspend fun lookUp(id: String) {
        val info = runCatching { web.get(ChannelResolver.channelUrl(id)) }.getOrNull()
            ?.takeIf { it.status == 200 }?.let { ChannelPageParser.parse(it.body) } ?: return
        edit { s ->
            s.copy(channels = s.channels.map { c ->
                if (c.id != id) c else c.copy(avatarUrl = c.avatarUrl ?: info.avatarUrl, handle = c.handle ?: info.handle,
                                               title = c.title.ifEmpty { info.title })
            })
        }
    }

    /** Stops following: its videos, feeds' state and group memberships go (or it would be followed again). Downloads stay. Returns its title. */
    fun unfollow(id: String): String? {
        var title: String? = null
        edit { s ->
            val channel = s.channels.firstOrNull { it.id == id } ?: return@edit s
            title = channel.title
            val videoIds = s.recentVideos[id].orEmpty().mapTo(HashSet()) { it.video.id }
            s.copy(
                channels = s.channels.filterNot { it.id == id },
                recentVideos = s.recentVideos - id,
                fetchedAt = s.fetchedAt - id,
                nonMemberChannels = s.nonMemberChannels - id,
                noMembersPlaylist = s.noMembersPlaylist - id,
                memberAccess = s.memberAccess.filterKeys { it !in videoIds },
                channelErrors = s.channelErrors - id,
                groups = s.groups.map { g -> g.copy(channels = g.channels.filterNot { it.id == id }) },
            )
        }
        title?.let { Logs.i("Removed channel $it ($id)") }
        return title
    }

    /** Moves a channel up (-1) or down (+1) the list. */
    fun moveChannel(id: String, by: Int) = edit { s ->
        val from = s.channels.indexOfFirst { it.id == id }
        val to = from + by
        if (from < 0 || to !in s.channels.indices) s
        else s.copy(channels = s.channels.toMutableList().apply { add(to, removeAt(from)) })
    }

    /** The account's YouTube subscriptions, for the import picker. Throws [SignedOutByYouTube] when YouTube wants a new sign-in. */
    suspend fun loadSubscriptions(): List<ChannelInfo> {
        val text = cookies() ?: throw SignedOutByYouTube()
        try {
            return SubscriptionsImport(web).fetch(NetscapeCookies.parse(text), clock())
        } catch (e: SignedOutByYouTube) {
            markExpired()
            throw e
        }
    }

    // Groups (stored here instead of Firestore)

    /** Groups change; a channel put in one that isn't followed gets followed. Returns the channels newly followed. */
    fun editGroupsLocally(change: (List<ChannelGroup>) -> List<ChannelGroup>): List<GroupChannel> {
        var follow: List<GroupChannel> = emptyList()
        edit { s ->
            val groups = change(s.groups)
            follow = groups.flatMap { it.channels }.distinctBy { it.id }.filter { !s.isFollowed(it.id) }
            s.copy(groups = groups)
        }
        if (follow.isNotEmpty()) addChannels(follow.map { ChannelInfo(it.id, it.title) })
        return follow
    }

    fun createGroup(group: ChannelGroup): List<GroupChannel> = editGroupsLocally { it + group }
    fun renameGroup(id: String, name: String) = editGroupsLocally { groups -> groups.map { if (it.id == id) it.copy(name = name.trim()) else it } }
    fun deleteGroup(id: String) = editGroupsLocally { groups -> groups.filterNot { it.id == id } }
    fun setInGroup(groupId: String, channel: GroupChannel, included: Boolean): List<GroupChannel> = editGroupsLocally { groups ->
        groups.map { g ->
            if (g.id != groupId) g else g.copy(channels = g.channels.filterNot { it.id == channel.id } + listOfNotNull(channel.takeIf { included }))
        }
    }
    fun moveGroup(id: String, by: Int) = editGroupsLocally { groups ->
        val from = groups.indexOfFirst { it.id == id }
        val to = from + by
        if (from < 0 || to !in groups.indices) groups else groups.toMutableList().apply { add(to, removeAt(from)) }
    }

    // Mode switches

    /** Mac → standalone: the Mac's channels and groups join this phone's (when kept). */
    fun adoptMac(channels: List<Channel>, groups: List<ChannelGroup>) {
        edit { ModeSwitch.adoptMac(it, channels, groups, clock()) }
    }

    /** Standalone → Mac: signs out of YouTube here and drops queued watched marks; channels, groups and check state stay on disk. */
    suspend fun leave() {
        signOut()
        flush()
    }

    companion object {
        const val MAX_CONCURRENT_CHANNELS = 3
        const val FEEDS_LIMIT = 150
        const val AVATAR_LOOKUPS = 20
        const val AVATAR_CACHE = 1000
        const val ACCESS_LOOKUPS = 15
        const val PULL_REUSE_MS = 60_000L
        const val FAILING_STREAK = 3
        const val SOURCE_WEB = "web"
        const val SOURCE_FILE = "file"
        const val REJECTED = "YouTube didn't accept this sign-in."
        const val NO_SIGN_IN_IN_FILE = "This file has no YouTube sign-in."
        const val NOT_KEPT = "Couldn't keep the sign-in on this phone. Try again."
    }
}

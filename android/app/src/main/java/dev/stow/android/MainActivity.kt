package dev.stow.android

import android.Manifest
import android.content.Intent
import android.os.Bundle
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.ui.layout.onSizeChanged
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.selection.selectable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.border
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Subscriptions
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Subscriptions
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import dev.stow.android.data.PairState
import dev.stow.android.data.VideoItem
import dev.stow.android.remote.RemoteModel
import dev.stow.android.ui.ChannelScreen
import dev.stow.android.ui.ChannelsScreen
import dev.stow.android.ui.DownloadsScreen
import dev.stow.android.ui.Format
import dev.stow.android.ui.HomeScreen
import dev.stow.android.ui.PairScreen
import dev.stow.android.ui.PlayerScreen
import dev.stow.android.ui.PlaylistScreen
import dev.stow.android.ui.RemoteScreen
import dev.stow.android.ui.SaveToPlaylistSheet
import dev.stow.android.ui.SearchScreen
import dev.stow.android.ui.SettingsScreen
import dev.stow.android.ui.Stow
import dev.stow.android.ui.StowTheme
import dev.stow.android.ui.SubscriptionsScreen
import dev.stow.android.ui.VideoActions
import dev.stow.android.ui.sortedFor
import androidx.compose.ui.zIndex
import androidx.compose.ui.graphics.asComposeRenderEffect
import androidx.compose.ui.graphics.graphicsLayer
import dev.stow.android.ui.ReportScreen
import dev.stow.android.ui.release
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    private val app get() = application as StowApplication
    private val repository get() = app.repository
    /** The alarm remote's state, here so the volume keys can reach it while its screen shows. */
    private val remote by lazy { RemoteModel(app, app.remoteClient, repository.prefs, lifecycleScope) }
    /** A screen to open from an intent (the alarm notification), taken by the NavHost. */
    private var openRoute by mutableStateOf<String?>(null)
    private var shownRoute: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        handle(intent)
        setContent {
            val theme by repository.prefs.theme.collectAsStateWithLifecycle()
            val dark = theme.isDark(androidx.compose.foundation.isSystemInDarkTheme())
            // The status and navigation bar icons follow the app's theme, not the phone's.
            LaunchedEffect(dark) {
                val style = if (dark) androidx.activity.SystemBarStyle.dark(android.graphics.Color.TRANSPARENT)
                            else androidx.activity.SystemBarStyle.light(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT)
                enableEdgeToEdge(statusBarStyle = style, navigationBarStyle = style)
            }
            StowTheme(theme) {
                Surface(Modifier.fillMaxSize(), color = Stow.colors.background) { App() }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        app.updater.checkIfDueInBackground()
    }

    override fun onResume() {
        super.onResume()
        // Back from "Install unknown apps": carry on with the update.
        app.updater.onResume()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    /** stow://pair?… opened from the phone's camera app, or the alarm notification. */
    private fun handle(intent: Intent?) {
        if (intent?.action == ACTION_OPEN_REMOTE) {
            openRoute = "remote"
            // Not again when the activity is recreated with the same intent.
            intent.action = null
        }
        val data = intent?.data ?: return
        if (data.scheme == "stow" && data.host == "pair") repository.pair(data.toString())
    }

    /** On the alarm remote, the volume keys turn the Mac's speaker up and down instead of the phone's. */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val up = when (event.keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> true
            KeyEvent.KEYCODE_VOLUME_DOWN -> false
            else -> null
        }
        if (up != null && shownRoute == "remote" && remote.volumeControllable) {
            if (event.action == KeyEvent.ACTION_DOWN) remote.nudgeVolume(up)
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    @Composable
    private fun App() {
        val pairState by repository.pairState.collectAsStateWithLifecycle()
        val notifications = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
        LaunchedEffect(Unit) { notifications.launch(Manifest.permission.POST_NOTIFICATIONS) }
        // An update the package installer wants confirmed: show Android's screen (only while the app is in front).
        val install by app.updater.install.collectAsStateWithLifecycle()
        LaunchedEffect(install) {
            val confirm = install as? dev.stow.android.update.Updater.Install.Confirm ?: return@LaunchedEffect
            runCatching { startActivity(confirm.intent) }
            app.updater.confirmShown(confirm)
        }
        if (pairState != PairState.Paired) {
            PairScreen(pairState, onScanned = repository::pair)
        } else {
            Shell()
        }
    }

    @Composable
    private fun Shell() {
        val nav = rememberNavController()
        val player = app.player
        val itemsById by repository.items.collectAsStateWithLifecycle()
        val channels by repository.channels.collectAsStateWithLifecycle()
        val playlists by repository.playlists.collectAsStateWithLifecycle()
        val sort by repository.prefs.downloadSort.collectAsStateWithLifecycle()
        val group by repository.prefs.groupByChannel.collectAsStateWithLifecycle()
        val wifiOnly by repository.prefs.wifiOnly.collectAsStateWithLifecycle()
        val current by player.current.collectAsStateWithLifecycle()
        val queue by player.queue.collectAsStateWithLifecycle()
        val route = nav.currentBackStackEntryAsState().value?.destination?.route
        // Cleared when Shell goes (e.g. the Mac unpaired this phone), so the volume keys work again.
        DisposableEffect(route) {
            shownRoute = route
            onDispose { shownRoute = null }
        }
        LaunchedEffect(openRoute) {
            openRoute?.let { nav.navigate(it) { launchSingleTop = true } }
            openRoute = null
        }
        val alarm by repository.prefs.alarm.collectAsStateWithLifecycle()
        val updater = app.updater
        val updateCheck by updater.check.collectAsStateWithLifecycle()
        val updateInstall by updater.install.collectAsStateWithLifecycle()
        val dismissedUpdate by repository.prefs.dismissedUpdate.collectAsStateWithLifecycle()
        val update = (updateCheck as? dev.stow.android.update.Updater.Check.Available)?.release
        var showUpdate by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(false) }
        val calm by repository.prefs.calm.collectAsStateWithLifecycle()
        val grayscale by repository.prefs.grayscale.collectAsStateWithLifecycle()
        val statsVersion by repository.stats.changes.collectAsStateWithLifecycle()
        val todaySeconds = remember(statsVersion) { repository.stats.day(java.time.LocalDate.now()).seconds }
        var saving by remember { mutableStateOf<VideoItem?>(null) }
        var storage by remember { mutableStateOf("") }
        val snackbar = remember { androidx.compose.material3.SnackbarHostState() }
        val scope = androidx.compose.runtime.rememberCoroutineScope()
        fun notify(message: String) {
            scope.launch {
                snackbar.currentSnackbarData?.dismiss()
                snackbar.showSnackbar(message, duration = androidx.compose.material3.SnackbarDuration.Short)
            }
        }

        val all = itemsById.values.filterNot { it.onlyInYouTubeFeeds }
        val youtubeFeeds by repository.youtubeFeeds.collectAsStateWithLifecycle()
        val groups by repository.groups.collectAsStateWithLifecycle()
        val feed = all.sortedByDescending { it.video.publishedAt?.time ?: it.sent?.sentAt?.time ?: 0 }
        val everything = itemsById.values.filterNot { it.fromSearch }.sortedByDescending { it.video.publishedAt?.time ?: it.sent?.sentAt?.time ?: 0 }
        val recommended = youtubeFeeds.recommended.mapNotNull { itemsById[it.id] }
        val subscriptionsFeed = dev.stow.android.data.Feeds.subscriptions(youtubeFeeds.subscriptions.mapNotNull { itemsById[it.id] }, feed)
        // The Mac's channels first (with their pictures), then the rest YouTube's feeds mention.
        val knownChannels = (channels.map { dev.stow.android.ui.SubscriptionChannel(it.id, it.title, it.avatarUrl) } +
            (youtubeFeeds.subscriptions + youtubeFeeds.recommended).filter { it.channelId.isNotEmpty() }
                .map { dev.stow.android.ui.SubscriptionChannel(it.channelId, it.channelTitle, youtubeFeeds.channelAvatars[it.channelId]) }).distinctBy { it.id }
        val subscribedChannels = knownChannels.filter { c -> channels.any { it.id == c.id } || youtubeFeeds.subscriptions.any { it.channelId == c.id } }
        // The Mac's channels' pictures, then the ones it looked up for channels only in YouTube's feeds.
        val channelPages by repository.channelPages.collectAsStateWithLifecycle()
        val avatars = channelPages.mapNotNull { (id, page) -> page.avatarUrl?.let { id to it } }.toMap() +
            youtubeFeeds.channelAvatars + channels.mapNotNull { c -> c.avatarUrl?.let { c.id to it } }
        var grouping by remember { mutableStateOf<dev.stow.android.data.GroupChannel?>(null) }
        var newGroup by remember { mutableStateOf(false) }
        var sizing by remember { mutableStateOf<VideoItem?>(null) }
        val groupActions = dev.stow.android.ui.GroupActions(
            create = repository::createGroup, rename = repository::renameGroup, delete = repository::deleteGroup,
            setChannel = repository::setInGroup, move = repository::moveGroup,
        )
        val refresh: suspend () -> Unit = {
            when (repository.refreshFromMac()) {
                dev.stow.android.data.Repository.RefreshResult.DONE -> notify("Up to date")
                dev.stow.android.data.Repository.RefreshResult.NO_ANSWER -> notify("The Mac didn't answer. Is Stow running on it?")
                dev.stow.android.data.Repository.RefreshResult.FAILED -> notify("Couldn't reach the Mac's Firebase. Check the connection.")
            }
        }
        LaunchedEffect(all.count { it.isPlayable }) {
            storage = withContext(Dispatchers.IO) { "${Format.bytes(repository.storageUsedBytes())} used on this phone" }
        }

        val sheet = dev.stow.android.ui.rememberPlayerSheetState()
        var bottomBarHeight by remember { mutableStateOf(0.dp) }
        val density = androidx.compose.ui.platform.LocalDensity.current
        // Nothing playing: the next video slides up from where the mini player sits.
        LaunchedEffect(current) { if (current == null) sheet.reset() }

        fun play(list: List<VideoItem>, start: VideoItem) {
            player.play(list, start)
            sheet.expand()
        }
        val actions = VideoActions(
            play = { item ->
                // Plays within the list you're looking at: the rest of it becomes Up next.
                // A video that isn't downloaded streams on its own.
                val context = when {
                    !item.isPlayable -> listOf(item)
                    route == "downloads" -> all.filter { it.isPlayable }.sortedFor(sort)
                    else -> feed.filter { it.isPlayable }
                }
                play(context, item)
            },
            download = { item ->
                // Long videos (past streams especially) can be GBs: say the size first.
                if (item.durationMs >= LONG_VIDEO_MS && item.state != dev.stow.android.data.DownloadState.FAILED) {
                    sizing = item
                } else {
                    repository.download(item)
                    notify(if (item.state == dev.stow.android.data.DownloadState.FAILED) "Retrying download" else "Downloading")
                }
            },
            delete = { item ->
                if (item.id == current) player.stop()
                repository.deleteDownload(item.id)
                notify(if (item.isPlayable) "Deleted from downloads" else "Download canceled")
            },
            setWatched = { item, watched ->
                repository.setWatched(item.id, watched)
                notify(if (watched) "Marked as watched" else "Marked as unwatched")
            },
            saveToPlaylist = { saving = it },
            openChannel = { id -> nav.navigate("channel/$id") },
            notify = ::notify,
            addToGroup = { item -> grouping = dev.stow.android.data.GroupChannel(item.video.channelId, item.video.channelTitle) },
        )

        val tabs = listOf(
            Tab("home", "Home", Icons.Filled.Home, Icons.Outlined.Home),
            Tab("subscriptions", "Subscriptions", Icons.Filled.Subscriptions, Icons.Outlined.Subscriptions),
            Tab("downloads", "Downloads", Icons.Filled.Download, Icons.Outlined.Download),
        )
        val fullScreen = route == "remote"

        val gray = if (grayscale) Modifier.graphicsLayer {
            renderEffect = android.graphics.RenderEffect.createColorFilterEffect(
                android.graphics.ColorMatrixColorFilter(android.graphics.ColorMatrix().apply { setSaturation(0f) })
            ).asComposeRenderEffect()
        } else Modifier
        androidx.compose.runtime.CompositionLocalProvider(dev.stow.android.ui.LocalCalm provides calm, dev.stow.android.ui.LocalUpdateAvailable provides (update != null), dev.stow.android.ui.LocalChannelAvatars provides avatars) {
        Box(Modifier.fillMaxSize().then(gray)) {
        Column(Modifier.fillMaxSize()) {
            Box(Modifier.weight(1f)) {
                androidx.compose.material3.SnackbarHost(snackbar, Modifier.align(Alignment.BottomCenter).zIndex(1f)) { data ->
                    androidx.compose.material3.Snackbar(data, containerColor = androidx.compose.ui.graphics.Color(0xFF323232),
                        contentColor = androidx.compose.ui.graphics.Color.White, shape = androidx.compose.foundation.shape.RoundedCornerShape(8.dp))
                }
                NavHost(nav, startDestination = "home") {
                    composable("home") {
                        HomeScreen(recommended, everything, groups, avatars, actions, todaySeconds = todaySeconds,
                                   onReport = { nav.navigate("report") },
                                   onSearch = { nav.navigate("search") }, onSettings = { nav.navigate("settings") },
                                   onRefresh = refresh, onNewGroup = { newGroup = true },
                                   onEditGroup = { nav.navigate("group/$it") },
                                   alarmMac = alarm?.takeIf { it.isRecent() }?.macName, onRemote = { nav.navigate("remote") },
                                   update = update?.version?.takeIf { it != dismissedUpdate }, onUpdate = { showUpdate = true },
                                   onHideUpdate = { update?.let { repository.prefs.dismissUpdate(it.version) } })
                    }
                    composable("subscriptions") {
                        SubscriptionsScreen(subscriptionsFeed, subscribedChannels, actions, onAllChannels = { nav.navigate("channels") },
                                            onSearch = { nav.navigate("search") }, onSettings = { nav.navigate("settings") },
                                            onRefresh = refresh)
                    }
                    composable("groups") {
                        dev.stow.android.ui.GroupsScreen(groups, groupActions, onOpen = { nav.navigate("group/$it") }, onBack = { nav.popBackStack() })
                    }
                    composable("group/{id}") { entry ->
                        val group = groups.firstOrNull { it.id == entry.arguments?.getString("id") }
                        dev.stow.android.ui.GroupScreen(group, knownChannels.map { dev.stow.android.data.GroupChannel(it.id, it.title) },
                                                        avatars, groupActions, onBack = { nav.popBackStack() })
                    }
                    composable("downloads") {
                        DownloadsScreen(
                            all = all, channels = channels, playlists = playlists, byId = itemsById,
                            sort = sort, groupByChannel = group, storageText = storage, actions = actions,
                            onSort = repository.prefs::setDownloadSort, onGroup = repository.prefs::setGroupByChannel,
                            onOpenPlaylist = { nav.navigate("playlist/$it") },
                            onNewPlaylist = { repository.createPlaylist(it); notify("Created “$it”") },
                            onSearch = { nav.navigate("search") }, onSettings = { nav.navigate("settings") },
                            onDeleteMany = { items ->
                                if (items.any { it.id == current }) player.stop()
                                items.forEach { repository.deleteDownload(it.id) }
                                notify(if (items.size == 1) "Deleted from downloads" else "Deleted ${items.size} videos from downloads")
                            },
                        )
                    }
                    composable("channels") {
                        val counts = everything.groupingBy { it.video.channelId }.eachCount()
                        ChannelsScreen(subscribedChannels, counts, onOpen = { nav.navigate("channel/$it") }, onBack = { nav.popBackStack() })
                    }
                    composable("channel/{id}") { entry ->
                        val id = entry.arguments?.getString("id")
                        val channel = channels.firstOrNull { it.id == id }
                        val page = id?.let { channelPages[it] }
                        var loading by remember(id) { mutableStateOf(false) }
                        var loadError by remember(id) { mutableStateOf<String?>(null) }
                        var attempt by remember(id) { mutableStateOf(0) }
                        // Not followed on the Mac: get its latest videos from YouTube here.
                        LaunchedEffect(id, attempt) {
                            if (id == null || channel != null) return@LaunchedEffect
                            loading = true
                            loadError = null
                            try {
                                withContext(Dispatchers.IO) { repository.loadChannelPage(id) }
                            } catch (e: kotlinx.coroutines.CancellationException) {
                                throw e
                            } catch (e: Exception) {
                                loadError = e.message?.lineSequence()?.firstOrNull()?.removePrefix("ERROR: ")?.takeIf { it.isNotBlank() }
                                    ?: "Check the connection and try again."
                            } finally {
                                loading = false
                            }
                        }
                        // Its latest videos from YouTube first (in YouTube's order), then the rest you know of.
                        val known = everything.filter { it.video.channelId == id } +
                            itemsById.values.filter { it.fromSearch && it.video.channelId == id }
                        val loaded = page?.let { (it.videoIds + it.streamIds).mapNotNull { v -> itemsById[v] } }.orEmpty()
                        val videos = loaded + known.filterNot { k -> loaded.any { it.id == k.id } }
                        val title = channel?.title ?: knownChannels.firstOrNull { it.id == id }?.title ?: page?.title?.takeIf { it.isNotEmpty() }
                            ?: videos.firstOrNull()?.video?.channelTitle.orEmpty()
                        ChannelScreen(channel, title, videos, actions.copy(play = { item -> play(videos, item) }),
                                      groupNames = groups.filter { g -> g.channels.any { it.id == id } }.map { it.name },
                                      onGroups = { if (id != null) grouping = dev.stow.android.data.GroupChannel(id, title) },
                                      onBack = { nav.popBackStack() },
                                      page = page, loading = loading, loadError = loadError, onRetry = { attempt++ })
                    }
                    composable("playlist/{id}") { entry ->
                        val playlist = playlists.firstOrNull { it.id == entry.arguments?.getString("id") }
                        val videos = playlist?.videoIds?.mapNotNull { itemsById[it] }.orEmpty()
                        PlaylistScreen(
                            playlist = playlist, videos = videos,
                            actions = actions.copy(
                                play = { item -> play(videos, item) },
                                removeFromPlaylist = { item ->
                                    playlist?.let { repository.playlistStore.remove(it.id, item.id); notify("Removed from ${it.name}") }
                                },
                                move = { item, by -> playlist?.let { repository.playlistStore.move(it.id, item.id, by) } },
                            ),
                            onPlayAll = { shuffle ->
                                val list = videos.filter { it.isPlayable }.let { if (shuffle) it.shuffled() else it }
                                list.firstOrNull()?.let { play(list, it) }
                            },
                            onRename = { name -> playlist?.let { repository.playlistStore.rename(it.id, name) } },
                            onDelete = {
                                playlist?.let { repository.playlistStore.delete(it.id); notify("Deleted “${it.name}”") }
                                nav.popBackStack()
                            },
                            onBack = { nav.popBackStack() },
                        )
                    }
                    composable("search") {
                        val recentSearches by repository.prefs.recentSearches.collectAsStateWithLifecycle()
                        SearchScreen(everything, itemsById, recentSearches, actions,
                                     onSearch = { withContext(Dispatchers.IO) { repository.searchYouTube(it) } },
                                     onRemoveRecent = repository.prefs::removeRecentSearch,
                                     onPlay = { list, item -> play(list, item) },
                                     onBack = { nav.popBackStack() })
                    }
                    composable("settings") {
                        SettingsScreen(repository, updater, wifiOnly, onReport = { nav.navigate("report") },
                                       onRemote = { nav.navigate("remote") }, onGroups = { nav.navigate("groups") },
                                       onUpdate = { showUpdate = true }, onBack = { nav.popBackStack() })
                    }
                    composable("remote") { RemoteScreen(remote, alarm?.macName, onBack = { nav.popBackStack() }) }
                    composable("report") {
                        val week = remember(statsVersion) { repository.stats.week() }
                        val lastWeek = remember(statsVersion) { repository.stats.week(java.time.LocalDate.now().minusDays(7)) }
                        ReportScreen(week, lastWeek, channels, onBack = { nav.popBackStack() })
                    }
                }
            }
            if (!fullScreen) {
                // Room for the mini player, which is drawn over everything (it grows into the watch page).
                if (current != null) Spacer(Modifier.height(dev.stow.android.ui.MiniPlayerHeight))
                Box(Modifier.onSizeChanged { bottomBarHeight = with(density) { it.height.toDp() } }) { BottomBar(tabs, route, nav) }
            }
        }
        val playing = current?.let { itemsById[it] }
        if (playing != null && !fullScreen) {
            val index = queue.indexOf(current)
            val upNext = if (index >= 0) queue.drop(index + 1).mapNotNull { itemsById[it] } else emptyList()
            PlayerScreen(
                connection = player, current = playing, upNext = upNext,
                channel = channels.firstOrNull { it.id == playing.video.channelId },
                actions = actions.copy(
                    // Up next: jump within the same queue.
                    play = { next -> player.play(queue.mapNotNull { itemsById[it] }, next) },
                    // Opening a channel from the watch page shrinks the player, like YouTube.
                    openChannel = { id -> sheet.collapse(); nav.navigate("channel/$id") },
                ),
                sheet = sheet, bottomInset = bottomBarHeight,
                loadComments = { video, fresh -> repository.comments(video, fresh) },
            )
        }
        }
        }

        // The update's notes, then its download and install (shown while one is under way, too).
        val updating = updateInstall.release
        (updating ?: update?.takeIf { showUpdate })?.let { release ->
            dev.stow.android.ui.UpdateDialog(updater, release, onDismiss = { showUpdate = false })
        }
        grouping?.let { channel ->
            dev.stow.android.ui.GroupPickerSheet(channel, groups, groupActions, notify = ::notify, onDismiss = { grouping = null })
        }
        if (newGroup) {
            dev.stow.android.ui.NameDialog("New group", "", onDismiss = { newGroup = false }) { name ->
                newGroup = false
                val group = repository.createGroup(name)
                nav.navigate("group/${group.id}")
            }
        }
        sizing?.let { item ->
            var size by remember(item.id) { mutableStateOf<Long?>(null) }
            var checking by remember(item.id) { mutableStateOf(true) }
            LaunchedEffect(item.id) {
                val cookies = if (item.video.isMembersOnly) repository.cookiesFile() else null
                size = runCatching { dev.stow.android.sync.YtDlp.downloadSize(this@MainActivity, item.video, cookies, repository.prefs.downloadFormatSort) }.getOrNull()
                cookies?.delete()
                checking = false
            }
            dev.stow.android.ui.DownloadSizeDialog(
                item.video.title, item.durationMs, size, checking,
                onDownload = {
                    sizing = null
                    repository.download(item)
                    notify("Downloading")
                },
                onDismiss = { sizing = null },
            )
        }
        saving?.let { item ->
            SaveToPlaylistSheet(
                item = itemsById[item.id] ?: item, playlists = playlists,
                onToggle = { playlist, add ->
                    if (add) repository.addToPlaylist(playlist.id, item) else repository.playlistStore.remove(playlist.id, item.id)
                    notify(if (add) "Saved to ${playlist.name}" else "Removed from ${playlist.name}")
                },
                onCreate = { name -> repository.createPlaylist(name, item); notify("Saved to $name") },
                onDismiss = { saving = null },
            )
        }
    }

    companion object {
        /** The alarm notification's tap: opens the remote. */
        const val ACTION_OPEN_REMOTE = "dev.stow.android.OPEN_REMOTE"
        /** Downloads longer than this ask first, with the size. */
        const val LONG_VIDEO_MS = 20 * 60 * 1000L
    }

    private data class Tab(val route: String, val label: String, val selected: ImageVector, val unselected: ImageVector)

    @Composable
    private fun BottomBar(tabs: List<Tab>, route: String?, nav: NavHostController) {
        // A floating capsule, as in iOS: filled symbols, the selected tab in the accent on a soft highlight.
        val behind = if (route in setOf("settings", "groups", "group/{id}")) Stow.colors.groupedBackground else Stow.colors.background
        Box(Modifier.fillMaxWidth().background(behind).navigationBarsPadding()
                .padding(start = 20.dp, end = 20.dp, top = 4.dp, bottom = 8.dp)) {
            Row(Modifier.fillMaxWidth().height(62.dp)
                    .shadow(10.dp, RoundedCornerShape(31.dp), ambientColor = Color.Black.copy(alpha = 0.18f), spotColor = Color.Black.copy(alpha = 0.18f))
                    .clip(RoundedCornerShape(31.dp)).background(Stow.colors.raised)
                    .border(0.5.dp, Stow.colors.divider.copy(alpha = 0.6f), RoundedCornerShape(31.dp))
                    .padding(4.dp)) {
                tabs.forEach { tab ->
                    val selected = route == tab.route
                    val tint = if (selected) Stow.colors.accent else Stow.colors.text
                    Column(
                        Modifier.weight(1f).fillMaxSize().clip(RoundedCornerShape(27.dp))
                            .background(if (selected) Stow.colors.chip else Color.Transparent)
                            .selectable(selected, role = androidx.compose.ui.semantics.Role.Tab) {
                                nav.navigate(tab.route) {
                                    popUpTo("home") { saveState = true }
                                    launchSingleTop = true
                                    restoreState = true
                                }
                            },
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center,
                    ) {
                        Icon(tab.selected, contentDescription = null, tint = tint, modifier = Modifier.size(24.dp))
                        Spacer(Modifier.height(2.dp))
                        Text(tab.label, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = tint, maxLines = 1)
                    }
                }
            }
        }
    }
}

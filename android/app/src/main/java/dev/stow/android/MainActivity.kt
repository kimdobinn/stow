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
import dev.stow.android.standalone.AppMode
import dev.stow.android.ui.ModeScreen
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
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedContentTransitionScope
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.semantics.dismiss
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavGraphBuilder
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

    /** A pairing link that arrived in standalone mode, waiting for "Pair with this Mac?". */
    private var pendingPair by mutableStateOf<String?>(null)

    /** stow://pair?… opened from the phone's camera app, the alarm notification, or the sign-in notification. */
    private fun handle(intent: Intent?) {
        if (intent?.action == ACTION_OPEN_REMOTE) {
            if (repository.mode.value == AppMode.MAC) openRoute = "remote"
            // Not again when the activity is recreated with the same intent.
            intent.action = null
        }
        if (intent?.action == ACTION_OPEN_SETTINGS) {
            openRoute = "settings"
            intent.action = null
        }
        // Debug builds: `--es stow.route settings|account|channels|import|search` opens that screen.
        if (BuildConfig.DEBUG) intent?.getStringExtra(EXTRA_ROUTE)?.let { route ->
            openRoute = when (route) {
                "settings", "account" -> "settings"
                "channels" -> "channels-manage"
                "import" -> "import"
                "search" -> "search"
                else -> null
            }
            intent.removeExtra(EXTRA_ROUTE)
        }
        val data = intent?.data ?: return
        if (data.scheme == "stow" && data.host == "pair") {
            intent.data = null
            if (repository.mode.value == AppMode.STANDALONE) pendingPair = data.toString() else repository.pair(data.toString())
        }
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
        val mode by repository.mode.collectAsStateWithLifecycle()
        val screen = when {
            mode == AppMode.CHOOSING -> Root.MODE
            mode == AppMode.STANDALONE -> Root.STANDALONE_SHELL
            pairState != PairState.Paired -> Root.PAIR
            else -> Root.MAC_SHELL
        }
        // Choosing a mode, pairing and the app itself crossfade into each other instead of cutting.
        // Each mode gets its own Shell (a fresh start, as before), and one mode's Shell never fades
        // into the other's: the old one would keep running for the fade in a mode it doesn't belong to.
        AnimatedContent(screen, transitionSpec = {
            if (initialState.isShell && targetState.isShell) EnterTransition.None togetherWith ExitTransition.None
            else fadeIn(tween(dev.stow.android.ui.Motion.MEDIUM)) togetherWith fadeOut(tween(dev.stow.android.ui.Motion.MEDIUM))
        }, label = "root") { shown ->
            when (shown) {
                Root.MODE -> ModeScreen(onMac = repository::chooseMac, onStandalone = repository::chooseStandalone)
                Root.PAIR -> PairScreen(pairState, onScanned = repository::pair, onStandalone = repository::chooseStandalone)
                Root.MAC_SHELL, Root.STANDALONE_SHELL -> Shell()
            }
        }
        pendingPair?.let { link ->
            androidx.compose.material3.AlertDialog(
                onDismissRequest = { pendingPair = null },
                title = { Text("Pair with this Mac?") },
                text = { Text("Stow stops working on its own; your channels on this phone are kept for later.") },
                confirmButton = {
                    androidx.compose.material3.TextButton(onClick = { pendingPair = null; repository.pair(link) }) { Text("Pair") }
                },
                dismissButton = { androidx.compose.material3.TextButton(onClick = { pendingPair = null }) { Text("Cancel") } },
            )
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
        val mode by repository.mode.collectAsStateWithLifecycle()
        val standaloneMode = mode == AppMode.STANDALONE
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
        // Downloads also include videos from searches and YouTube's feeds (standalone never "sends" them).
        val downloads = itemsById.values.filter { !it.onlyInYouTubeFeeds || it.state != null }
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
            setChannel = repository::setInGroup, move = repository::moveGroup, standalone = standaloneMode,
        )
        val engine = repository.standalone
        val followedIds by engine.followedIds.collectAsStateWithLifecycle()
        val account by engine.account.collectAsStateWithLifecycle()
        val checkStatus by engine.checkStatus.collectAsStateWithLifecycle()
        val signInPrompt by repository.prefs.signInPrompt.collectAsStateWithLifecycle()
        val expiredDismissed by repository.prefs.expiredBannerDismissed.collectAsStateWithLifecycle()
        var addingChannel by remember { mutableStateOf(false) }
        LaunchedEffect(Unit) { repository.messages.collect { notify(it) } }
        val refresh: suspend () -> Unit = {
            when (repository.refresh()) {
                dev.stow.android.data.Repository.RefreshResult.DONE -> notify("Up to date")
                dev.stow.android.data.Repository.RefreshResult.NO_ANSWER -> notify("The Mac didn't answer. Is Stow running on it?")
                dev.stow.android.data.Repository.RefreshResult.FAILED -> notify("Couldn't reach the Mac's Firebase. Check the connection.")
                dev.stow.android.data.Repository.RefreshResult.YOUTUBE_FAILED -> notify("Couldn't reach YouTube. Check the connection.")
                dev.stow.android.data.Repository.RefreshResult.SLOWED_DOWN -> notify("YouTube asked Stow to slow down. It'll try again later.")
            }
        }
        val cookiesImport = if (standaloneMode) dev.stow.android.ui.rememberCookiesImport(engine, ::notify) {
            if (route == "account-signin") nav.popBackStack()
        } else null
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
                    route == "downloads" -> downloads.filter { it.isPlayable }.sortedFor(sort)
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
            openChannel = { id -> if (id.isNotEmpty()) nav.navigate("channel/$id") },
            notify = ::notify,
            addToGroup = { item -> grouping = dev.stow.android.data.GroupChannel(item.video.channelId, item.video.channelTitle) },
            follow = if (standaloneMode) ({ item -> repository.follow(item.video.channelId, item.video.channelTitle, avatars[item.video.channelId]) }) else null,
            followed = followedIds,
            markAnyWatched = standaloneMode,
        )
        val standaloneHome = if (standaloneMode) dev.stow.android.ui.StandaloneHome(
            signedIn = account.state == dev.stow.android.standalone.AccountState.SIGNED_IN,
            expiredBanner = account.state == dev.stow.android.standalone.AccountState.EXPIRED && !expiredDismissed,
            signInPrompt = signInPrompt,
            followsNone = followedIds.isEmpty(),
            onSignIn = { repository.prefs.setSignInPrompt(false); nav.navigate("account-signin") },
            onDismissExpired = { repository.prefs.setExpiredBannerDismissed(true) },
            onDismissPrompt = { repository.prefs.setSignInPrompt(false) },
            onAddChannel = { addingChannel = true },
            onImport = { nav.navigate("import") },
        ) else null

        val tabs = listOf(
            Tab("home", "Home", Icons.Filled.Home, Icons.Outlined.Home),
            Tab("subscriptions", "Subscriptions", Icons.Filled.Subscriptions, Icons.Outlined.Subscriptions),
            Tab("downloads", "Downloads", Icons.Filled.Download, Icons.Outlined.Download),
        )
        val fullScreen = route == "remote" || route == "account-signin"

        val gray = if (grayscale) Modifier.graphicsLayer {
            renderEffect = android.graphics.RenderEffect.createColorFilterEffect(
                android.graphics.ColorMatrixColorFilter(android.graphics.ColorMatrix().apply { setSaturation(0f) })
            ).asComposeRenderEffect()
        } else Modifier
        androidx.compose.runtime.CompositionLocalProvider(dev.stow.android.ui.LocalCalm provides calm, dev.stow.android.ui.LocalUpdateAvailable provides (update != null), dev.stow.android.ui.LocalChannelAvatars provides avatars) {
        Box(Modifier.fillMaxSize().then(gray)) {
        Column(Modifier.fillMaxSize()) {
            Box(Modifier.weight(1f)) {
                Snackbars(snackbar, Modifier.align(Alignment.BottomCenter).zIndex(1f))
                // Like YouTube: switching tabs is instant; a pushed screen (a channel, Settings, Search)
                // slides in from the right over the last one, which drifts left a little, and back
                // reverses it, following the back gesture on Android 14 and later.
                NavHost(nav, startDestination = "home",
                        enterTransition = {
                            if (isToTab()) EnterTransition.None
                            else slideIntoContainer(AnimatedContentTransitionScope.SlideDirection.Start, dev.stow.android.ui.Motion.enter(PUSH_MS))
                        },
                        exitTransition = {
                            if (isToTab()) ExitTransition.None
                            else slideOutOfContainer(AnimatedContentTransitionScope.SlideDirection.Start, dev.stow.android.ui.Motion.enter(PUSH_MS)) { it / 4 }
                        },
                        // Back uses an even curve, so a back gesture moves the screens as far as the finger has gone.
                        popEnterTransition = {
                            if (isTabSwitch()) EnterTransition.None
                            else slideIntoContainer(AnimatedContentTransitionScope.SlideDirection.End, tween(PUSH_MS, easing = dev.stow.android.ui.Motion.Standard)) { it / 4 }
                        },
                        popExitTransition = {
                            if (isTabSwitch()) ExitTransition.None
                            else slideOutOfContainer(AnimatedContentTransitionScope.SlideDirection.End, tween(PUSH_MS, easing = dev.stow.android.ui.Motion.Standard))
                        }) {
                    screen("home") {
                        HomeScreen(recommended, everything, groups, avatars, actions, todaySeconds = todaySeconds,
                                   onReport = { nav.navigate("report") },
                                   onSearch = { nav.navigate("search") }, onSettings = { nav.navigate("settings") },
                                   onRefresh = refresh, onNewGroup = { newGroup = true },
                                   onEditGroup = { nav.navigate("group/$it") },
                                   alarmMac = alarm?.takeIf { it.isRecent() && !standaloneMode }?.macName, onRemote = { nav.navigate("remote") },
                                   update = update?.version?.takeIf { it != dismissedUpdate }, onUpdate = { showUpdate = true },
                                   onHideUpdate = { update?.let { repository.prefs.dismissUpdate(it.version) } },
                                   standalone = standaloneHome)
                    }
                    screen("subscriptions") {
                        SubscriptionsScreen(subscriptionsFeed, subscribedChannels, actions,
                                            onAllChannels = { nav.navigate(if (standaloneMode) "channels-manage" else "channels") },
                                            onSearch = { nav.navigate("search") }, onSettings = { nav.navigate("settings") },
                                            onRefresh = refresh,
                                            emptyText = if (standaloneMode) {
                                                if (followedIds.isEmpty()) "Follow channels to see their new videos here." else "No videos yet. Pull down to check your channels."
                                            } else "No videos yet. Pull down to ask the Mac for new ones.")
                    }
                    screen("groups") {
                        dev.stow.android.ui.GroupsScreen(groups, groupActions, onOpen = { nav.navigate("group/$it") }, onBack = { nav.popBackStack() })
                    }
                    screen("group/{id}") { entry ->
                        val group = groups.firstOrNull { it.id == entry.arguments?.getString("id") }
                        dev.stow.android.ui.GroupScreen(group, knownChannels.map { dev.stow.android.data.GroupChannel(it.id, it.title) },
                                                        avatars, groupActions, onBack = { nav.popBackStack() })
                    }
                    screen("downloads") {
                        DownloadsScreen(
                            all = downloads, channels = channels, playlists = playlists, byId = itemsById,
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
                    screen("channels") {
                        val counts = everything.groupingBy { it.video.channelId }.eachCount()
                        ChannelsScreen(subscribedChannels, counts, onOpen = { nav.navigate("channel/$it") }, onBack = { nav.popBackStack() })
                    }
                    screen("channel/{id}") { entry ->
                        val id = entry.arguments?.getString("id")
                        val channel = channels.firstOrNull { it.id == id }
                        val page = id?.let { channelPages[it] }
                        var loading by remember(id) { mutableStateOf(false) }
                        var loadError by remember(id) { mutableStateOf<String?>(null) }
                        var attempt by remember(id) { mutableStateOf(0) }
                        // The last name and picture seen: after unfollowing, they stay while YouTube's page loads.
                        var knownTitle by remember(id) { mutableStateOf("") }
                        var knownAvatar by remember(id) { mutableStateOf<String?>(null) }
                        val followed = channel != null
                        // Not followed (on the Mac, or here): get its latest videos from YouTube here. Standalone,
                        // again when it stops being followed (removed from this page), so it shows them and Follow.
                        LaunchedEffect(id, dev.stow.android.ui.ChannelPageRules.loadKey(attempt, standaloneMode, followed)) {
                            if (id == null || !dev.stow.android.ui.ChannelPageRules.loads(followed)) return@LaunchedEffect
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
                        val currentTitle = channel?.title ?: knownChannels.firstOrNull { it.id == id }?.title ?: page?.title?.takeIf { it.isNotEmpty() }
                            ?: videos.firstOrNull()?.video?.channelTitle.orEmpty()
                        val currentAvatar = channel?.avatarUrl ?: page?.avatarUrl ?: avatars[id]
                        LaunchedEffect(currentTitle) { if (currentTitle.isNotEmpty()) knownTitle = currentTitle }
                        LaunchedEffect(currentAvatar) { if (currentAvatar != null) knownAvatar = currentAvatar }
                        val title = dev.stow.android.ui.ChannelPageRules.title(currentTitle, knownTitle)
                        val avatar = currentAvatar ?: knownAvatar
                        ChannelScreen(channel, title, videos, actions.copy(play = { item -> play(videos, item) }),
                                      groupNames = groups.filter { g -> g.channels.any { it.id == id } }.map { it.name },
                                      onGroups = { if (id != null) grouping = dev.stow.android.data.GroupChannel(id, title) },
                                      onBack = { nav.popBackStack() },
                                      page = page, loading = loading, loadError = loadError, onRetry = { attempt++ },
                                      avatarUrl = avatar,
                                      follow = if (standaloneMode && id != null) dev.stow.android.ui.FollowState(
                                          followed = id in followedIds,
                                          onFollow = { repository.follow(id, title, avatar, page?.handle) },
                                          onUnfollow = { repository.unfollow(id) },
                                      ) else null,
                                      onRefresh = if (standaloneMode) refresh else null)
                    }
                    screen("playlist/{id}") { entry ->
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
                    screen("search") {
                        val recentSearches by repository.prefs.recentSearches.collectAsStateWithLifecycle()
                        SearchScreen(everything, itemsById, recentSearches, actions,
                                     onSearch = { withContext(Dispatchers.IO) { repository.searchYouTube(it) } },
                                     onRemoveRecent = repository.prefs::removeRecentSearch,
                                     onPlay = { list, item -> play(list, item) },
                                     onBack = { nav.popBackStack() })
                    }
                    screen("settings") {
                        SettingsScreen(repository, updater, wifiOnly, onReport = { nav.navigate("report") },
                                       onRemote = { nav.navigate("remote") }, onGroups = { nav.navigate("groups") },
                                       onUpdate = { showUpdate = true }, onBack = { nav.popBackStack() },
                                       onSignIn = { nav.navigate("account-signin") }, onManageChannels = { nav.navigate("channels-manage") },
                                       onImport = { nav.navigate("import") }, notify = ::notify)
                    }
                    screen("account-signin") {
                        dev.stow.android.ui.SignInScreen(engine, onImportFile = { cookiesImport?.start?.invoke() },
                                                         onDone = { message -> notify(message); nav.popBackStack() },
                                                         onCancel = { nav.popBackStack() })
                    }
                    screen("channels-manage") {
                        val errors = checkStatus.channelErrors
                        dev.stow.android.ui.ManageChannelsScreen(
                            channels, errors, signedIn = account.state == dev.stow.android.standalone.AccountState.SIGNED_IN,
                            onOpen = { nav.navigate("channel/$it") }, onMove = engine::moveChannel, onRemove = repository::unfollow,
                            onGroups = { grouping = it }, onAdd = { addingChannel = true }, onImport = { nav.navigate("import") },
                            onBack = { nav.popBackStack() })
                    }
                    screen("import") {
                        dev.stow.android.ui.ImportChannelsScreen(
                            followedIds, load = engine::loadSubscriptions,
                            onAdd = { picked ->
                                val added = engine.addChannels(picked)
                                notify(if (added == 1) "Added 1 channel" else "Added $added channels")
                                nav.popBackStack()
                            },
                            onSignIn = { nav.navigate("account-signin") }, onBack = { nav.popBackStack() })
                    }
                    screen("remote") { RemoteScreen(remote, alarm?.macName, onBack = { nav.popBackStack() }) }
                    screen("report") {
                        val week = remember(statsVersion) { repository.stats.week() }
                        val lastWeek = remember(statsVersion) { repository.stats.week(java.time.LocalDate.now().minusDays(7)) }
                        ReportScreen(week, lastWeek, channels, onBack = { nav.popBackStack() })
                    }
                }
            }
            // The remote and the sign-in page take the whole screen: the tabs slide down out of the way
            // (and back up after), instead of vanishing.
            androidx.compose.animation.AnimatedVisibility(!fullScreen,
                enter = slideInVertically(dev.stow.android.ui.Motion.enter()) { it } + expandVertically(dev.stow.android.ui.Motion.enter()),
                exit = slideOutVertically(dev.stow.android.ui.Motion.exit()) { it } + shrinkVertically(dev.stow.android.ui.Motion.exit())) {
                Column {
                    // Room for the mini player, which is drawn over everything (it grows into the watch page);
                    // the lists above ease up or down as it comes and goes rather than jumping.
                    val miniSpace by animateDpAsState(if (current != null) dev.stow.android.ui.MiniPlayerHeight else 0.dp,
                                                      dev.stow.android.ui.Motion.enter(), label = "mini-space")
                    Spacer(Modifier.height(miniSpace))
                    // The tabs sink out of view as the watch page grows over them, and rise as it shrinks.
                    // A layer translation, so the measured height (where the mini player sits) stays put.
                    Box(Modifier.onSizeChanged { bottomBarHeight = with(density) { it.height.toDp() } }
                            .graphicsLayer { translationY = sheet.progress.value * size.height }) { BottomBar(tabs, route, nav) }
                }
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
                    openChannel = { id -> if (id.isNotEmpty()) { sheet.collapse(); nav.navigate("channel/$id") } },
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
        if (addingChannel) {
            dev.stow.android.ui.AddChannelDialog(
                onAdd = { input -> engine.addChannel(input).title },
                onAdded = { title -> addingChannel = false; notify("Following $title") },
                onDismiss = { addingChannel = false },
            )
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

    /** Where the screens' own snackbars show: they rise from the bottom and fade away, like YouTube's. */
    @Composable
    private fun Snackbars(state: androidx.compose.material3.SnackbarHostState, modifier: Modifier) {
        val data = state.currentSnackbarData
        // The same timing SnackbarHost gives (a short one, longer with accessibility timeouts).
        val accessibility = androidx.compose.ui.platform.LocalAccessibilityManager.current
        LaunchedEffect(data) {
            if (data == null) return@LaunchedEffect
            val millis = when (data.visuals.duration) {
                androidx.compose.material3.SnackbarDuration.Indefinite -> return@LaunchedEffect
                androidx.compose.material3.SnackbarDuration.Long -> 10_000L
                androidx.compose.material3.SnackbarDuration.Short -> 4_000L
            }
            kotlinx.coroutines.delay(accessibility?.calculateRecommendedTimeoutMillis(
                millis, containsIcons = true, containsText = true, containsControls = data.visuals.actionLabel != null) ?: millis)
            data.dismiss()
        }
        AnimatedContent(data, modifier, contentAlignment = Alignment.BottomCenter, transitionSpec = {
            (slideInVertically(dev.stow.android.ui.Motion.enter()) { it } + fadeIn(tween(dev.stow.android.ui.Motion.SHORT))) togetherWith
                (fadeOut(tween(dev.stow.android.ui.Motion.SHORT)) + slideOutVertically(dev.stow.android.ui.Motion.exit()) { it / 2 }) using
                SizeTransform(clip = false)
        }, label = "snackbar") { shown ->
            if (shown != null) {
                // Read out and dismissable by accessibility services, as SnackbarHost's are.
                androidx.compose.material3.Snackbar(shown, containerColor = Color(0xFF323232),
                    contentColor = Color.White, shape = RoundedCornerShape(8.dp),
                    modifier = Modifier.semantics {
                        liveRegion = androidx.compose.ui.semantics.LiveRegionMode.Polite
                        dismiss { shown.dismiss(); true }
                    })
            }
        }
    }

    companion object {
        /** How long a pushed screen takes to slide in. */
        private const val PUSH_MS = dev.stow.android.ui.Motion.LONG
        private val TAB_ROUTES = setOf("home", "subscriptions", "downloads")

        /** Between two tabs (not into or out of a pushed screen): YouTube switches those at once. */
        private fun AnimatedContentTransitionScope<NavBackStackEntry>.isTabSwitch() =
            initialState.destination.route in TAB_ROUTES && targetState.destination.route in TAB_ROUTES

        /**
         * Going forward to a tab only happens from the tab bar, and that's instant even from a pushed
         * screen (Settings, a channel), as in YouTube; going back to a tab still slides.
         */
        private fun AnimatedContentTransitionScope<NavBackStackEntry>.isToTab() =
            targetState.destination.route in TAB_ROUTES

        /**
         * A screen in the app's navigation, on its own background: pushed screens slide over the
         * one before, which mustn't show through.
         */
        private fun NavGraphBuilder.screen(route: String, content: @Composable (NavBackStackEntry) -> Unit) =
            composable(route) { entry -> Box(Modifier.fillMaxSize().background(Stow.colors.background)) { content(entry) } }

        /** The alarm notification's tap: opens the remote. */
        const val ACTION_OPEN_REMOTE = "dev.stow.android.OPEN_REMOTE"
        /** The "YouTube signed you out" notification's tap: opens Settings. */
        const val ACTION_OPEN_SETTINGS = "dev.stow.android.OPEN_SETTINGS"
        /** Debug builds: a screen to open at launch. */
        const val EXTRA_ROUTE = "stow.route"
        /** Downloads longer than this ask first, with the size. */
        const val LONG_VIDEO_MS = 20 * 60 * 1000L
    }

    private enum class Root {
        MODE, PAIR, MAC_SHELL, STANDALONE_SHELL;
        val isShell: Boolean get() = this == MAC_SHELL || this == STANDALONE_SHELL
    }

    private data class Tab(val route: String, val label: String, val selected: ImageVector, val unselected: ImageVector)

    @Composable
    private fun BottomBar(tabs: List<Tab>, route: String?, nav: NavHostController) {
        // A floating capsule, as in iOS: filled symbols, the selected tab in the accent on a soft highlight.
        // Follows the screen sliding in, rather than switching colour the moment it starts.
        val behind by animateColorAsState(if (route in setOf("settings", "groups", "group/{id}")) Stow.colors.groupedBackground else Stow.colors.background,
                                          tween(PUSH_MS), label = "behind")
        Box(Modifier.fillMaxWidth().drawBehind { drawRect(behind) }.navigationBarsPadding()
                .padding(start = 20.dp, end = 20.dp, top = 4.dp, bottom = 8.dp)) {
            Row(Modifier.fillMaxWidth().height(62.dp)
                    .shadow(10.dp, RoundedCornerShape(31.dp), ambientColor = Color.Black.copy(alpha = 0.18f), spotColor = Color.Black.copy(alpha = 0.18f))
                    .clip(RoundedCornerShape(31.dp)).background(Stow.colors.raised)
                    .border(0.5.dp, Stow.colors.divider.copy(alpha = 0.6f), RoundedCornerShape(31.dp))
                    .padding(4.dp)) {
                tabs.forEach { tab ->
                    val selected = route == tab.route
                    // The highlight and colour move to the new tab quickly; the screen itself switches at once.
                    val tint by animateColorAsState(if (selected) Stow.colors.accent else Stow.colors.text,
                                                    tween(dev.stow.android.ui.Motion.SHORT), label = "tab")
                    val highlight by animateColorAsState(if (selected) Stow.colors.chip else Color.Transparent,
                                                         tween(dev.stow.android.ui.Motion.SHORT), label = "tab-highlight")
                    Column(
                        Modifier.weight(1f).fillMaxSize().clip(RoundedCornerShape(27.dp))
                            .drawBehind { drawRect(highlight) }
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

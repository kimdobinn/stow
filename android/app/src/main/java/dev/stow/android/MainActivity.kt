package dev.stow.android

import android.Manifest
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
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
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import dev.stow.android.data.PairState
import dev.stow.android.data.VideoItem
import dev.stow.android.ui.ChannelScreen
import dev.stow.android.ui.ChannelsScreen
import dev.stow.android.ui.DownloadsScreen
import dev.stow.android.ui.Format
import dev.stow.android.ui.HomeScreen
import dev.stow.android.ui.MiniPlayer
import dev.stow.android.ui.PairScreen
import dev.stow.android.ui.PlayerScreen
import dev.stow.android.ui.PlaylistScreen
import dev.stow.android.ui.SaveToPlaylistSheet
import dev.stow.android.ui.SearchScreen
import dev.stow.android.ui.SettingsScreen
import dev.stow.android.ui.Stow
import dev.stow.android.ui.StowTheme
import dev.stow.android.ui.SubscriptionsScreen
import dev.stow.android.ui.VideoActions
import dev.stow.android.ui.sortedFor
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    private val app get() = application as StowApplication
    private val repository get() = app.repository

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        handle(intent)
        setContent {
            StowTheme {
                Surface(Modifier.fillMaxSize(), color = Stow.colors.background) { App() }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    /** stow://pair?… opened from the phone's camera app. */
    private fun handle(intent: Intent?) {
        val data = intent?.data ?: return
        if (data.scheme == "stow" && data.host == "pair") repository.pair(data.toString())
    }

    @Composable
    private fun App() {
        val pairState by repository.pairState.collectAsStateWithLifecycle()
        val notifications = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
        LaunchedEffect(Unit) { notifications.launch(Manifest.permission.POST_NOTIFICATIONS) }
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
        var saving by remember { mutableStateOf<VideoItem?>(null) }
        var storage by remember { mutableStateOf("") }

        val all = itemsById.values.toList()
        val feed = all.sortedByDescending { it.video.publishedAt?.time ?: it.sent?.sentAt?.time ?: 0 }
        LaunchedEffect(all.count { it.isPlayable }) {
            storage = withContext(Dispatchers.IO) { "${Format.bytes(repository.storageUsedBytes())} used on this phone" }
        }

        fun play(list: List<VideoItem>, start: VideoItem) {
            player.play(list, start)
            nav.navigate("watch") { launchSingleTop = true }
        }
        val actions = VideoActions(
            play = { item ->
                // Plays within the list you're looking at: the rest of it becomes Up next.
                val context = when (route) {
                    "downloads" -> all.filter { it.isPlayable }.sortedFor(sort)
                    else -> feed.filter { it.isPlayable }
                }
                play(context, item)
            },
            download = repository::download,
            delete = { item -> if (item.id == current) player.stop(); repository.deleteDownload(item.id) },
            setWatched = { item, watched -> repository.setWatched(item.id, watched) },
            saveToPlaylist = { saving = it },
            openChannel = { id -> nav.navigate("channel/$id") },
        )

        val tabs = listOf(
            Tab("home", "Home", Icons.Filled.Home, Icons.Outlined.Home),
            Tab("subscriptions", "Subscriptions", Icons.Filled.Subscriptions, Icons.Outlined.Subscriptions),
            Tab("downloads", "Downloads", Icons.Filled.Download, Icons.Outlined.Download),
        )
        val watching = route == "watch"

        Column(Modifier.fillMaxSize()) {
            Box(Modifier.weight(1f)) {
                NavHost(nav, startDestination = "home") {
                    composable("home") {
                        HomeScreen(feed, channels, actions, onSearch = { nav.navigate("search") }, onSettings = { nav.navigate("settings") })
                    }
                    composable("subscriptions") {
                        SubscriptionsScreen(feed, channels, actions, onAllChannels = { nav.navigate("channels") },
                                            onSearch = { nav.navigate("search") }, onSettings = { nav.navigate("settings") })
                    }
                    composable("downloads") {
                        DownloadsScreen(
                            all = all, channels = channels, playlists = playlists, byId = itemsById,
                            sort = sort, groupByChannel = group, storageText = storage, actions = actions,
                            onSort = repository.prefs::setDownloadSort, onGroup = repository.prefs::setGroupByChannel,
                            onOpenPlaylist = { nav.navigate("playlist/$it") },
                            onNewPlaylist = { repository.createPlaylist(it) },
                            onSearch = { nav.navigate("search") }, onSettings = { nav.navigate("settings") },
                        )
                    }
                    composable("channels") {
                        ChannelsScreen(channels, onOpen = { nav.navigate("channel/$it") },
                                       onAutoDownload = repository::setAutoDownload, onBack = { nav.popBackStack() })
                    }
                    composable("channel/{id}") { entry ->
                        val id = entry.arguments?.getString("id")
                        val channel = channels.firstOrNull { it.id == id }
                        val videos = channel?.recent?.mapNotNull { itemsById[it.video.id] }.orEmpty()
                        ChannelScreen(channel, videos, actions, onAutoDownload = { on -> id?.let { repository.setAutoDownload(it, on) } },
                                      onBack = { nav.popBackStack() })
                    }
                    composable("playlist/{id}") { entry ->
                        val playlist = playlists.firstOrNull { it.id == entry.arguments?.getString("id") }
                        val videos = playlist?.videoIds?.mapNotNull { itemsById[it] }.orEmpty()
                        PlaylistScreen(
                            playlist = playlist, videos = videos,
                            actions = actions.copy(
                                play = { item -> play(videos, item) },
                                removeFromPlaylist = { item -> playlist?.let { repository.playlistStore.remove(it.id, item.id) } },
                                move = { item, by -> playlist?.let { repository.playlistStore.move(it.id, item.id, by) } },
                            ),
                            onPlayAll = { shuffle ->
                                val list = videos.filter { it.isPlayable }.let { if (shuffle) it.shuffled() else it }
                                list.firstOrNull()?.let { play(list, it) }
                            },
                            onRename = { name -> playlist?.let { repository.playlistStore.rename(it.id, name) } },
                            onDelete = { playlist?.let { repository.playlistStore.delete(it.id) }; nav.popBackStack() },
                            onBack = { nav.popBackStack() },
                        )
                    }
                    composable("search") { SearchScreen(feed, actions, onBack = { nav.popBackStack() }) }
                    composable("settings") { SettingsScreen(repository, wifiOnly, onBack = { nav.popBackStack() }) }
                    composable("watch") {
                        val item = current?.let { itemsById[it] }
                        val index = queue.indexOf(current)
                        val upNext = if (index >= 0) queue.drop(index + 1).mapNotNull { itemsById[it] } else emptyList()
                        PlayerScreen(
                            connection = player, current = item, upNext = upNext,
                            channel = channels.firstOrNull { it.id == item?.video?.channelId },
                            actions = actions.copy(play = { next ->
                                // Up next: jump within the same queue.
                                player.play(queue.mapNotNull { itemsById[it] }, next)
                            }),
                            onCollapse = { nav.popBackStack() },
                        )
                        LaunchedEffect(current) { if (current == null) nav.popBackStack() }
                    }
                }
            }
            if (!watching) {
                val playing = current?.let { itemsById[it] }
                if (playing != null) MiniPlayer(player, playing, onOpen = { nav.navigate("watch") { launchSingleTop = true } })
                BottomBar(tabs, route, nav)
            }
        }

        saving?.let { item ->
            SaveToPlaylistSheet(
                item = itemsById[item.id] ?: item, playlists = playlists,
                onToggle = { playlist, add ->
                    if (add) repository.addToPlaylist(playlist.id, item) else repository.playlistStore.remove(playlist.id, item.id)
                },
                onCreate = { name -> repository.createPlaylist(name, item) },
                onDismiss = { saving = null },
            )
        }
    }

    private data class Tab(val route: String, val label: String, val selected: ImageVector, val unselected: ImageVector)

    @Composable
    private fun BottomBar(tabs: List<Tab>, route: String?, nav: NavHostController) {
        Column(Modifier.fillMaxWidth().background(Stow.colors.background).navigationBarsPadding()) {
            HorizontalDivider(color = Stow.colors.divider, thickness = 0.5.dp)
            Row(Modifier.fillMaxWidth().height(52.dp)) {
                tabs.forEach { tab ->
                    val selected = route == tab.route
                    Column(
                        Modifier.weight(1f).fillMaxWidth().clickable {
                            nav.navigate(tab.route) {
                                popUpTo("home") { saveState = true }
                                launchSingleTop = true
                                restoreState = true
                            }
                        }.padding(top = 6.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Icon(if (selected) tab.selected else tab.unselected, contentDescription = tab.label, tint = Stow.colors.text,
                             modifier = Modifier.size(24.dp))
                        Spacer(Modifier.height(2.dp))
                        Text(tab.label, fontSize = 10.sp, color = Stow.colors.text)
                    }
                }
            }
        }
    }
}

package dev.stow.android.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.Download
import androidx.compose.ui.focus.focusRequester
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.stow.android.data.Channel
import dev.stow.android.data.VideoItem
import dev.stow.android.sync.SyncWorker
import kotlinx.coroutines.delay

/** The logo bar of YouTube's Home and Subscriptions tabs. */
@Composable
fun LogoTopBar(onSearch: () -> Unit, onSettings: () -> Unit) {
    Row(Modifier.fillMaxWidth().statusBarsPadding().height(52.dp).padding(start = 14.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically) {
        StowLogo()
        Spacer(Modifier.weight(1f))
        IconButton(onClick = onSearch) { Icon(Icons.Filled.Search, contentDescription = "Search", tint = Stow.colors.text) }
        IconButton(onClick = onSettings) { Icon(Icons.Outlined.Settings, contentDescription = "Settings", tint = Stow.colors.text) }
    }
}

/** A plain title bar with a back arrow. */
@Composable
fun BackTopBar(title: String, onBack: () -> Unit, actions: @Composable () -> Unit = {}) {
    Row(Modifier.fillMaxWidth().statusBarsPadding().height(52.dp).padding(end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = Stow.colors.text) }
        Text(title, fontSize = 18.sp, fontWeight = FontWeight.Medium, color = Stow.colors.text, maxLines = 1,
             overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        actions()
    }
}

/** Pull down to ask Firebase for anything new. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun Refreshable(content: @Composable () -> Unit) {
    val context = LocalContext.current
    var refreshing by remember { mutableStateOf(false) }
    LaunchedEffect(refreshing) {
        if (refreshing) {
            SyncWorker.runNow(context)
            delay(1_200)
            refreshing = false
        }
    }
    PullToRefreshBox(isRefreshing = refreshing, onRefresh = { refreshing = true }, modifier = Modifier.fillMaxSize()) { content() }
}

private enum class HomeFilter(val label: String) { ALL("All"), DOWNLOADED("Downloaded") }

/**
 * What's new from your channels, newest first, then a clear end: "You're all caught up".
 * Watched videos stay folded away below it unless you ask for them.
 */
@Composable
fun HomeScreen(
    feed: List<VideoItem>, channels: List<Channel>, actions: VideoActions, todaySeconds: Long,
    onReport: () -> Unit, onSearch: () -> Unit, onSettings: () -> Unit,
) {
    var filter by rememberSaveable { mutableStateOf(HomeFilter.ALL) }
    var channelId by rememberSaveable { mutableStateOf<String?>(null) }
    var showWatched by rememberSaveable { mutableStateOf(false) }
    val avatars = channels.associate { it.id to it.avatarUrl }
    val matching = feed.filter { item ->
        (channelId == null || item.video.channelId == channelId) && (filter == HomeFilter.ALL || item.isPlayable)
    }
    val fresh = matching.filter { !it.watched }
    val watched = matching.filter { it.watched }
    Column(Modifier.fillMaxSize()) {
        LogoTopBar(onSearch, onSettings)
        ChipRow {
            HomeFilter.entries.forEach { f ->
                Chip(f.label, filter == f && channelId == null, onClick = { filter = f; channelId = null })
            }
            channels.forEach { c ->
                Chip(c.title, channelId == c.id, onClick = { channelId = if (channelId == c.id) null else c.id; filter = HomeFilter.ALL })
            }
        }
        Refreshable {
            LazyColumn(Modifier.fillMaxSize()) {
                items(fresh, key = { it.id }) { VideoCard(it, avatars[it.video.channelId], actions) }
                item(key = "caught-up") {
                    CaughtUp(todaySeconds, watched.size, showWatched, onToggle = { showWatched = !showWatched }, onReport = onReport)
                }
                if (showWatched) items(watched, key = { "w-" + it.id }) { VideoCard(it, avatars[it.video.channelId], actions) }
            }
        }
    }
}

/** The end of Home, instead of an endless feed. */
@Composable
private fun CaughtUp(todaySeconds: Long, watchedCount: Int, showingWatched: Boolean, onToggle: () -> Unit, onReport: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.size(56.dp).clip(CircleShape).background(Stow.colors.chip), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Check, contentDescription = null, tint = Stow.colors.text, modifier = Modifier.size(30.dp))
        }
        Spacer(Modifier.height(12.dp))
        Text("You're all caught up", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = Stow.colors.text)
        Spacer(Modifier.height(4.dp))
        Text("That's everything new from your channels.", fontSize = 14.sp, color = Stow.colors.secondaryText, textAlign = TextAlign.Center)
        Spacer(Modifier.height(4.dp))
        Text("Watched today: ${Format.minutes(todaySeconds)}", fontSize = 13.sp, color = Stow.colors.secondaryText,
             modifier = Modifier.clickable(onClick = onReport).padding(4.dp))
        if (watchedCount > 0) {
            Spacer(Modifier.height(8.dp))
            TextButton(onClick = onToggle) {
                Text(if (showingWatched) "Hide watched videos" else "Show watched videos ($watchedCount)", color = Color3D())
            }
        }
    }
}

/** Channel avatars on top, their videos below; "All" opens the channel list. */
@Composable
fun SubscriptionsScreen(
    feed: List<VideoItem>, channels: List<Channel>, actions: VideoActions,
    onAllChannels: () -> Unit, onSearch: () -> Unit, onSettings: () -> Unit,
) {
    var selected by rememberSaveable { mutableStateOf<String?>(null) }
    val avatars = channels.associate { it.id to it.avatarUrl }
    val shown = feed.filter { selected == null || it.video.channelId == selected }
    Column(Modifier.fillMaxSize()) {
        LogoTopBar(onSearch, onSettings)
        Row(verticalAlignment = Alignment.CenterVertically) {
            LazyRow(Modifier.weight(1f), contentPadding = PaddingValues(horizontal = 8.dp, vertical = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                items(channels, key = { it.id }) { channel ->
                    Column(
                        Modifier.width(72.dp).clip(androidx.compose.foundation.shape.RoundedCornerShape(8.dp))
                            .clickable { selected = if (selected == channel.id) null else channel.id }.padding(vertical = 4.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        val ring = if (selected == channel.id) Modifier.border(2.dp, Stow.colors.text, CircleShape).padding(3.dp) else Modifier.padding(3.dp)
                        Box(ring) { ChannelAvatar(channel.avatarUrl, 52.dp, name = channel.title) }
                        Spacer(Modifier.height(4.dp))
                        Text(channel.title, fontSize = 11.sp, color = if (selected == null || selected == channel.id) Stow.colors.text else Stow.colors.secondaryText,
                             maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
                    }
                }
            }
            TextButton(onClick = onAllChannels) { Text("All", color = Color3D(), fontWeight = FontWeight.Medium) }
        }
        selected?.let { id ->
            Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(channels.firstOrNull { it.id == id }?.title.orEmpty(), fontWeight = FontWeight.Medium, color = Stow.colors.text, modifier = Modifier.weight(1f))
                TextButton(onClick = { actions.openChannel(id) }) { Text("View channel", color = Color3D()) }
            }
        }
        Refreshable {
            LazyColumn(Modifier.fillMaxSize()) {
                if (shown.isEmpty()) item { EmptyState("No videos yet.") }
                items(shown, key = { it.id }) { VideoCard(it, avatars[it.video.channelId], actions) }
            }
        }
    }
}

/** YouTube's blue link color. */
@Composable
fun Color3D() = androidx.compose.material3.MaterialTheme.colorScheme.primary

/** Every channel, each with its auto-download switch. */
@Composable
fun ChannelsScreen(channels: List<Channel>, onOpen: (String) -> Unit, onAutoDownload: (String, Boolean) -> Unit, onBack: () -> Unit) {
    Column(Modifier.fillMaxSize()) {
        BackTopBar("All channels", onBack)
        LazyColumn(Modifier.fillMaxSize()) {
            item {
                Text("Turn on auto-download to get a channel's new uploads on this phone as soon as the Mac finds them.",
                     fontSize = 13.sp, color = Stow.colors.secondaryText, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
            }
            items(channels, key = { it.id }) { channel ->
                Row(Modifier.fillMaxWidth().clickable { onOpen(channel.id) }.padding(horizontal = 16.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    ChannelAvatar(channel.avatarUrl, 48.dp, name = channel.title)
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Text(channel.title, fontSize = 15.sp, fontWeight = FontWeight.Medium, color = Stow.colors.text, maxLines = 1)
                        Text(listOfNotNull(channel.handle, Format.count(channel.recent.size, "recent video")).joinToString(" · "),
                             fontSize = 12.sp, color = Stow.colors.secondaryText, maxLines = 1)
                    }
                    androidx.compose.material3.Switch(checked = channel.autoDownload, onCheckedChange = { onAutoDownload(channel.id, it) })
                }
            }
        }
    }
}

/** A channel's page: its header with the auto-download button, then its recent videos. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ChannelScreen(channel: Channel?, videos: List<VideoItem>, actions: VideoActions, onAutoDownload: (Boolean) -> Unit, onBack: () -> Unit) {
    var oldestFirst by rememberSaveable { mutableStateOf(false) }
    Column(Modifier.fillMaxSize()) {
        BackTopBar(channel?.title.orEmpty(), onBack)
        if (channel == null) {
            EmptyState("This channel isn't on the Mac anymore.")
            return
        }
        LazyColumn(Modifier.fillMaxSize()) {
            item {
                Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    ChannelAvatar(channel.avatarUrl, 72.dp, name = channel.title)
                    Spacer(Modifier.width(16.dp))
                    Column {
                        Text(channel.title, fontSize = 22.sp, fontWeight = FontWeight.Bold, color = Stow.colors.text)
                        Text(listOfNotNull(channel.handle, Format.count(channel.recent.size, "recent video")).joinToString(" · "),
                             fontSize = 13.sp, color = Stow.colors.secondaryText)
                    }
                }
                Column(Modifier.padding(horizontal = 16.dp)) {
                    if (channel.autoDownload) {
                        PillButton("Auto-downloading", Icons.Filled.Check,
                                   onClick = { onAutoDownload(false) })
                    } else {
                        PillButton("Auto-download new uploads", Icons.Outlined.Download,
                                   onClick = { onAutoDownload(true) }, filled = true)
                    }
                    Spacer(Modifier.height(6.dp))
                    Text(if (channel.autoDownload) "New uploads download to this phone automatically. Tap to stop."
                         else "Or tap any video below to download just that one.",
                         fontSize = 12.sp, color = Stow.colors.secondaryText)
                }
                ChipRow {
                    Chip("Latest", !oldestFirst, onClick = { oldestFirst = false })
                    Chip("Oldest", oldestFirst, onClick = { oldestFirst = true })
                }
            }
            val sorted = if (oldestFirst) videos.reversed() else videos
            if (sorted.isEmpty()) item { EmptyState("No recent videos.") }
            items(sorted, key = { it.id }) { item -> VideoRow(item, actions, showChannel = false) }
        }
    }
}

/** Searches every video's title and channel. */
@Composable
fun SearchScreen(all: List<VideoItem>, actions: VideoActions, onBack: () -> Unit) {
    var query by rememberSaveable { mutableStateOf("") }
    val focus = remember { androidx.compose.ui.focus.FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    val words = query.trim().lowercase().split(" ").filter { it.isNotEmpty() }
    val results = if (words.isEmpty()) emptyList() else all.filter { item ->
        val text = (item.video.title + " " + item.video.channelTitle).lowercase()
        words.all { it in text }
    }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().height(56.dp).padding(end = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = Stow.colors.text) }
            androidx.compose.foundation.text.BasicTextField(
                value = query, onValueChange = { query = it }, singleLine = true,
                textStyle = androidx.compose.ui.text.TextStyle(fontSize = 16.sp, color = Stow.colors.text),
                cursorBrush = androidx.compose.ui.graphics.SolidColor(Stow.colors.text),
                modifier = Modifier.weight(1f).focusRequester(focus).clip(androidx.compose.foundation.shape.RoundedCornerShape(50))
                    .background(Stow.colors.chip).padding(horizontal = 16.dp, vertical = 10.dp),
                decorationBox = { inner ->
                    if (query.isEmpty()) Text("Search your videos", color = Stow.colors.secondaryText, fontSize = 16.sp)
                    inner()
                },
            )
        }
        LazyColumn(Modifier.fillMaxSize()) {
            if (words.isNotEmpty() && results.isEmpty()) item { EmptyState("No videos match “${query.trim()}”.") }
            items(results, key = { it.id }) { VideoRow(it, actions) }
        }
    }
}

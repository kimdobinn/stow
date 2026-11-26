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
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.selection.selectable
import androidx.compose.material.icons.automirrored.rounded.ArrowBackIos
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.History
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.ui.draw.shadow
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Alarm
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
import dev.stow.android.data.ChannelGroup
import dev.stow.android.data.Feeds
import androidx.compose.material.icons.filled.Add
import dev.stow.android.data.VideoItem
import kotlinx.coroutines.delay

/** A tab's large title with its toolbar buttons (search, settings), as in iOS. */
@Composable
fun LargeTitleBar(title: String, onSearch: () -> Unit, onSettings: () -> Unit) {
    Row(Modifier.fillMaxWidth().statusBarsPadding().padding(start = 16.dp, end = 12.dp, top = 10.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = StowType.largeTitle, color = Stow.colors.text, modifier = Modifier.weight(1f),
             maxLines = 1, overflow = TextOverflow.Ellipsis)
        ToolbarButton(Icons.Rounded.Search, "Search", onSearch)
        Spacer(Modifier.width(10.dp))
        ToolbarButton(Icons.Rounded.Settings, "Settings", onSettings)
    }
}

/** A round toolbar button on a light fill. */
@Composable
fun ToolbarButton(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    Box(Modifier.size(44.dp).clip(CircleShape).background(Stow.colors.chip)
            .clickable(onClickLabel = label, role = androidx.compose.ui.semantics.Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center) {
        Icon(icon, contentDescription = label, tint = Stow.colors.text, modifier = Modifier.size(22.dp))
    }
}

/** A navigation bar: back on the left, the title centered, actions on the right. */
@Composable
fun BackTopBar(title: String, onBack: () -> Unit, actions: @Composable () -> Unit = {}) {
    Box(Modifier.fillMaxWidth().statusBarsPadding().height(52.dp)) {
        Box(Modifier.align(Alignment.CenterStart).padding(start = 8.dp).size(44.dp).clip(CircleShape)
                .clickable(onClickLabel = "Back", role = androidx.compose.ui.semantics.Role.Button, onClick = onBack),
            contentAlignment = Alignment.Center) {
            Icon(Icons.AutoMirrored.Rounded.ArrowBackIos, contentDescription = "Back", tint = Stow.colors.accent,
                 modifier = Modifier.size(22.dp).offset(x = 4.dp))
        }
        Text(title, style = StowType.headline, color = Stow.colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis,
             textAlign = TextAlign.Center, modifier = Modifier.align(Alignment.Center).padding(horizontal = 64.dp))
        Row(Modifier.align(Alignment.CenterEnd).padding(end = 4.dp), verticalAlignment = Alignment.CenterVertically) { actions() }
    }
}

/** Pull down: asks the Mac to check every channel and YouTube's feeds now, and waits for it. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun Refreshable(onRefresh: suspend () -> Unit = {}, content: @Composable () -> Unit) {
    var refreshing by remember { mutableStateOf(false) }
    LaunchedEffect(refreshing) {
        if (refreshing) {
            onRefresh()
            refreshing = false
        }
    }
    PullToRefreshBox(isRefreshing = refreshing, onRefresh = { refreshing = true }, modifier = Modifier.fillMaxSize()) { content() }
}

/**
 * Like YouTube's Home: everything YouTube recommends, from any channel. Chips after "All" are your
 * channel groups: one shows only its channels, newest first, ending in "You're all caught up".
 * Long-press a group's chip to edit it; "+" makes one.
 */
@Composable
fun HomeScreen(
    recommended: List<VideoItem>, everything: List<VideoItem>, groups: List<ChannelGroup>, avatars: Map<String, String?>,
    actions: VideoActions, todaySeconds: Long,
    onReport: () -> Unit, onSearch: () -> Unit, onSettings: () -> Unit,
    onRefresh: suspend () -> Unit, onNewGroup: () -> Unit, onEditGroup: (String) -> Unit,
    alarmMac: String? = null, onRemote: () -> Unit = {},
) {
    var groupId by rememberSaveable { mutableStateOf<String?>(null) }
    var showWatched by rememberSaveable { mutableStateOf(false) }
    val group = groups.firstOrNull { it.id == groupId }
    Column(Modifier.fillMaxSize()) {
        LargeTitleBar("Home", onSearch, onSettings)
        alarmMac?.let { AlarmBanner(it, onRemote) }
        ChipRow {
            Chip("All", group == null, onClick = { groupId = null })
            groups.forEach { g ->
                Chip(g.name, group?.id == g.id, onClick = { groupId = if (group?.id == g.id) null else g.id },
                     onLongClick = { onEditGroup(g.id) })
            }
            Chip(if (groups.isEmpty()) "New group" else "", false, onClick = onNewGroup,
                 leading = { Icon(Icons.Filled.Add, contentDescription = "New group", tint = Stow.colors.text, modifier = Modifier.size(18.dp)) })
        }
        Refreshable(onRefresh) {
            LazyColumn(Modifier.fillMaxSize()) {
                topAnchor()
                if (group == null) {
                    // YouTube's recommendations; your channels' newest until the Mac has shared them.
                    val videos = recommended.ifEmpty { everything.filter { !it.watched } }
                    if (recommended.isEmpty()) {
                        item(key = "no-recs") {
                            Text("YouTube's recommendations come through the Mac: keep Stow there signed in to YouTube. Until then, here's what's new from your channels.",
                                 style = StowType.footnote, color = Stow.colors.secondaryText, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
                        }
                    }
                    items(videos, key = { "all-" + it.id }) { VideoCard(it, avatars[it.video.channelId], actions) }
                    item(key = "end") {
                        Text(if (videos.isEmpty()) "Nothing here yet. Pull down to ask the Mac for videos." else "That's everything for now. Pull down for a fresh batch.",
                             style = StowType.footnote, color = Stow.colors.secondaryText, textAlign = TextAlign.Center,
                             modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 28.dp))
                    }
                } else {
                    val videos = Feeds.group(group, everything)
                    val fresh = videos.filter { !it.watched }
                    val watched = videos.filter { it.watched }
                    if (group.channels.isEmpty()) {
                        item(key = "empty-group") {
                            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                                EmptyState("“${group.name}” has no channels yet.")
                                TextButton(onClick = { onEditGroup(group.id) }) { Text("Add channels", color = Color3D()) }
                            }
                        }
                    } else {
                        items(fresh, key = { "g-" + it.id }) { VideoCard(it, avatars[it.video.channelId], actions) }
                        item(key = "caught-up") {
                            CaughtUp(todaySeconds, watched.size, showWatched, onToggle = { showWatched = !showWatched }, onReport = onReport,
                                     what = "That's everything new from ${group.name}.")
                        }
                        if (showWatched) items(watched, key = { "gw-" + it.id }) { VideoCard(it, avatars[it.video.channelId], actions) }
                    }
                }
            }
        }
    }
}

/** While the Mac's alarm plays (its push came in the last two hours): one tap to the remote. */
@Composable
private fun AlarmBanner(macName: String, onOpen: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp).clip(androidx.compose.foundation.shape.RoundedCornerShape(14.dp))
            .background(Stow.colors.chip).clickable(onClick = onOpen).padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Filled.Alarm, contentDescription = null, tint = Stow.colors.accent, modifier = Modifier.size(22.dp))
        Spacer(Modifier.width(12.dp))
        Text("Alarm playing on $macName", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = Stow.colors.text,
             maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        Text(" · Open remote", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = Color3D(), maxLines = 1)
    }
}

/** The end of Home, instead of an endless feed. */
@Composable
private fun CaughtUp(todaySeconds: Long, watchedCount: Int, showingWatched: Boolean, onToggle: () -> Unit, onReport: () -> Unit,
                     what: String = "That's everything new from your channels.") {
    Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.size(60.dp).clip(CircleShape).background(StowGradient), contentAlignment = Alignment.Center) {
            Icon(Icons.Rounded.Check, contentDescription = null, tint = androidx.compose.ui.graphics.Color.White, modifier = Modifier.size(32.dp))
        }
        Spacer(Modifier.height(14.dp))
        Text("You're All Caught Up", style = StowType.title3, color = Stow.colors.text)
        Spacer(Modifier.height(4.dp))
        Text(what, style = StowType.subheadline, color = Stow.colors.secondaryText, textAlign = TextAlign.Center)
        Spacer(Modifier.height(4.dp))
        Text("Watched today: ${Format.minutes(todaySeconds)}", style = StowType.footnote, color = Stow.colors.secondaryText,
             modifier = Modifier.clickable(onClick = onReport).padding(4.dp))
        if (watchedCount > 0) {
            Spacer(Modifier.height(8.dp))
            TextButton(onClick = onToggle) {
                Text(if (showingWatched) "Hide watched videos" else "Show watched videos ($watchedCount)", color = Color3D())
            }
        }
    }
}

/** A channel on the Subscriptions row: one of the Mac's, or one from YouTube's feed. */
data class SubscriptionChannel(val id: String, val title: String, val avatarUrl: String?)

/**
 * Like YouTube's Subscriptions: new videos from every channel you subscribe to (YouTube's feed) and
 * every channel on the Mac, newest first. Channel avatars on top filter it; "All" lists them.
 */
@Composable
fun SubscriptionsScreen(
    feed: List<VideoItem>, channels: List<SubscriptionChannel>, actions: VideoActions,
    onAllChannels: () -> Unit, onSearch: () -> Unit, onSettings: () -> Unit, onRefresh: suspend () -> Unit,
) {
    var selected by rememberSaveable { mutableStateOf<String?>(null) }
    val avatars = channels.associate { it.id to it.avatarUrl }
    val shown = feed.filter { selected == null || it.video.channelId == selected }
    Column(Modifier.fillMaxSize()) {
        LargeTitleBar("Subscriptions", onSearch, onSettings)
        Row(verticalAlignment = Alignment.CenterVertically) {
            LazyRow(Modifier.weight(1f), contentPadding = PaddingValues(horizontal = 8.dp, vertical = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                items(channels, key = { it.id }) { channel ->
                    Column(
                        Modifier.width(72.dp).clip(androidx.compose.foundation.shape.RoundedCornerShape(8.dp))
                            .clickable { selected = if (selected == channel.id) null else channel.id }.padding(vertical = 4.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        val ring = if (selected == channel.id) Modifier.border(2.dp, Stow.colors.accent, CircleShape).padding(3.dp) else Modifier.padding(3.dp)
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
        Refreshable(onRefresh) {
            LazyColumn(Modifier.fillMaxSize()) {
                topAnchor()
                if (shown.isEmpty()) item { EmptyState("No videos yet. Pull down to ask the Mac for new ones.") }
                items(shown, key = { it.id }) { VideoCard(it, avatars[it.video.channelId], actions) }
            }
        }
    }
}

/** Links and text buttons: the accent. */
@Composable
fun Color3D() = Stow.colors.accent

/** Every channel: the Mac's, then the rest you subscribe to. */
@Composable
fun ChannelsScreen(channels: List<SubscriptionChannel>, counts: Map<String, Int>, onOpen: (String) -> Unit, onBack: () -> Unit) {
    Column(Modifier.fillMaxSize()) {
        BackTopBar("All channels", onBack)
        LazyColumn(Modifier.fillMaxSize()) {
            items(channels, key = { it.id }) { channel ->
                Row(Modifier.fillMaxWidth().clickable { onOpen(channel.id) }.padding(horizontal = 16.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    ChannelAvatar(channel.avatarUrl, 48.dp, name = channel.title)
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Text(channel.title, fontSize = 15.sp, fontWeight = FontWeight.Medium, color = Stow.colors.text, maxLines = 1)
                        Text(Format.count(counts[channel.id] ?: 0, "recent video"), fontSize = 12.sp, color = Stow.colors.secondaryText, maxLines = 1)
                    }
                }
            }
        }
    }
}

private enum class ChannelTab(val label: String) { VIDEOS("Videos"), LIVE("Live") }

/** A channel's page: its header, then its videos, and its past live streams under Live, like YouTube. */
@Composable
fun ChannelScreen(
    channel: Channel?, title: String, videos: List<VideoItem>, actions: VideoActions,
    groupNames: List<String>, onGroups: () -> Unit, onBack: () -> Unit,
) {
    var oldestFirst by rememberSaveable { mutableStateOf(false) }
    var tab by rememberSaveable { mutableStateOf(ChannelTab.VIDEOS) }
    val (uploads, streams) = Feeds.split(videos)
    val listed = if (tab == ChannelTab.LIVE) streams else uploads
    Column(Modifier.fillMaxSize()) {
        BackTopBar(title, onBack)
        if (channel == null && videos.isEmpty()) {
            EmptyState("This channel isn't on the Mac anymore.")
            return
        }
        LazyColumn(Modifier.fillMaxSize()) {
            item {
                Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    ChannelAvatar(channel?.avatarUrl ?: LocalChannelAvatars.current[videos.firstOrNull()?.video?.channelId], 72.dp, name = title)
                    Spacer(Modifier.width(16.dp))
                    Column(Modifier.weight(1f)) {
                        Text(title, fontSize = 22.sp, fontWeight = FontWeight.Bold, color = Stow.colors.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        Text(listOfNotNull(channel?.handle, Format.count(videos.size, "recent video")).joinToString(" · "),
                             fontSize = 13.sp, color = Stow.colors.secondaryText)
                        Spacer(Modifier.height(6.dp))
                        PillButton(if (groupNames.isEmpty()) "Add to group" else groupNames.joinToString(", "),
                                   if (groupNames.isEmpty()) Icons.Filled.Add else Icons.Rounded.Check, onGroups)
                    }
                }
                if (channel == null) {
                    Text("Not followed on the Mac yet: these are its videos from your YouTube feeds and searches. Add it to a group and the Mac follows it.",
                         fontSize = 13.sp, color = Stow.colors.secondaryText, modifier = Modifier.padding(horizontal = 16.dp))
                }
                ChipRow {
                    ChannelTab.entries.forEach { t -> Chip(t.label, tab == t, onClick = { tab = t }) }
                    Spacer(Modifier.width(8.dp))
                    Chip("Latest", !oldestFirst, onClick = { oldestFirst = false })
                    Chip("Oldest", oldestFirst, onClick = { oldestFirst = true })
                }
            }
            val sorted = if (oldestFirst) listed.reversed() else listed
            if (sorted.isEmpty()) item { EmptyState(if (tab == ChannelTab.LIVE) "No past live streams." else "No recent videos.") }
            items(sorted, key = { it.id }) { item -> VideoRow(item, actions, showChannel = false) }
        }
    }
}

/**
 * Search, as in the YouTube app: as you type it suggests your recent searches and matching videos
 * you already have; search (the keyboard's button) looks through all of YouTube.
 */
@Composable
fun SearchScreen(
    yourVideos: List<VideoItem>, itemsById: Map<String, VideoItem>, recent: List<String>, actions: VideoActions,
    onSearch: suspend (String) -> List<String>, onRemoveRecent: (String) -> Unit,
    onPlay: (List<VideoItem>, VideoItem) -> Unit, onBack: () -> Unit,
) {
    var field by rememberSaveable(stateSaver = androidx.compose.ui.text.input.TextFieldValue.Saver) {
        mutableStateOf(androidx.compose.ui.text.input.TextFieldValue(""))
    }
    var submitted by rememberSaveable { mutableStateOf<String?>(null) }
    var resultIds by rememberSaveable { mutableStateOf<List<String>>(emptyList()) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val focus = remember { androidx.compose.ui.focus.FocusRequester() }
    val focusManager = androidx.compose.ui.platform.LocalFocusManager.current
    val keyboard = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    var job by remember { mutableStateOf<kotlinx.coroutines.Job?>(null) }

    fun search(text: String) {
        val q = text.trim()
        if (q.isEmpty()) return
        field = androidx.compose.ui.text.input.TextFieldValue(q, androidx.compose.ui.text.TextRange(q.length))
        submitted = q
        resultIds = emptyList()
        error = null
        loading = true
        keyboard?.hide()
        focusManager.clearFocus()
        job?.cancel()
        job = scope.launch {
            try {
                resultIds = onSearch(q)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                if (!isActive) return@launch
                error = e.message?.lineSequence()?.firstOrNull()?.removePrefix("ERROR: ")?.takeIf { it.isNotBlank() } ?: "Check the connection and try again."
            } finally {
                // A newer search replaced this one: it's still loading.
                if (isActive) loading = false
            }
        }
    }

    LaunchedEffect(Unit) {
        val last = submitted
        when {
            last == null -> focus.requestFocus()
            // Back after the app was closed: the results are gone, so search again.
            resultIds.none { it in itemsById } && !loading -> search(last)
        }
    }

    val query = field.text.trim()
    val showingResults = submitted != null && query == submitted
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().height(56.dp).padding(end = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = Stow.colors.text) }
            Row(Modifier.weight(1f).clip(androidx.compose.foundation.shape.RoundedCornerShape(50)).background(Stow.colors.chip)
                    .padding(start = 16.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                androidx.compose.foundation.text.BasicTextField(
                    value = field, onValueChange = { field = it }, singleLine = true,
                    textStyle = androidx.compose.ui.text.TextStyle(fontSize = 16.sp, color = Stow.colors.text),
                    cursorBrush = androidx.compose.ui.graphics.SolidColor(Stow.colors.text),
                    keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(imeAction = androidx.compose.ui.text.input.ImeAction.Search),
                    keyboardActions = androidx.compose.foundation.text.KeyboardActions(onSearch = { search(field.text) }),
                    modifier = Modifier.weight(1f).focusRequester(focus).padding(vertical = 10.dp),
                    decorationBox = { inner ->
                        if (field.text.isEmpty()) Text("Search YouTube", color = Stow.colors.secondaryText, fontSize = 16.sp)
                        inner()
                    },
                )
                if (field.text.isNotEmpty()) {
                    IconButton(onClick = { field = androidx.compose.ui.text.input.TextFieldValue(""); focus.requestFocus(); keyboard?.show() },
                               modifier = Modifier.size(36.dp)) {
                        Icon(Icons.Rounded.Close, contentDescription = "Clear", tint = Stow.colors.secondaryText, modifier = Modifier.size(20.dp))
                    }
                } else {
                    Spacer(Modifier.height(36.dp))
                }
            }
        }
        LazyColumn(Modifier.fillMaxSize()) {
            topAnchor()
            when {
                showingResults -> {
                    val results = resultIds.mapNotNull { itemsById[it] }
                    when {
                        loading -> item("loading") {
                            Box(Modifier.fillMaxWidth().padding(48.dp), contentAlignment = Alignment.Center) {
                                androidx.compose.material3.CircularProgressIndicator(color = Stow.colors.accent, strokeWidth = 3.dp,
                                                                                    modifier = Modifier.size(32.dp))
                            }
                        }
                        error != null -> item("error") {
                            Column(Modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                                Text("Couldn't search YouTube.", style = StowType.subheadline, color = Stow.colors.text)
                                Text(error.orEmpty(), style = StowType.footnote, color = Stow.colors.secondaryText, textAlign = TextAlign.Center,
                                     maxLines = 3, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 4.dp))
                                TextButton(onClick = { submitted?.let(::search) }) { Text("Try Again", color = Stow.colors.accent) }
                            }
                        }
                        results.isEmpty() -> item("none") { EmptyState("No videos found for “$submitted”.") }
                        else -> {
                            val resultActions = actions.copy(play = { onPlay(results, it) })
                            items(results, key = { "r-" + it.id }) { VideoCard(it, LocalChannelAvatars.current[it.video.channelId], resultActions) }
                            item("note") { EmptyState("Shorts and live streams are left out.", PaddingValues(24.dp)) }
                        }
                    }
                }
                query.isEmpty() -> {
                    if (recent.isEmpty()) {
                        item("hint") { EmptyState("Search all of YouTube. Shorts and live streams are left out.") }
                    }
                    items(recent, key = { "h-$it" }) { text -> SuggestionRow(text, history = true, onClick = { search(text) }, onRemove = { onRemoveRecent(text) }) }
                }
                else -> {
                    item("search-for") { SuggestionRow(query, history = false, onClick = { search(query) }) }
                    val words = query.lowercase().split(" ").filter { it.isNotEmpty() }
                    val pastMatches = recent.filter { r -> !r.equals(query, ignoreCase = true) && words.all { it in r.lowercase() } }.take(5)
                    items(pastMatches, key = { "h-$it" }) { text -> SuggestionRow(text, history = true, onClick = { search(text) }, onRemove = { onRemoveRecent(text) }) }
                    val yours = yourVideos.filter { item ->
                        val text = (item.video.title + " " + item.video.channelTitle).lowercase()
                        words.all { it in text }
                    }
                    if (yours.isNotEmpty()) {
                        item("yours") {
                            Text("Your videos", style = StowType.footnote, fontWeight = FontWeight.SemiBold, color = Stow.colors.secondaryText,
                                 modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 6.dp))
                        }
                        items(yours, key = { "y-" + it.id }) { VideoRow(it, actions) }
                    }
                }
            }
        }
    }
}

/** A search suggestion: a past search (with a clock, removable) or "search for what you typed". */
@Composable
private fun SuggestionRow(text: String, history: Boolean, onClick: () -> Unit, onRemove: (() -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(start = 16.dp, end = 4.dp).height(52.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(if (history) Icons.Rounded.History else Icons.Rounded.Search, contentDescription = null,
             tint = Stow.colors.secondaryText, modifier = Modifier.size(22.dp))
        Spacer(Modifier.width(16.dp))
        Text(text, fontSize = 16.sp, color = Stow.colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        if (onRemove != null) {
            IconButton(onClick = onRemove) {
                Icon(Icons.Rounded.Close, contentDescription = "Remove “$text”", tint = Stow.colors.secondaryText, modifier = Modifier.size(18.dp))
            }
        }
    }
}

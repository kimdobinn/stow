package dev.stow.android.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.stow.android.data.Channel
import dev.stow.android.data.GroupChannel
import dev.stow.android.standalone.ChannelInfo
import dev.stow.android.standalone.ImportSelection
import dev.stow.android.standalone.SignedOutByYouTube
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Settings › Your channels (standalone): the channels this phone follows, in order. Tap one to
 * open it; ⋯ (or a long press) moves it, puts it in a group or removes it. "+" adds one by URL,
 * @handle or channel ID; "Import" picks from your YouTube subscriptions when signed in.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ManageChannelsScreen(
    channels: List<Channel>, errors: Map<String, String>, signedIn: Boolean,
    onOpen: (String) -> Unit, onMove: (String, Int) -> Unit, onRemove: (String) -> Unit, onGroups: (GroupChannel) -> Unit,
    onAdd: () -> Unit, onImport: () -> Unit, onBack: () -> Unit,
) {
    Column(Modifier.fillMaxSize().background(Stow.colors.groupedBackground)) {
        BackTopBar("Your channels", onBack) {
            if (signedIn) TextButton(onClick = onImport) { Text("Import", color = Stow.colors.accent) }
            IconButton(onClick = onAdd) { Icon(Icons.Filled.Add, contentDescription = "Add a channel", tint = Stow.colors.accent) }
        }
        LazyColumn(Modifier.fillMaxSize()) {
            if (channels.isEmpty()) {
                item {
                    Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        EmptyState("No channels yet. Add one by its URL or @handle, follow one from its page, or import your YouTube subscriptions.")
                        PillButton("Add a channel", Icons.Filled.Add, onAdd, filled = true)
                        if (signedIn) {
                            Spacer(Modifier.height(8.dp))
                            TextButton(onClick = onImport) { Text("Import from YouTube", color = Stow.colors.accent) }
                        }
                    }
                }
            } else {
                item {
                    Text("Stow checks these for new videos. The order here is the order everywhere.",
                         style = StowType.footnote, color = Stow.colors.secondaryText, modifier = Modifier.padding(horizontal = 32.dp, vertical = 8.dp))
                }
                item {
                    Column(Modifier.padding(horizontal = 16.dp).clip(RoundedCornerShape(14.dp)).background(Stow.colors.raised)) {
                        channels.forEachIndexed { index, channel ->
                            var menu by remember { mutableStateOf(false) }
                            Row(Modifier.fillMaxWidth().combinedClickable(onClick = { onOpen(channel.id) }, onLongClick = { menu = true })
                                    .padding(start = 16.dp, end = 4.dp, top = 8.dp, bottom = 8.dp),
                                verticalAlignment = Alignment.CenterVertically) {
                                ChannelAvatar(channel.avatarUrl, 40.dp, name = channel.title)
                                Spacer(Modifier.width(12.dp))
                                Column(Modifier.weight(1f)) {
                                    Text(channel.title, style = StowType.body, color = Stow.colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    val error = errors[channel.id]
                                    Text(error ?: listOfNotNull(channel.handle, Format.count(channel.recent.size, "recent video")).joinToString(" · "),
                                         style = StowType.footnote, color = if (error != null) Color(0xFFFF3B30) else Stow.colors.secondaryText,
                                         maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                                Box {
                                    IconButton(onClick = { menu = true }) {
                                        Icon(Icons.Rounded.MoreHoriz, contentDescription = "More", tint = Stow.colors.secondaryText)
                                    }
                                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                                        if (index > 0) DropdownMenuItem(text = { Text("Move up") }, onClick = { menu = false; onMove(channel.id, -1) })
                                        if (index < channels.lastIndex) DropdownMenuItem(text = { Text("Move down") }, onClick = { menu = false; onMove(channel.id, 1) })
                                        DropdownMenuItem(text = { Text("Add to a group") }, onClick = { menu = false; onGroups(GroupChannel(channel.id, channel.title)) })
                                        DropdownMenuItem(text = { Text("Remove channel", color = Color(0xFFFF3B30)) }, onClick = { menu = false; onRemove(channel.id) })
                                    }
                                }
                            }
                            if (index < channels.lastIndex) HorizontalDivider(Modifier.padding(start = 68.dp), thickness = 0.5.dp, color = Stow.colors.divider)
                        }
                    }
                }
                item { Spacer(Modifier.height(32.dp)) }
            }
        }
    }
}

/** "+": a channel by its URL, @handle or ID (or any of its videos' URLs). */
@Composable
fun AddChannelDialog(onAdd: suspend (String) -> String, onAdded: (String) -> Unit, onDismiss: () -> Unit) {
    var text by rememberSaveable { mutableStateOf("") }
    var adding by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
    fun add() {
        val input = text.trim()
        if (input.isEmpty() || adding) return
        adding = true
        error = null
        scope.launch {
            try {
                onAdded(withContext(Dispatchers.IO) { onAdd(input) })
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                error = e.message?.lineSequence()?.firstOrNull()?.removePrefix("ERROR: ") ?: "Check the connection and try again."
            } finally {
                adding = false
            }
        }
    }
    AlertDialog(
        onDismissRequest = { if (!adding) onDismiss() },
        title = { Text("Add a channel") },
        text = {
            Column {
                OutlinedTextField(
                    value = text, onValueChange = { text = it; error = null }, singleLine = true, enabled = !adding,
                    placeholder = { Text("Channel URL, @handle or channel ID") },
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { add() }),
                    modifier = Modifier.fillMaxWidth().focusRequester(focus),
                )
                when {
                    adding -> Row(Modifier.padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = Stow.colors.accent)
                        Spacer(Modifier.width(8.dp))
                        Text("Looking it up…", fontSize = 14.sp, color = Stow.colors.secondaryText)
                    }
                    error != null -> Text(error.orEmpty(), fontSize = 14.sp, color = Color(0xFFFF3B30), modifier = Modifier.padding(top = 8.dp))
                }
            }
        },
        confirmButton = { TextButton(onClick = ::add, enabled = text.isNotBlank() && !adding) { Text("Add") } },
        dismissButton = { TextButton(onClick = onDismiss, enabled = !adding) { Text("Cancel") } },
    )
}

/**
 * Import from YouTube: your subscriptions, nothing ticked (Stow never adds them all by itself);
 * ones already followed show as added.
 */
@Composable
fun ImportChannelsScreen(
    followed: Set<String>, load: suspend () -> List<ChannelInfo>, onAdd: (List<ChannelInfo>) -> Unit, onSignIn: () -> Unit, onBack: () -> Unit,
) {
    var channels by remember { mutableStateOf<List<ChannelInfo>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var signedOut by remember { mutableStateOf(false) }
    var attempt by remember { mutableStateOf(0) }
    var selection by remember { mutableStateOf(ImportSelection()) }
    var query by rememberSaveable { mutableStateOf("") }
    LaunchedEffect(attempt) {
        error = null
        signedOut = false
        try {
            channels = withContext(Dispatchers.IO) { load() }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: SignedOutByYouTube) {
            signedOut = true
        } catch (e: Exception) {
            error = e.message ?: "Check the connection and try again."
        }
    }
    val all = channels.orEmpty()
    val shown = all.filter { c -> query.isBlank() || query.trim().lowercase().split(" ").all { w -> w in (c.title + " " + c.handle.orEmpty()).lowercase() } }
    Column(Modifier.fillMaxSize().background(Stow.colors.groupedBackground)) {
        BackTopBar("Import from YouTube", onBack) {
            if (all.isNotEmpty()) {
                val allPicked = all.any { it.id !in followed } && all.filter { it.id !in followed }.all { selection.isPicked(it.id) }
                TextButton(onClick = { selection = if (allPicked) selection.selectNone() else selection.selectAll(all, followed) }) {
                    Text(if (allPicked) "Select none" else "Select all", color = Stow.colors.accent)
                }
            }
        }
        when {
            signedOut -> Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                EmptyState("YouTube signed you out. Sign in again to see your subscriptions.")
                PillButton("Sign in", null, onSignIn, filled = true)
            }
            error != null -> Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text("Couldn't get your subscriptions from YouTube.", style = StowType.subheadline, color = Stow.colors.text, textAlign = TextAlign.Center)
                Text(error.orEmpty(), style = StowType.footnote, color = Stow.colors.secondaryText, textAlign = TextAlign.Center,
                     maxLines = 3, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 4.dp))
                TextButton(onClick = { attempt++ }) { Text("Try Again", color = Stow.colors.accent) }
            }
            channels == null -> Box(Modifier.fillMaxWidth().padding(48.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = Stow.colors.accent, strokeWidth = 3.dp, modifier = Modifier.size(32.dp))
            }
            all.isEmpty() -> EmptyState("No subscriptions on this YouTube account.")
            else -> {
                Row(Modifier.padding(horizontal = 16.dp, vertical = 4.dp).fillMaxWidth().clip(RoundedCornerShape(50)).background(Stow.colors.chip)
                        .padding(horizontal = 16.dp, vertical = 10.dp)) {
                    androidx.compose.foundation.text.BasicTextField(
                        value = query, onValueChange = { query = it }, singleLine = true,
                        textStyle = androidx.compose.ui.text.TextStyle(fontSize = 16.sp, color = Stow.colors.text),
                        cursorBrush = androidx.compose.ui.graphics.SolidColor(Stow.colors.text),
                        modifier = Modifier.weight(1f),
                        decorationBox = { inner ->
                            if (query.isEmpty()) Text("Search your subscriptions", color = Stow.colors.secondaryText, fontSize = 16.sp)
                            inner()
                        },
                    )
                }
                LazyColumn(Modifier.weight(1f).fillMaxWidth()) {
                    items(shown, key = { it.id }) { channel ->
                        val added = selection.isAdded(channel.id, followed)
                        Row(Modifier.fillMaxWidth().clickable(enabled = !added) { selection = selection.toggle(channel.id, followed) }
                                .padding(horizontal = 12.dp, vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically) {
                            Checkbox(checked = added || selection.isPicked(channel.id), enabled = !added,
                                     onCheckedChange = { selection = selection.toggle(channel.id, followed) })
                            ChannelAvatar(channel.avatarUrl, 36.dp, name = channel.title)
                            Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text(channel.title, style = StowType.body, color = Stow.colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                val detail = listOfNotNull(channel.handle, "Added".takeIf { added }).joinToString(" · ")
                                if (detail.isNotEmpty()) Text(detail, style = StowType.footnote, color = Stow.colors.secondaryText, maxLines = 1)
                            }
                        }
                    }
                }
                Box(Modifier.fillMaxWidth().background(Stow.colors.groupedBackground).navigationBarsPadding()
                        .padding(horizontal = 16.dp, vertical = 10.dp), contentAlignment = Alignment.Center) {
                    val count = selection.count
                    val enabled = count > 0
                    Row(Modifier.fillMaxWidth().height(48.dp).clip(RoundedCornerShape(24.dp))
                            .background(if (enabled) Stow.colors.accent else Stow.colors.chip)
                            .clickable(enabled = enabled) { onAdd(selection.chosen(all)) },
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = androidx.compose.foundation.layout.Arrangement.Center) {
                        Text(if (count == 1) "Add 1 channel" else "Add $count channels", style = StowType.headline,
                             color = if (enabled) Color.White else Stow.colors.secondaryText)
                    }
                }
            }
        }
    }
}

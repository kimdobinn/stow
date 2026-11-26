package dev.stow.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.RemoveCircle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.stow.android.data.ChannelGroup
import dev.stow.android.data.GroupChannel

/** What the group screens can do (Repository's group functions). */
data class GroupActions(
    val create: (String, GroupChannel?) -> ChannelGroup,
    val rename: (String, String) -> Unit,
    val delete: (String) -> Unit,
    val setChannel: (String, GroupChannel, Boolean) -> Unit,
    val move: (String, Int) -> Unit,
)

/** "Add channel to a group": a checkbox per group, and a new group with this channel in it. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GroupPickerSheet(channel: GroupChannel, groups: List<ChannelGroup>, actions: GroupActions, notify: (String) -> Unit, onDismiss: () -> Unit) {
    var creating by remember { mutableStateOf(false) }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = Stow.colors.raised) {
        Column(Modifier.fillMaxWidth().padding(bottom = 24.dp)) {
            Text("Add ${channel.title} to…", style = StowType.headline, color = Stow.colors.text,
                 maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp))
            groups.forEach { group ->
                val included = group.channels.any { it.id == channel.id }
                fun toggle(on: Boolean) {
                    actions.setChannel(group.id, channel, on)
                    notify(if (on) "Added to ${group.name}" else "Removed from ${group.name}")
                }
                Row(Modifier.fillMaxWidth().clickable { toggle(!included) }.padding(horizontal = 12.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = included, onCheckedChange = ::toggle)
                    Text(group.name, color = Stow.colors.text, style = StowType.body, modifier = Modifier.weight(1f))
                    Text(Format.count(group.channels.size, "channel"), color = Stow.colors.secondaryText, style = StowType.footnote,
                         modifier = Modifier.padding(end = 12.dp))
                }
            }
            if (groups.isNotEmpty()) HorizontalDivider(Modifier.padding(vertical = 8.dp), color = Stow.colors.divider)
            Row(Modifier.fillMaxWidth().clickable { creating = true }.padding(horizontal = 20.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Add, contentDescription = null, tint = Stow.colors.accent)
                Spacer(Modifier.width(16.dp))
                Text("New group", color = Stow.colors.accent, style = StowType.body, fontWeight = FontWeight.Medium)
            }
            Text("Home can show just a group's channels. The Mac adds any channel it doesn't follow yet.",
                 style = StowType.footnote, color = Stow.colors.secondaryText, modifier = Modifier.padding(horizontal = 20.dp))
        }
    }
    if (creating) NameDialog("New group", "", onDismiss = { creating = false }) { name ->
        actions.create(name, channel)
        notify("Added to $name")
        creating = false
    }
}

/** Settings › Channel groups: every group, to open, reorder or add. */
@Composable
fun GroupsScreen(groups: List<ChannelGroup>, actions: GroupActions, onOpen: (String) -> Unit, onBack: () -> Unit) {
    var creating by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().background(Stow.colors.groupedBackground)) {
        BackTopBar("Channel groups", onBack) {
            IconButton(onClick = { creating = true }) { Icon(Icons.Filled.Add, contentDescription = "New group", tint = Stow.colors.accent) }
        }
        LazyColumn(Modifier.fillMaxSize()) {
            item {
                Text("Pick a group on Home to see only its channels, newest first.",
                     style = StowType.footnote, color = Stow.colors.secondaryText, modifier = Modifier.padding(horizontal = 32.dp, vertical = 8.dp))
            }
            if (groups.isEmpty()) {
                item { EmptyState("No groups yet. Tap + to make one, or use “Add channel to a group” on any video.") }
            } else {
                item {
                    Column(Modifier.padding(horizontal = 16.dp).clip(RoundedCornerShape(12.dp)).background(Stow.colors.raised)) {
                        groups.forEachIndexed { index, group ->
                            Row(Modifier.fillMaxWidth().clickable { onOpen(group.id) }.padding(start = 16.dp, end = 8.dp).height(52.dp),
                                verticalAlignment = Alignment.CenterVertically) {
                                Text(group.name, style = StowType.body, color = Stow.colors.text, modifier = Modifier.weight(1f),
                                     maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(Format.count(group.channels.size, "channel"), style = StowType.subheadline, color = Stow.colors.secondaryText)
                                Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = Stow.colors.secondaryText)
                            }
                            if (index < groups.lastIndex) HorizontalDivider(Modifier.padding(start = 16.dp), color = Stow.colors.divider)
                        }
                    }
                }
            }
        }
    }
    if (creating) NameDialog("New group", "", onDismiss = { creating = false }) { name ->
        val group = actions.create(name, null)
        creating = false
        onOpen(group.id)
    }
}

/** One group: rename it, its channels (remove, add from any channel Stow knows), delete it. */
@Composable
fun GroupScreen(
    group: ChannelGroup?, knownChannels: List<GroupChannel>, avatars: Map<String, String?>,
    actions: GroupActions, onBack: () -> Unit,
) {
    if (group == null) {
        Column(Modifier.fillMaxSize()) {
            BackTopBar("Group", onBack)
            EmptyState("This group was deleted.")
        }
        return
    }
    var renaming by remember { mutableStateOf(false) }
    var adding by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().background(Stow.colors.groupedBackground)) {
        BackTopBar(group.name, onBack) {
            TextButton(onClick = { renaming = true }) { Text("Rename", color = Stow.colors.accent) }
        }
        LazyColumn(Modifier.fillMaxSize()) {
            item { SectionLabel("Channels") }
            item {
                Column(Modifier.padding(horizontal = 16.dp).clip(RoundedCornerShape(12.dp)).background(Stow.colors.raised)) {
                    group.channels.forEach { channel ->
                        Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp).height(56.dp), verticalAlignment = Alignment.CenterVertically) {
                            ChannelAvatar(avatars[channel.id], 32.dp, name = channel.title)
                            Spacer(Modifier.width(12.dp))
                            Text(channel.title, style = StowType.body, color = Stow.colors.text, modifier = Modifier.weight(1f),
                                 maxLines = 1, overflow = TextOverflow.Ellipsis)
                            IconButton(onClick = { actions.setChannel(group.id, channel, false) }) {
                                Icon(Icons.Rounded.RemoveCircle, contentDescription = "Remove ${channel.title}", tint = Color(0xFFFF3B30))
                            }
                        }
                        HorizontalDivider(Modifier.padding(start = 60.dp), color = Stow.colors.divider)
                    }
                    Row(Modifier.fillMaxWidth().clickable { adding = true }.padding(horizontal = 16.dp).height(52.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.Add, contentDescription = null, tint = Stow.colors.accent)
                        Spacer(Modifier.width(12.dp))
                        Text("Add channels", style = StowType.body, color = Stow.colors.accent)
                    }
                }
            }
            item {
                Text("Any video's ⋯ menu can add its channel too. Channels the Mac doesn't follow yet get added there (with Morning off).",
                     style = StowType.footnote, color = Stow.colors.secondaryText, modifier = Modifier.padding(horizontal = 32.dp, vertical = 8.dp))
            }
            item {
                Spacer(Modifier.height(16.dp))
                Row(Modifier.padding(horizontal = 16.dp).fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Stow.colors.raised)
                        .clickable { deleting = true }.padding(horizontal = 16.dp).height(52.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Text("Delete group", style = StowType.body, color = Color(0xFFFF3B30))
                }
                Spacer(Modifier.height(32.dp))
            }
        }
    }
    if (renaming) NameDialog("Rename group", group.name, onDismiss = { renaming = false }) { actions.rename(group.id, it); renaming = false }
    if (adding) AddChannelsSheet(group, knownChannels, avatars, actions, onDismiss = { adding = false })
    if (deleting) {
        AlertDialog(
            onDismissRequest = { deleting = false },
            title = { Text("Delete “${group.name}”?") },
            text = { Text("The channels stay; only the group goes.") },
            confirmButton = { TextButton(onClick = { deleting = false; actions.delete(group.id); onBack() }) { Text("Delete", color = Color(0xFFFF3B30)) } },
            dismissButton = { TextButton(onClick = { deleting = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(text.uppercase(), style = StowType.footnote, color = Stow.colors.secondaryText,
         modifier = Modifier.padding(start = 32.dp, end = 32.dp, top = 16.dp, bottom = 6.dp))
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AddChannelsSheet(group: ChannelGroup, known: List<GroupChannel>, avatars: Map<String, String?>, actions: GroupActions, onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = Stow.colors.raised) {
        Text("Add to ${group.name}", style = StowType.headline, color = Stow.colors.text,
             modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp))
        if (known.isEmpty()) EmptyState("No channels yet: they come from the Mac and your YouTube feeds.")
        LazyColumn(Modifier.fillMaxWidth().padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(0.dp)) {
            items(known, key = { it.id }) { channel ->
                val included = group.channels.any { it.id == channel.id }
                Row(Modifier.fillMaxWidth().clickable { actions.setChannel(group.id, channel, !included) }.padding(horizontal = 12.dp, vertical = 2.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = included, onCheckedChange = { actions.setChannel(group.id, channel, it) })
                    ChannelAvatar(avatars[channel.id], 32.dp, name = channel.title)
                    Spacer(Modifier.width(12.dp))
                    Text(channel.title, style = StowType.body, color = Stow.colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis,
                         modifier = Modifier.weight(1f))
                }
            }
        }
    }
}

/** Long streams can be several GB: the size first, then download or not. */
@Composable
fun DownloadSizeDialog(title: String, durationMs: Long, sizeBytes: Long?, checking: Boolean, onDownload: () -> Unit, onDismiss: () -> Unit) {
    val size = when {
        sizeBytes != null -> Format.bytes(sizeBytes)
        checking -> null
        else -> "about " + Format.bytes(dev.stow.android.data.Feeds.estimatedBytes(durationMs))
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Download ${Format.duration(durationMs)} video?") },
        text = {
            Column {
                Text(title, maxLines = 2, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.Medium)
                Spacer(Modifier.height(8.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (size == null) {
                        androidx.compose.material3.CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(8.dp))
                        Text("Checking the size…", fontSize = 15.sp)
                    } else {
                        Text("Size: $size (up to 1080p)", fontSize = 15.sp)
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDownload) { Text("Download", fontWeight = FontWeight.SemiBold) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

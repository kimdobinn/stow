package dev.stow.android.ui

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material.icons.outlined.ThumbUp
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.KeyboardArrowUp
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
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
import dev.stow.android.data.Comment
import dev.stow.android.data.CommentsPage
import dev.stow.android.data.Video

private sealed interface CommentsState {
    data object Loading : CommentsState
    data class Loaded(val page: CommentsPage) : CommentsState
    data object Failed : CommentsState
}

/**
 * YouTube's comments teaser under the watch page's actions: the count and the top comment; tap
 * for all of them in a sheet. Loads when the video opens (saved comments at once).
 */
@Composable
fun CommentsCard(video: Video, load: suspend (Video, Boolean) -> CommentsPage) {
    var state by remember(video.id) { mutableStateOf<CommentsState>(CommentsState.Loading) }
    var attempt by remember(video.id) { mutableIntStateOf(0) }
    var open by remember(video.id) { mutableStateOf(false) }
    LaunchedEffect(video.id, attempt) {
        state = CommentsState.Loading
        state = runCatching { load(video, attempt > 0) }.fold({ CommentsState.Loaded(it) }, { CommentsState.Failed })
    }
    val current = state
    Column(Modifier.padding(horizontal = 16.dp, vertical = 6.dp).fillMaxWidth().clip12().background(Stow.colors.chip)
            .clickable {
                when (current) {
                    is CommentsState.Loaded -> if (current.page.threads.isNotEmpty()) open = true
                    CommentsState.Failed -> attempt++
                    CommentsState.Loading -> {}
                }
            }
            .padding(horizontal = 14.dp, vertical = 12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Comments", style = StowType.subheadline, fontWeight = FontWeight.SemiBold, color = Stow.colors.text)
            (current as? CommentsState.Loaded)?.page?.shownCount?.let {
                Spacer(Modifier.width(6.dp))
                Text(Format.shortCount(it), style = StowType.subheadline, color = Stow.colors.secondaryText)
            }
        }
        Spacer(Modifier.height(8.dp))
        when (current) {
            CommentsState.Loading -> Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = Stow.colors.secondaryText)
                Spacer(Modifier.width(8.dp))
                Text("Loading comments…", style = StowType.footnote, color = Stow.colors.secondaryText)
            }
            CommentsState.Failed ->
                Text("Couldn't load the comments. Tap to try again.", style = StowType.footnote, color = Stow.colors.secondaryText)
            is CommentsState.Loaded -> {
                val top = current.page.threads.firstOrNull()
                if (top == null) {
                    Text("No comments yet, or they're turned off.", style = StowType.footnote, color = Stow.colors.secondaryText)
                } else Row(verticalAlignment = Alignment.CenterVertically) {
                    ChannelAvatar(top.authorThumbnail, 24.dp, name = top.author.removePrefix("@"))
                    Spacer(Modifier.width(10.dp))
                    Text(top.text, style = StowType.footnote, color = Stow.colors.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
    if (open && current is CommentsState.Loaded) {
        CommentsSheet(current.page, onRefresh = { attempt++ }, onDismiss = { open = false })
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CommentsSheet(page: CommentsPage, onRefresh: () -> Unit, onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                     containerColor = Stow.colors.raised) {
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Comments", style = StowType.headline, color = Stow.colors.text)
                Spacer(Modifier.width(8.dp))
                Text(page.shownCount?.let(Format::shortCount) ?: "Top", style = StowType.subheadline,
                     color = Stow.colors.secondaryText, modifier = Modifier.weight(1f))
                Text("Refresh", style = StowType.subheadline, fontWeight = FontWeight.SemiBold, color = Stow.colors.accent,
                     modifier = Modifier.clickable { onRefresh() }.padding(6.dp))
            }
            HorizontalDivider(thickness = 0.5.dp, color = Stow.colors.divider)
            LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(18.dp),
                       contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp)) {
                items(page.threads, key = { it.id }) { CommentThread(it) }
            }
        }
    }
}

@Composable
private fun CommentThread(thread: Comment) {
    var showReplies by remember(thread.id) { mutableStateOf(false) }
    Column(Modifier.animateContentSize()) {
        CommentRow(thread, 32)
        if (thread.replies.isNotEmpty()) {
            Row(Modifier.padding(start = 42.dp, top = 6.dp).clip12().clickable { showReplies = !showReplies }
                    .padding(vertical = 4.dp, horizontal = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(if (showReplies) Icons.Rounded.KeyboardArrowUp else Icons.Rounded.KeyboardArrowDown, contentDescription = null,
                     tint = Stow.colors.accent, modifier = Modifier.size(20.dp))
                Text(if (thread.replies.size == 1) "1 reply" else "${thread.replies.size} replies", style = StowType.footnote,
                     fontWeight = FontWeight.SemiBold, color = Stow.colors.accent)
            }
            if (showReplies) {
                Column(Modifier.padding(start = 42.dp, top = 8.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    thread.replies.forEach { CommentRow(it, 24) }
                }
            }
        }
    }
}

@Composable
private fun CommentRow(comment: Comment, avatar: Int) {
    var showAll by remember(comment.id) { mutableStateOf(false) }
    val long = comment.text.length > 300 || comment.text.count { it == '\n' } >= 5
    Row {
        ChannelAvatar(comment.authorThumbnail, avatar.dp, name = comment.author.removePrefix("@"))
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            if (comment.isPinned) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.PushPin, contentDescription = null, tint = Stow.colors.secondaryText, modifier = Modifier.size(12.dp))
                    Spacer(Modifier.width(4.dp))
                    Text("Pinned", style = StowType.caption, color = Stow.colors.secondaryText)
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                val name = Modifier.then(if (comment.byUploader) Modifier.clip12().background(Stow.colors.chip).padding(horizontal = 6.dp) else Modifier)
                Text(comment.author, style = StowType.caption, fontWeight = FontWeight.SemiBold, color = Stow.colors.text, modifier = name)
                comment.postedAt?.let {
                    Text("  ·  " + Format.ago(java.util.Date(it * 1000)), style = StowType.caption, color = Stow.colors.secondaryText)
                }
            }
            Spacer(Modifier.height(2.dp))
            Text(comment.text, style = StowType.subheadline, color = Stow.colors.text,
                 maxLines = if (long && !showAll) 5 else Int.MAX_VALUE, overflow = TextOverflow.Ellipsis)
            if (long) {
                Text(if (showAll) "Show less" else "Read more", style = StowType.footnote, fontWeight = FontWeight.SemiBold,
                     color = Stow.colors.secondaryText, modifier = Modifier.clickable { showAll = !showAll }.padding(vertical = 3.dp))
            }
            Row(Modifier.padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.ThumbUp, contentDescription = "Likes", tint = Stow.colors.secondaryText, modifier = Modifier.size(14.dp))
                if (comment.likes > 0) {
                    Spacer(Modifier.width(5.dp))
                    Text(Format.shortCount(comment.likes), style = StowType.caption, color = Stow.colors.secondaryText)
                }
                if (comment.isHearted) {
                    Spacer(Modifier.width(12.dp))
                    Icon(Icons.Rounded.Favorite, contentDescription = "Hearted by the channel", tint = Color(0xFFFF3B30), modifier = Modifier.size(14.dp))
                }
            }
        }
    }
}

private fun Modifier.clip12() = clip(RoundedCornerShape(12.dp))

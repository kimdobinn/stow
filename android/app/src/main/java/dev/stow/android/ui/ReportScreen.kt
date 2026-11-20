package dev.stow.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.stow.android.data.Channel
import dev.stow.android.data.VideoItem
import dev.stow.android.data.WatchStats
import java.time.format.TextStyle
import java.util.Locale

/** A channel that keeps sending videos you don't watch. */
data class SkippedChannel(val channel: Channel, val sent: Int, val watched: Int)

/** Channels with auto-download on whose recent sent videos you mostly didn't watch. */
fun skippedChannels(channels: List<Channel>, items: Collection<VideoItem>): List<SkippedChannel> {
    val monthAgo = System.currentTimeMillis() - 30L * 86_400_000
    return channels.filter { it.autoDownload }.mapNotNull { channel ->
        val recent = items.filter { it.video.channelId == channel.id && (it.sent?.sentAt?.time ?: 0) > monthAgo }
        val watched = recent.count { it.watched }
        SkippedChannel(channel, recent.size, watched).takeIf { recent.size >= 3 && watched * 10 < recent.size * 3 }
    }
}

/** This week's watching: total, per day, per channel, and channels worth dropping. */
@Composable
fun ReportScreen(
    thisWeek: List<WatchStats.Day>, lastWeek: List<WatchStats.Day>, channels: List<Channel>,
    skipped: List<SkippedChannel>, onAutoDownloadOff: (String) -> Unit, onBack: () -> Unit,
) {
    val total = thisWeek.sumOf { it.seconds }
    val previous = lastWeek.sumOf { it.seconds }
    val titles = channels.associate { it.id to it.title }
    val byChannel = thisWeek.flatMap { it.secondsByChannel.entries }.groupBy({ it.key }, { it.value })
        .mapValues { it.value.sum() }.entries.sortedByDescending { it.value }
    val finished = thisWeek.flatMap { it.finishedByChannel.entries }.groupBy({ it.key }, { it.value }).mapValues { it.value.sum() }
    val most = (thisWeek.maxOfOrNull { it.seconds } ?: 0).coerceAtLeast(60)
    val channelMax = byChannel.firstOrNull()?.value?.coerceAtLeast(60) ?: 60

    Column(Modifier.fillMaxSize()) {
        BackTopBar("Your week", onBack)
        LazyColumn(Modifier.fillMaxSize()) {
            item {
                Column(Modifier.padding(16.dp)) {
                    Text(Format.minutes(total), fontSize = 34.sp, fontWeight = FontWeight.Bold, color = Stow.colors.text)
                    val change = when {
                        previous == 0L -> "in the last 7 days"
                        total <= previous -> "${Format.minutes(previous - total)} less than the week before"
                        else -> "${Format.minutes(total - previous)} more than the week before"
                    }
                    Text(change, fontSize = 14.sp, color = Stow.colors.secondaryText)
                }
                // One bar per day; today is the last.
                Row(Modifier.fillMaxWidth().height(150.dp).padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalAlignment = Alignment.Bottom) {
                    thisWeek.forEachIndexed { i, day ->
                        Column(Modifier.weight(1f).fillMaxHeight(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Bottom) {
                            Text(if (day.seconds >= 60) "${day.seconds / 60}" else "", fontSize = 11.sp, color = Stow.colors.secondaryText)
                            val fraction = (day.seconds.toFloat() / most).coerceIn(0.02f, 1f)
                            Box(Modifier.fillMaxWidth().fillMaxHeight(fraction * 0.8f).clip(RoundedCornerShape(topStart = 4.dp, topEnd = 4.dp))
                                    .background(if (i == thisWeek.lastIndex) ProgressRed else Stow.colors.secondaryText.copy(alpha = 0.45f)))
                            Spacer(Modifier.height(4.dp))
                            Text(day.date.dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.getDefault()), fontSize = 11.sp, color = Stow.colors.secondaryText)
                        }
                    }
                }
                Text("Minutes per day", fontSize = 11.sp, color = Stow.colors.secondaryText, modifier = Modifier.padding(start = 16.dp, top = 4.dp))
                SectionHeader("By channel")
                if (byChannel.isEmpty()) EmptyState("Nothing watched this week yet.")
            }
            items(byChannel, key = { it.key }) { (channelId, seconds) ->
                Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        ChannelAvatar(channels.firstOrNull { it.id == channelId }?.avatarUrl, 28.dp, name = titles[channelId].orEmpty())
                        Spacer(Modifier.width(10.dp))
                        Text(titles[channelId] ?: "Other", fontSize = 15.sp, fontWeight = FontWeight.Medium, color = Stow.colors.text, modifier = Modifier.weight(1f))
                        Text(listOfNotNull(Format.minutes(seconds), finished[channelId]?.let { Format.count(it, "video") }).joinToString(" · "),
                             fontSize = 13.sp, color = Stow.colors.secondaryText)
                    }
                    Box(Modifier.padding(start = 38.dp, top = 6.dp).fillMaxWidth().height(4.dp).clip(RoundedCornerShape(2.dp)).background(Stow.colors.chip)) {
                        Box(Modifier.fillMaxWidth((seconds.toFloat() / channelMax).coerceIn(0.02f, 1f)).height(4.dp).background(ProgressRed))
                    }
                }
            }
            if (skipped.isNotEmpty()) {
                item { SectionHeader("Worth a look") }
                items(skipped, key = { "s-" + it.channel.id }) { s ->
                    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                        ChannelAvatar(s.channel.avatarUrl, 36.dp, name = s.channel.title)
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(s.channel.title, fontSize = 15.sp, fontWeight = FontWeight.Medium, color = Stow.colors.text)
                            Text("You watched ${s.watched} of its last ${s.sent} videos", fontSize = 12.sp, color = Stow.colors.secondaryText)
                        }
                        PillButton("Stop auto-download", null, onClick = { onAutoDownloadOff(s.channel.id) })
                    }
                }
            }
            item { Spacer(Modifier.height(24.dp)) }
        }
    }
}

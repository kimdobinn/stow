package dev.stow.android.ui

import android.text.format.DateUtils
import java.util.Date
import dev.stow.android.data.VideoItem

object Format {
    /** "1 video", "3 videos". */
    fun count(n: Int, noun: String): String = "$n ${if (n == 1) noun else noun + "s"}"

    /** "Channel · 3 days ago" (· "Members only"). */
    fun meta(item: VideoItem, withDuration: Boolean = false): String =
        listOf(item.video.channelTitle, ago(item.video.publishedAt),
               if (withDuration && item.durationMs > 0) duration(item.durationMs) else "",
               if (item.video.isMembersOnly) "Members only" else "")
            .filter { it.isNotEmpty() }.joinToString(" · ")

    /** "1 h 5 min", "42 min", "0 min". */
    fun minutes(seconds: Long): String {
        if (seconds in 1..59) return "<1 min"
        val minutes = seconds / 60
        return if (minutes >= 60) "${minutes / 60} h ${minutes % 60} min" else "$minutes min"
    }

    fun duration(ms: Long): String {
        val total = ms / 1000
        val h = total / 3600
        val m = (total % 3600) / 60
        val s = total % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
    }

    fun ago(date: Date?): String =
        date?.let { DateUtils.getRelativeTimeSpanString(it.time, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString() } ?: ""

    fun bytes(bytes: Long): String = when {
        bytes >= 1L shl 30 -> "%.1f GB".format(bytes / (1L shl 30).toDouble())
        bytes >= 1L shl 20 -> "%.0f MB".format(bytes / (1L shl 20).toDouble())
        else -> "${bytes / 1024} KB"
    }
}

package dev.stow.android.data

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject
import java.io.File
import java.time.LocalDate

/** Seconds watched per day and channel, plus videos finished, kept 90 days on the phone. */
class WatchStats(context: Context) {
    data class Day(val date: LocalDate, val secondsByChannel: Map<String, Long>, val finishedByChannel: Map<String, Int>) {
        val seconds: Long get() = secondsByChannel.values.sum()
    }

    private val file = File(context.filesDir, "stats.json")
    private var days: MutableMap<LocalDate, Day> = load()
    private val _changes = MutableStateFlow(0)
    /** Bumps on every change, so screens can recompute. */
    val changes: StateFlow<Int> = _changes.asStateFlow()
    private var unsaved = 0L

    @Synchronized
    fun addSeconds(channelId: String, seconds: Long) {
        val today = LocalDate.now()
        val day = days[today] ?: Day(today, emptyMap(), emptyMap())
        days[today] = day.copy(secondsByChannel = day.secondsByChannel + (channelId to (day.secondsByChannel[channelId] ?: 0) + seconds))
        unsaved += seconds
        // A write every half minute of watching is plenty.
        if (unsaved >= 30) save()
        _changes.value++
    }

    @Synchronized
    fun addFinished(channelId: String) {
        val today = LocalDate.now()
        val day = days[today] ?: Day(today, emptyMap(), emptyMap())
        days[today] = day.copy(finishedByChannel = day.finishedByChannel + (channelId to (day.finishedByChannel[channelId] ?: 0) + 1))
        save()
        _changes.value++
    }

    @Synchronized
    fun day(date: LocalDate): Day = days[date] ?: Day(date, emptyMap(), emptyMap())

    /** The 7 days ending `end` (oldest first). */
    fun week(end: LocalDate = LocalDate.now()): List<Day> = (6 downTo 0).map { day(end.minusDays(it.toLong())) }

    @Synchronized
    fun flush() = save()

    private fun save() {
        unsaved = 0
        val cutoff = LocalDate.now().minusDays(90)
        days.keys.filter { it < cutoff }.forEach(days::remove)
        val root = JSONObject()
        for ((date, day) in days) {
            root.put(date.toString(), JSONObject().apply {
                put("seconds", JSONObject(day.secondsByChannel.mapValues { it.value }))
                put("finished", JSONObject(day.finishedByChannel.mapValues { it.value }))
            })
        }
        val temp = File(file.parentFile, "stats.json.tmp")
        temp.writeText(root.toString())
        temp.renameTo(file)
    }

    private fun load(): MutableMap<LocalDate, Day> = runCatching {
        val root = JSONObject(file.readText())
        root.keys().asSequence().associate { key ->
            val date = LocalDate.parse(key)
            val o = root.getJSONObject(key)
            val seconds = o.optJSONObject("seconds")?.let { s -> s.keys().asSequence().associateWith { s.getLong(it) } }.orEmpty()
            val finished = o.optJSONObject("finished")?.let { f -> f.keys().asSequence().associateWith { f.getInt(it) } }.orEmpty()
            date to Day(date, seconds, finished)
        }.toMutableMap()
    }.getOrDefault(mutableMapOf())
}

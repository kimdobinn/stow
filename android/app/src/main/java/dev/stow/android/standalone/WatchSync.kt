package dev.stow.android.standalone

import org.json.JSONObject

/**
 * Watched videos follow YouTube's watch history (the Mac's `WatchSync`): history entries that
 * appeared on top since the last read become watched here; videos watched here are marked
 * watched on YouTube with yt-dlp. Unwatching stays here (YouTube can't unwatch).
 */
object WatchSync {
    const val HISTORY_LIMIT = 50
    const val ANCHOR_COUNT = 10
    const val PUSHES_PER_SYNC = 10
    const val INTERVAL_MS = 15 * 60 * 1000L

    /** The entries of `history` above the newest of `previous`'s first 10 that it still lists. A first read is all new. */
    fun newlyWatched(history: List<String>, previous: List<String>): List<String> {
        for (anchor in previous.take(ANCHOR_COUNT)) {
            val index = history.indexOf(anchor)
            if (index >= 0) return history.subList(0, index).toList()
        }
        return history
    }

    /** The history playlist's video ids (yt-dlp -J of :ythistory), newest first, without repeats. */
    fun parseHistory(json: String): List<String> {
        val entries = JSONObject(json).optJSONArray("entries") ?: return emptyList()
        val seen = LinkedHashSet<String>()
        for (i in 0 until entries.length()) {
            entries.optJSONObject(i)?.optString("id")?.takeIf { it.isNotEmpty() }?.let(seen::add)
        }
        return seen.toList()
    }
}

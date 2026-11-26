package dev.stow.android.data

import org.json.JSONArray
import org.json.JSONObject

/** A YouTube comment (from yt-dlp's `comments` list), with its replies when it starts a thread. */
data class Comment(
    val id: String,
    val author: String,
    val authorThumbnail: String?,
    val text: String,
    val likes: Long,
    /** Seconds since 1970. */
    val postedAt: Long?,
    val isPinned: Boolean = false,
    /** Written by the video's channel. */
    val byUploader: Boolean = false,
    /** The channel gave it a heart. */
    val isHearted: Boolean = false,
    val replies: List<Comment> = emptyList(),
)

/** A video's top comments in YouTube's "Top" order, and YouTube's count of all of them. */
data class CommentsPage(val threads: List<Comment>, val totalCount: Long?) {
    /**
     * YouTube's count of all comments, when yt-dlp gave it. With a limit on how many to fetch it
     * reports just the number fetched, which would read as the total.
     */
    val shownCount: Long? get() = totalCount?.takeIf { it > threads.size + threads.sumOf { t -> t.replies.size } }
}

object Comments {
    /**
     * Reads yt-dlp's `-j --write-comments` answer, or the trimmed copy [trim] saves. Replies are
     * grouped under their thread in order; ones whose thread is missing are dropped.
     */
    fun parse(json: String): CommentsPage {
        val root = JSONObject(json)
        val raw = root.optJSONArray("comments") ?: JSONArray()
        val threads = mutableListOf<Comment>()
        val replies = linkedMapOf<String, MutableList<Comment>>()
        for (i in 0 until raw.length()) {
            val o = raw.optJSONObject(i) ?: continue
            val id = o.optString("id").ifEmpty { null } ?: continue
            if (!o.has("text") || o.isNull("text")) continue
            val comment = Comment(
                id = id, author = o.optString("author"),
                authorThumbnail = o.optString("author_thumbnail").ifEmpty { null },
                text = o.optString("text"), likes = o.optLong("like_count"),
                postedAt = if (o.has("timestamp") && !o.isNull("timestamp")) o.optLong("timestamp") else null,
                isPinned = o.optBoolean("is_pinned"), byUploader = o.optBoolean("author_is_uploader"),
                isHearted = o.optBoolean("is_favorited"),
            )
            val parent = o.optString("parent", "root")
            if (parent == "root") threads += comment else replies.getOrPut(parent) { mutableListOf() } += comment
        }
        val total = if (root.has("comment_count") && !root.isNull("comment_count")) root.optLong("comment_count") else null
        return CommentsPage(threads.map { it.copy(replies = replies[it.id].orEmpty()) }, total)
    }

    /** Just the comments and their count from yt-dlp's answer (which also lists every format), to keep. */
    fun trim(json: String): String {
        val root = JSONObject(json)
        return JSONObject().apply {
            put("comments", root.optJSONArray("comments") ?: JSONArray())
            if (root.has("comment_count") && !root.isNull("comment_count")) put("comment_count", root.optLong("comment_count"))
        }.toString()
    }
}

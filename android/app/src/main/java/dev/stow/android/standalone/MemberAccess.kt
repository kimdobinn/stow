package dev.stow.android.standalone

import org.json.JSONObject

/** Whether the signed-in account's membership level can watch a members-only video (the Mac's `MemberAccess`). */
sealed interface MemberAccess {
    data object Watchable : MemberAccess
    /** Needs a higher membership level (YouTube's name for it, when it says). Without one, the account isn't a member. */
    data class Locked(val level: String?) : MemberAccess
    /** Was for members first and is public now. */
    data object NowPublic : MemberAccess

    val canWatch: Boolean get() = this == Watchable || this == NowPublic

    /** standalone.json's form: "watchable", "nowPublic", "locked" or "locked:<level>". */
    val stored: String
        get() = when (this) {
            Watchable -> "watchable"
            NowPublic -> "nowPublic"
            is Locked -> if (level == null) "locked" else "locked:$level"
        }

    companion object {
        fun parse(text: String?): MemberAccess? = when {
            text == null -> null
            text == "watchable" -> Watchable
            text == "nowPublic" -> NowPublic
            text == "locked" -> Locked(null)
            text.startsWith("locked:") -> Locked(text.removePrefix("locked:").ifEmpty { null })
            else -> null
        }

        /** A lookup that worked: still for members, or public now. */
        fun fromLookup(json: String): MemberAccess =
            when (runCatching { JSONObject(json).optString("availability") }.getOrNull()) {
                "public", "unlisted" -> NowPublic
                else -> Watchable
            }

        /** What a failed lookup says: the level a locked video needs, or watchable (it failed only picking a format). Null when it can't tell. */
        fun fromError(text: String): MemberAccess? {
            val marker = "members on level: "
            val at = text.indexOf(marker)
            if (at >= 0) {
                val rest = text.substring(at + marker.length)
                val end = rest.indexOf(" (or any higher level)").takeIf { it >= 0 }
                    ?: rest.indexOfFirst { it == '.' || it == '\n' }.takeIf { it >= 0 } ?: rest.length
                return Locked(rest.substring(0, end).trim().ifEmpty { null })
            }
            val lowered = text.lowercase()
            if (listOf("join this channel to get access", "members-only content", "this video is not available", "video unavailable")
                    .any { it in lowered }) return Locked(null)
            if ("requested format is not available" in lowered || "only images are available" in lowered) return Watchable
            return null
        }
    }
}

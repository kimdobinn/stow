package dev.stow.android.update

import org.json.JSONObject

/** A phone release on GitHub: tag v<version> with the signed APK as an asset (see android/release.sh). */
data class Release(
    val version: String,
    val notes: String,
    val apkName: String,
    val apkUrl: String,
    val apkSize: Long,
) {
    fun toJson(): String = JSONObject()
        .put("version", version).put("notes", notes)
        .put("apkName", apkName).put("apkUrl", apkUrl).put("apkSize", apkSize)
        .toString()

    companion object {
        /** Reads what [toJson] wrote (null if it's missing or unreadable). */
        fun fromJson(json: String?): Release? = json?.let {
            runCatching {
                val o = JSONObject(it)
                Release(o.getString("version"), o.optString("notes"), o.getString("apkName"), o.getString("apkUrl"), o.getLong("apkSize"))
            }.getOrNull()
        }

        private val androidTag = Regex("""v(\d+(?:\.\d+)*)""")

        /**
         * A release from GitHub's API (`/releases/latest`, or one entry of `/releases`). Null for what
         * isn't a phone release: drafts, pre-releases (the iPhone's ios-v* and the Mac's mac-v*), tags
         * not of the form v1.2.3, and releases without an APK. Prefers the asset named Stow-<version>.apk.
         */
        fun parse(json: JSONObject): Release? {
            if (json.optBoolean("draft") || json.optBoolean("prerelease")) return null
            val version = androidTag.matchEntire(json.optString("tag_name"))?.groupValues?.get(1) ?: return null
            val assets = json.optJSONArray("assets") ?: return null
            val apks = (0 until assets.length()).map { assets.getJSONObject(it) }.filter {
                it.optString("name").endsWith(".apk", ignoreCase = true) &&
                    it.optString("browser_download_url").startsWith("http") &&
                    it.optLong("size") > 0 &&
                    it.optString("state", "uploaded") == "uploaded"
            }
            val apk = apks.firstOrNull { it.optString("name") == "Stow-$version.apk" } ?: apks.firstOrNull() ?: return null
            return Release(
                version = version,
                notes = json.optString("body").replace("\r\n", "\n").trim(),
                apkName = apk.getString("name"),
                apkUrl = apk.getString("browser_download_url"),
                apkSize = apk.getLong("size"),
            )
        }

        fun parse(json: String): Release? = parse(JSONObject(json))
    }
}

object Versions {
    /**
     * Compares dotted versions number by number, so 0.10.0 > 0.9.1 and 1.0 == 1.0.0. Anything after
     * a part's digits (1.2.0-debug) is ignored.
     */
    fun compare(a: String, b: String): Int {
        val x = parts(a)
        val y = parts(b)
        for (i in 0 until maxOf(x.size, y.size)) {
            val c = x.getOrElse(i) { 0 }.compareTo(y.getOrElse(i) { 0 })
            if (c != 0) return c
        }
        return 0
    }

    fun isNewer(candidate: String, current: String) = compare(candidate, current) > 0

    private fun parts(version: String): List<Long> =
        version.trim().removePrefix("v").split('.').map { part -> part.takeWhile(Char::isDigit).toLongOrNull() ?: 0 }
}

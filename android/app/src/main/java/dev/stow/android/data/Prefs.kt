package dev.stow.android.data

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Pairing (from the Mac's QR code) and settings, in app-private preferences. */
class Prefs(context: Context) {
    private val prefs: SharedPreferences = context.getSharedPreferences("stow", Context.MODE_PRIVATE)

    private val _wifiOnly = MutableStateFlow(prefs.getBoolean(KEY_WIFI_ONLY, true))
    /** Download only on Wi-Fi (default) or also on mobile data. */
    val wifiOnly: StateFlow<Boolean> = _wifiOnly.asStateFlow()

    fun setWifiOnly(on: Boolean) {
        prefs.edit().putBoolean(KEY_WIFI_ONLY, on).apply()
        _wifiOnly.value = on
    }

    private val _downloadSort = MutableStateFlow(
        runCatching { DownloadSort.valueOf(prefs.getString(KEY_SORT, null) ?: "") }.getOrDefault(DownloadSort.RECENTLY_DOWNLOADED))
    val downloadSort: StateFlow<DownloadSort> = _downloadSort.asStateFlow()
    fun setDownloadSort(sort: DownloadSort) {
        prefs.edit().putString(KEY_SORT, sort.name).apply()
        _downloadSort.value = sort
    }

    private val _groupByChannel = MutableStateFlow(prefs.getBoolean(KEY_GROUP, false))
    val groupByChannel: StateFlow<Boolean> = _groupByChannel.asStateFlow()
    fun setGroupByChannel(on: Boolean) {
        prefs.edit().putBoolean(KEY_GROUP, on).apply()
        _groupByChannel.value = on
    }

        private fun flag(key: String, default: Boolean) = MutableStateFlow(prefs.getBoolean(key, default))
    private fun set(flow: MutableStateFlow<Boolean>, key: String, on: Boolean) {
        prefs.edit().putBoolean(key, on).apply()
        flow.value = on
    }

    private val _downloadQuality = MutableStateFlow(
        runCatching { DownloadQuality.valueOf(prefs.getString(KEY_QUALITY, null) ?: "") }.getOrDefault(DownloadQuality.P1080))
    /** The highest resolution a download takes (it takes less when the video has nothing that high). */
    val downloadQuality: StateFlow<DownloadQuality> = _downloadQuality.asStateFlow()
    fun setDownloadQuality(quality: DownloadQuality) {
        prefs.edit().putString(KEY_QUALITY, quality.name).apply()
        _downloadQuality.value = quality
    }

    /** yt-dlp's format order for downloads. */
    val downloadFormatSort: String get() = downloadQuality.value.formatSort

    /** Play the next video when one ends (off: stop with a "done" screen). PlaybackService reads it too. */
    private val _autoplay = flag(KEY_AUTOPLAY, false)
    val autoplay: StateFlow<Boolean> = _autoplay.asStateFlow()
    fun setAutoplay(on: Boolean) = set(_autoplay, KEY_AUTOPLAY, on)

    /** Titles only: no thumbnails anywhere. */
    private val _calm = flag(KEY_CALM, false)
    val calm: StateFlow<Boolean> = _calm.asStateFlow()
    fun setCalm(on: Boolean) = set(_calm, KEY_CALM, on)

    /** The app in black and white (not the video itself). */
    private val _grayscale = flag(KEY_GRAYSCALE, false)
    val grayscale: StateFlow<Boolean> = _grayscale.asStateFlow()
    fun setGrayscale(on: Boolean) = set(_grayscale, KEY_GRAYSCALE, on)

    private val _theme = MutableStateFlow(
        runCatching { AppTheme.valueOf(prefs.getString(KEY_THEME, null) ?: "") }.getOrDefault(AppTheme.SYSTEM))
    /** How the app looks: following the phone, light, dark or warm paper. */
    val theme: StateFlow<AppTheme> = _theme.asStateFlow()
    fun setTheme(theme: AppTheme) {
        prefs.edit().putString(KEY_THEME, theme.name).apply()
        _theme.value = theme
    }

    private val _recentSearches = MutableStateFlow(
        prefs.getString(KEY_RECENT_SEARCHES, null)?.split("\n")?.filter { it.isNotBlank() }.orEmpty())
    /** What you searched YouTube for, latest first. */
    val recentSearches: StateFlow<List<String>> = _recentSearches.asStateFlow()
    fun addRecentSearch(query: String) {
        val q = query.trim().replace("\n", " ")
        if (q.isEmpty()) return
        saveRecentSearches((listOf(q) + _recentSearches.value.filterNot { it.equals(q, ignoreCase = true) }).take(20))
    }
    fun removeRecentSearch(query: String) = saveRecentSearches(_recentSearches.value - query)
    private fun saveRecentSearches(list: List<String>) {
        prefs.edit().putString(KEY_RECENT_SEARCHES, list.joinToString("\n")).apply()
        _recentSearches.value = list
    }

    /** Videos marked watched on the phone that were never sent to it (streamed). */
    private val _watchedHere = MutableStateFlow(prefs.getStringSet(KEY_WATCHED_HERE, emptySet()).orEmpty().toSet())
    val watchedHere: StateFlow<Set<String>> = _watchedHere.asStateFlow()
    @Synchronized
    fun setWatchedHere(id: String, watched: Boolean) {
        val updated = if (watched) _watchedHere.value + id else _watchedHere.value - id
        prefs.edit().putStringSet(KEY_WATCHED_HERE, updated).apply()
        _watchedHere.value = updated
    }

    /** Several at once (YouTube's history, the Mac's watched videos when switching to standalone). */
    @Synchronized
    fun addWatchedHere(ids: Collection<String>) {
        if (ids.all { it in _watchedHere.value }) return
        val updated = _watchedHere.value + ids
        prefs.edit().putStringSet(KEY_WATCHED_HERE, updated).apply()
        _watchedHere.value = updated
    }

    /** "mac" or "standalone" (see standalone/AppMode); null until chosen. */
    var appMode: String?
        get() = prefs.getString(KEY_APP_MODE, null)
        set(value) { prefs.edit().apply { if (value == null) remove(KEY_APP_MODE) else putString(KEY_APP_MODE, value) }.commit() }

    private val _signInPrompt = flag(KEY_SIGN_IN_PROMPT, false)
    /** Home's "Sign in to YouTube on this phone" card, after switching from the Mac. */
    val signInPrompt: StateFlow<Boolean> = _signInPrompt.asStateFlow()
    fun setSignInPrompt(on: Boolean) = set(_signInPrompt, KEY_SIGN_IN_PROMPT, on)

    private val _expiredBannerDismissed = flag(KEY_EXPIRED_DISMISSED, false)
    /** Home's "YouTube signed you out" banner was closed (until the next time it happens). */
    val expiredBannerDismissed: StateFlow<Boolean> = _expiredBannerDismissed.asStateFlow()
    fun setExpiredBannerDismissed(on: Boolean) = set(_expiredBannerDismissed, KEY_EXPIRED_DISMISSED, on)

        /** The Firebase project the Mac paired this phone with, once paired. */
    val pairedProject: String? get() = prefs.getString(KEY_PROJECT, null)

    /** Decrypts what only paired phones may read (the YouTube cookies). */
    val pairingKey: ByteArray?
        get() = prefs.getString(KEY_KEY, null)?.let { Base64.decode(it, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP) }

    fun savePairing(projectId: String, keyBase64Url: String) {
        prefs.edit().putString(KEY_PROJECT, projectId).putString(KEY_KEY, keyBase64Url).apply()
    }

    fun clearPairing() {
        prefs.edit().remove(KEY_PROJECT).remove(KEY_KEY).apply()
    }

    private val _alarm = MutableStateFlow(readAlarm())
    /** The Mac's latest "alarm playing" push (where to reach it), until its "ended" push. */
    val alarm: StateFlow<AlarmPush?> = _alarm.asStateFlow()

    fun saveAlarm(alarm: AlarmPush) {
        prefs.edit().putString(KEY_ALARM_HOSTS, alarm.hosts.joinToString(",")).putInt(KEY_ALARM_PORT, alarm.port)
            .putString(KEY_ALARM_MAC, alarm.macName).putLong(KEY_ALARM_AT, alarm.at).apply()
        _alarm.value = alarm
    }

    fun clearAlarm() {
        prefs.edit().remove(KEY_ALARM_HOSTS).remove(KEY_ALARM_PORT).remove(KEY_ALARM_MAC).remove(KEY_ALARM_AT).apply()
        _alarm.value = null
    }

    /**
     * When the Mac sent its latest "ended" push (FCM's clock). FCM doesn't keep pushes in order,
     * so a "playing" sent before it is a late one from a run that's already over.
     */
    var alarmEndedSentAt: Long
        get() = prefs.getLong(KEY_ALARM_ENDED, 0)
        set(value) { prefs.edit().putLong(KEY_ALARM_ENDED, value).apply() }

    private fun readAlarm(): AlarmPush? {
        val at = prefs.getLong(KEY_ALARM_AT, 0).takeIf { it > 0 } ?: return null
        return AlarmPush(prefs.getString(KEY_ALARM_HOSTS, null).orEmpty().split(",").filter { it.isNotBlank() },
                         prefs.getInt(KEY_ALARM_PORT, AlarmPush.DEFAULT_PORT), prefs.getString(KEY_ALARM_MAC, null) ?: "the Mac", at)
    }

    var lastYtDlpUpdate: Long
        get() = prefs.getLong(KEY_YTDLP_UPDATE, 0)
        set(value) { prefs.edit().putLong(KEY_YTDLP_UPDATE, value).apply() }

    /** When the app last asked GitHub for a newer release (see update/Updater). */
    var lastUpdateCheck: Long
        get() = prefs.getLong(KEY_UPDATE_CHECK, 0)
        set(value) { prefs.edit().putLong(KEY_UPDATE_CHECK, value).apply() }

    /** The newer release that check found (JSON, see update/Release), kept so the dot shows offline too. */
    var availableUpdate: String?
        get() = prefs.getString(KEY_UPDATE_AVAILABLE, null)
        set(value) { prefs.edit().putString(KEY_UPDATE_AVAILABLE, value).apply() }

    private val _dismissedUpdate = MutableStateFlow(prefs.getString(KEY_UPDATE_DISMISSED, null))
    /** The version whose banner on Home was closed (the dot on the settings button stays). */
    val dismissedUpdate: StateFlow<String?> = _dismissedUpdate.asStateFlow()
    fun dismissUpdate(version: String) {
        prefs.edit().putString(KEY_UPDATE_DISMISSED, version).apply()
        _dismissedUpdate.value = version
    }

    companion object {
        const val KEY_UPDATE_CHECK = "lastUpdateCheck"
        const val KEY_UPDATE_AVAILABLE = "availableUpdate"
        const val KEY_UPDATE_DISMISSED = "dismissedUpdate"
        const val KEY_WIFI_ONLY = "wifiOnly"
        const val KEY_PROJECT = "pairedProject"
        const val KEY_KEY = "pairingKey"
        const val KEY_YTDLP_UPDATE = "lastYtDlpUpdate"
        const val KEY_SORT = "downloadSort"
        const val KEY_AUTOPLAY = "autoplay"
        const val KEY_CALM = "calm"
        const val KEY_GRAYSCALE = "grayscale"
        const val KEY_WATCHED_HERE = "watchedHere"
        const val KEY_GROUP = "groupByChannel"
        const val KEY_THEME = "theme"
        const val KEY_QUALITY = "downloadQuality"
        const val KEY_RECENT_SEARCHES = "recentSearches"
        const val KEY_ALARM_HOSTS = "alarmHosts"
        const val KEY_ALARM_PORT = "alarmPort"
        const val KEY_ALARM_MAC = "alarmMac"
        const val KEY_ALARM_AT = "alarmAt"
        const val KEY_ALARM_ENDED = "alarmEndedSentAt"
        const val KEY_APP_MODE = "appMode"
        const val KEY_SIGN_IN_PROMPT = "signInPrompt"
        const val KEY_EXPIRED_DISMISSED = "expiredBannerDismissed"
    }
}

/** The app's look. Paper is a light theme in warm off-white with a terracotta accent. */
enum class AppTheme(val label: String) {
    SYSTEM("Automatic"), LIGHT("Light"), DARK("Dark"), PAPER("Paper");

    fun isDark(systemDark: Boolean) = when (this) {
        SYSTEM -> systemDark
        DARK -> true
        LIGHT, PAPER -> false
    }
}

/** The highest resolution downloads take. */
enum class DownloadQuality(val height: Int?, val label: String, val detail: String) {
    BEST(null, "Best available", "Up to 4K or more; the largest files"),
    P1440(1440, "1440p", "Sharper than 1080p on a big screen; about twice the size"),
    P1080(1080, "1080p", "Full HD"),
    P720(720, "720p", "About half the size of 1080p"),
    P480(480, "480p", "Smallest; fine for talks and podcasts");

    /**
     * yt-dlp's `-S`: the highest resolution up to the cap, then the highest frame rate, then H.264
     * and AAC, which every phone decodes in hardware. YouTube has no H.264 above 1080p, so higher
     * downloads are VP9 or AV1. (No frame-rate setting: YouTube offers 60 fps videos at 30 fps
     * only at 480p and below.)
     */
    val formatSort: String get() = "${height?.let { "res:$it" } ?: "res"},fps,vcodec:h264,acodec:m4a"
}

/** From the Mac's "alarm" push: its LAN addresses (likeliest first), the remote's port and its name. */
data class AlarmPush(val hosts: List<String>, val port: Int, val macName: String, val at: Long) {
    /** Recent enough that the alarm is probably still going (Home shows the remote banner). */
    fun isRecent(now: Long = System.currentTimeMillis()) = now - at < MAX_AGE_MS

    companion object {
        const val DEFAULT_PORT = 48261
        /** No alarm runs this long; past it a missed "ended" push no longer leaves the remote up. */
        const val MAX_AGE_MS = 2 * 60 * 60 * 1000L
    }
}

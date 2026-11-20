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

    var lastYtDlpUpdate: Long
        get() = prefs.getLong(KEY_YTDLP_UPDATE, 0)
        set(value) { prefs.edit().putLong(KEY_YTDLP_UPDATE, value).apply() }

    private companion object {
        const val KEY_WIFI_ONLY = "wifiOnly"
        const val KEY_PROJECT = "pairedProject"
        const val KEY_KEY = "pairingKey"
        const val KEY_YTDLP_UPDATE = "lastYtDlpUpdate"
        const val KEY_SORT = "downloadSort"
        const val KEY_GROUP = "groupByChannel"
    }
}

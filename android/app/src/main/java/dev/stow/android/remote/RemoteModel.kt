package dev.stow.android.remote

import android.content.Context
import dev.stow.android.data.Prefs
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject

/** What the remote screen shows. */
sealed interface RemoteUi {
    data object NotPaired : RemoteUi
    data object Searching : RemoteUi
    /** [reason] is the Mac's own answer when it refused (e.g. auth); null when nothing answered. */
    data class Unreachable(val reason: String?) : RemoteUi
    data class Live(val state: AlarmState) : RemoteUi
    data object Ended : RemoteUi
}

/**
 * The remote screen's state, polled from the Mac, with the phone's own pause/volume changes
 * shown right away (and kept over stale polls for a moment). The activity owns it so the
 * hardware volume keys can drive it too. Runs on the main thread.
 */
class RemoteModel(private val context: Context, private val client: RemoteClient, private val prefs: Prefs,
                  private val scope: CoroutineScope) {
    private val _ui = MutableStateFlow<RemoteUi>(RemoteUi.Searching)
    val ui: StateFlow<RemoteUi> = _ui.asStateFlow()

    private val _notice = MutableStateFlow<String?>(null)
    /** A short message after an action the Mac refused or didn't get. */
    val notice: StateFlow<String?> = _notice.asStateFlow()

    private val _choices = MutableStateFlow<List<AlarmVideo>?>(null)
    /** "Play something else": null while loading. */
    val choices: StateFlow<List<AlarmVideo>?> = _choices.asStateFlow()

    /** A value the phone just set, shown over polls until the Mac has caught up. */
    private class Pending<T>(val value: T, val until: Long = System.currentTimeMillis() + 2_000) {
        val current: T? get() = value.takeIf { System.currentTimeMillis() < until }
    }
    private var paused: Pending<Boolean>? = null
    private var volume: Pending<Int>? = null
    private var muted: Pending<Boolean>? = null
    private var latest: AlarmState? = null
    /** An alarm push was in while this run was live, so its absence now means "ended". */
    private var sawPush = false
    private var failures = 0
    private var volumeJob: Job? = null
    private var wantedVolume: Int? = null
    private var noticeJob: Job? = null

    val volumeControllable: Boolean get() = (_ui.value as? RemoteUi.Live)?.state?.volume != null

    /** Polls about once a second (more slowly while the Mac can't be reached) until cancelled. */
    suspend fun poll() {
        if (_ui.value is RemoteUi.Ended || _ui.value is RemoteUi.NotPaired) {
            _ui.value = RemoteUi.Searching
            latest = null
            sawPush = false
        }
        while (_ui.value !is RemoteUi.Ended && _ui.value !is RemoteUi.NotPaired) {
            refresh()
            delay(if (_ui.value is RemoteUi.Live) 1_000 else 3_000)
        }
    }

    fun retry() {
        _ui.value = RemoteUi.Searching
        scope.launch { refresh() }
    }

    private suspend fun refresh() {
        try {
            show(client.state())
            failures = 0
        } catch (_: RemoteException.NotPaired) {
            _ui.value = RemoteUi.NotPaired
        } catch (e: RemoteException) {
            failures++
            when {
                // The Mac's "ended" push came in and its server is gone: the alarm is over.
                sawPush && prefs.alarm.value == null -> end()
                // One missed poll while live isn't worth flashing an error.
                _ui.value !is RemoteUi.Live || failures >= 3 -> _ui.value = RemoteUi.Unreachable((e as? RemoteException.Rejected)?.message)
            }
        }
    }

    private fun show(state: AlarmState) {
        if (_ui.value is RemoteUi.Ended) return
        if (state.finished) return end()
        latest = state
        if (prefs.alarm.value != null) sawPush = true
        _ui.value = RemoteUi.Live(state.copy(
            isPaused = paused?.current ?: state.isPaused,
            volume = volume?.current ?: state.volume,
            isMuted = muted?.current ?: state.isMuted,
        ))
    }

    private fun end() {
        _ui.value = RemoteUi.Ended
        prefs.clearAlarm()
        AlarmNotification.cancel(context)
    }

    private fun live(): AlarmState? = (_ui.value as? RemoteUi.Live)?.state

    private fun send(name: String, vararg fields: Pair<String, Any>) {
        val action = JSONObject().put("action", name).apply { fields.forEach { (key, value) -> put(key, value) } }
        scope.launch { perform(action) }
    }

    private suspend fun perform(action: JSONObject) {
        try {
            show(client.act(action))
        } catch (e: RemoteException) {
            note(e.message.orEmpty())
        }
    }

    private fun note(message: String) {
        _notice.value = message
        noticeJob?.cancel()
        noticeJob = scope.launch { delay(3_000); _notice.value = null }
    }

    fun togglePaused() {
        val state = live() ?: return
        val value = !state.isPaused
        paused = Pending(value)
        show(latest ?: state)
        send("setPaused", "paused" to value)
    }

    fun seekBy(seconds: Int) {
        val state = live() ?: return
        _ui.value = RemoteUi.Live(state.copy(position = (state.position + seconds).coerceIn(0.0, state.duration ?: Double.MAX_VALUE)))
        send("seekBy", "seconds" to seconds)
    }

    fun seekTo(seconds: Double) {
        val state = live() ?: return
        _ui.value = RemoteUi.Live(state.copy(position = seconds))
        send("seekTo", "seconds" to seconds)
    }

    fun next() = send("next")

    fun playIndex(index: Int) = send("playIndex", "index" to index)

    fun playVideo(id: String) = send("playVideo", "videoId" to id)

    fun toggleMuted() {
        val state = live() ?: return
        val value = !state.isMuted
        muted = Pending(value)
        show(latest ?: state)
        send("setMuted", "muted" to value)
    }

    /** "I'm awake": one tap ends the alarm. */
    fun stop() {
        scope.launch {
            try {
                client.act(JSONObject().put("action", "stop"))
                end()
            } catch (e: RemoteException) {
                note(e.message.orEmpty())
            }
        }
    }

    /**
     * Shown at once; sent while dragging at most one request at a time, and always ending with
     * the last value, so a slider drag neither floods the Mac nor loses where it stopped.
     */
    fun setVolume(value: Int) {
        val clamped = value.coerceIn(0, 100)
        volume = Pending(clamped)
        live()?.let { show(latest ?: it) }
        wantedVolume = clamped
        if (volumeJob?.isActive == true) return
        volumeJob = scope.launch {
            while (true) {
                val next = wantedVolume ?: break
                wantedVolume = null
                perform(JSONObject().put("action", "setVolume").put("volume", next))
                delay(150)
            }
        }
    }

    /** The phone's volume keys while the remote shows; false when there's no volume to change. */
    fun nudgeVolume(up: Boolean): Boolean {
        val current = live()?.volume ?: return false
        setVolume(current + if (up) VOLUME_STEP else -VOLUME_STEP)
        return true
    }

    fun loadChoices() {
        _choices.value = null
        scope.launch {
            _choices.value = try {
                client.choices()
            } catch (e: RemoteException) {
                note(e.message.orEmpty())
                emptyList()
            }
        }
    }

    companion object {
        const val VOLUME_STEP = 5
    }
}

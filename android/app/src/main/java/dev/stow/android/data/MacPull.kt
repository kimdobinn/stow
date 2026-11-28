package dev.stow.android.data

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull

/** Pull to refresh with the Mac: waiting for its answer, which a mode change or an unpairing ends. */
object MacPull {
    enum class Answer { ANSWERED, NO_ANSWER, STOPPED }

    /** The Mac answers with the request's time (to the millisecond). */
    fun answers(shared: Remote.Shared, requestedAt: Long): Boolean = (shared.refreshHandledAt?.time ?: 0) >= requestedAt - 1_000

    /**
     * Waits (up to `timeoutMs`) for `shared` to carry the Mac's answer. `shared` must also emit
     * when the mode or the pairing changes, so `stillPaired` going false ends the wait at once.
     */
    suspend fun await(shared: Flow<Remote.Shared>, requestedAt: Long, timeoutMs: Long, stillPaired: () -> Boolean): Answer {
        val last = withTimeoutOrNull(timeoutMs) { shared.first { !stillPaired() || answers(it, requestedAt) } }
        return when {
            !stillPaired() -> Answer.STOPPED
            last == null -> Answer.NO_ANSWER
            else -> Answer.ANSWERED
        }
    }
}

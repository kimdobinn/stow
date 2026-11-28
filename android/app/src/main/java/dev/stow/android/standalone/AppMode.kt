package dev.stow.android.standalone

/**
 * How the app works: paired with the Mac (it follows the channels and sends videos), on its own
 * (this phone follows channels and checks them itself, with no Firebase at all), or not chosen yet.
 */
enum class AppMode {
    CHOOSING, MAC, STANDALONE;

    /** What the `appMode` preference holds ("mac" / "standalone"); null while choosing. */
    val stored: String?
        get() = when (this) {
            MAC -> "mac"
            STANDALONE -> "standalone"
            CHOOSING -> null
        }

    companion object {
        /**
         * The mode at launch, from the stored preference and whether the preferences hold a
         * pairing (never Firebase). Installs paired before modes existed resolve to [MAC]; the
         * caller then stores "mac" (see [needsStoring]).
         */
        fun resolve(stored: String?, hasPairing: Boolean): AppMode = when (stored) {
            "mac" -> MAC
            "standalone" -> STANDALONE
            else -> if (hasPairing) MAC else CHOOSING
        }

        /** True when [resolve] picked a mode the preference doesn't say yet (it's written then). */
        fun needsStoring(stored: String?, resolved: AppMode): Boolean = resolved.stored != null && resolved.stored != stored
    }
}

/**
 * Bumped on every mode change: work started in one mode (a pull from the Mac, a sync, a Firestore
 * listener) checks its era before each step and stops at the next mode, so nothing started with
 * the Mac touches Firebase after switching to standalone.
 */
class ModeEra {
    @Volatile var value = 0
        private set

    /** The mode goes from `from` to `to`: a new era unless it stays the same. */
    @Synchronized
    fun change(from: AppMode, to: AppMode) {
        if (from != to) value++
    }

    fun isCurrent(era: Int) = era == value
}

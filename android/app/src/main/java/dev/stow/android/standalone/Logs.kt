package dev.stow.android.standalone

/** The system log (tag "Stow"); standard output in JVM unit tests, where android.util.Log is a stub. */
object Logs {
    fun i(message: String) { runCatching { android.util.Log.i("Stow", message) }.onFailure { println("I/Stow: $message") } }
    fun w(message: String, error: Throwable? = null) {
        runCatching { android.util.Log.w("Stow", message, error) }.onFailure { println("W/Stow: $message ${error ?: ""}") }
    }
    fun e(message: String) { runCatching { android.util.Log.e("Stow", message) }.onFailure { println("E/Stow: $message") } }
}

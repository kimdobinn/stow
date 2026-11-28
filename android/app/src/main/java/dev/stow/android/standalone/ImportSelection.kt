package dev.stow.android.standalone

/**
 * What's ticked in "Import from YouTube". Nothing is ticked at first, and only "Select all"
 * (a tap) ticks everything: the app never imports all your subscriptions by itself. Channels
 * already followed show as added and can't be ticked.
 */
data class ImportSelection(val picked: Set<String> = emptySet()) {
    fun isAdded(id: String, followed: Set<String>) = id in followed
    fun isPicked(id: String) = id in picked

    fun toggle(id: String, followed: Set<String>): ImportSelection =
        if (id in followed) this else copy(picked = if (id in picked) picked - id else picked + id)

    fun selectAll(available: List<ChannelInfo>, followed: Set<String>) =
        copy(picked = available.map { it.id }.filter { it !in followed }.toSet())

    fun selectNone() = ImportSelection()

    val count: Int get() = picked.size

    /** The picked channels, in YouTube's order. */
    fun chosen(available: List<ChannelInfo>): List<ChannelInfo> = available.filter { it.id in picked }
}

package dev.stow.android.standalone

/** What started a check. `key` is what standalone.json and the log say. */
enum class Trigger(val key: String) {
    LAUNCH("launch"), FOREGROUND("foreground"), TICK("tick"), BACKGROUND("background"),
    PULL("pull"), CHANNEL_ADDED("channelAdded"), SIGN_IN("signIn");

    /** These run whenever asked; the rest only once a check is due. */
    val alwaysRuns: Boolean get() = this == PULL || this == CHANNEL_ADDED || this == SIGN_IN

    companion object {
        fun of(key: String?): Trigger? = entries.firstOrNull { it.key == key }
    }
}

/** A channel's feeds. */
enum class FeedKind { UPLOADS, STREAMS, MEMBERS }

/** The YouTube account as far as the checks care. */
enum class AccountState(val key: String) {
    SIGNED_OUT("signedOut"), SIGNED_IN("signedIn"), EXPIRED("expired");

    companion object {
        fun of(key: String?): AccountState = entries.firstOrNull { it.key == key } ?: SIGNED_OUT
    }
}

/** When each of a channel's feeds was last read (epoch ms, 0 = never). */
data class FetchedAt(val uploads: Long = 0, val streams: Long = 0, val members: Long = 0) {
    operator fun get(kind: FeedKind) = when (kind) {
        FeedKind.UPLOADS -> uploads
        FeedKind.STREAMS -> streams
        FeedKind.MEMBERS -> members
    }

    fun with(kind: FeedKind, at: Long) = when (kind) {
        FeedKind.UPLOADS -> copy(uploads = at)
        FeedKind.STREAMS -> copy(streams = at)
        FeedKind.MEMBERS -> copy(members = at)
    }
}

/**
 * What one check reads (the spec's due-plan, a pure function both phones test): every channel's
 * uploads; streams and members feeds when they're due; YouTube's Home and Subscriptions, the watch
 * history and member access lookups when signed in.
 */
object CheckPlan {
    const val MINUTE = 60_000L
    const val HOUR = 60 * MINUTE
    const val CHECK_INTERVAL = 15 * MINUTE
    const val STREAMS_EVERY = 6 * HOUR
    const val STREAMS_ON_PULL = HOUR
    const val MEMBERS_EVERY = 60 * MINUTE
    const val MEMBERS_ON_PULL = 15 * MINUTE
    const val FEEDS_EVERY = 20 * MINUTE
    const val FEEDS_IN_BACKGROUND = 2 * HOUR
    const val HISTORY_EVERY = 15 * MINUTE
    const val PROBE_EVERY = HOUR
    /** A channel the account isn't a member of, or without a members playlist, goes this long without its members feed. */
    const val MEMBERS_SKIP = 7 * 24 * HOUR

    data class Input(
        val trigger: Trigger,
        val now: Long,
        val channelIds: List<String>,
        val fetchedAt: Map<String, FetchedAt> = emptyMap(),
        val account: AccountState = AccountState.SIGNED_OUT,
        /** nonMemberChannels and noMembersPlaylist: when each was found. */
        val nonMember: Map<String, Long> = emptyMap(),
        val noMembersPlaylist: Map<String, Long> = emptyMap(),
        val feedsLoadedAt: Long = 0,
        val syncWatched: Boolean = true,
        val lastWatchSync: Long = 0,
        val pendingMarks: Int = 0,
        val lastProbeAt: Long = 0,
    )

    data class Plan(
        val channels: Map<String, Set<FeedKind>>,
        /** YouTube's Home and Subscriptions. */
        val feeds: Boolean,
        val history: Boolean,
        val accessChecks: Boolean,
        /** Signed out by YouTube: try the cookies once (hourly) to see if they work again. */
        val probe: Boolean,
    )

    fun skipsMembers(channelId: String, input: Input): Boolean {
        fun recent(at: Long?) = at != null && input.now - at < MEMBERS_SKIP
        return recent(input.nonMember[channelId]) || recent(input.noMembersPlaylist[channelId])
    }

    fun plan(input: Input): Plan {
        val trigger = input.trigger
        val now = input.now
        val signedIn = input.account == AccountState.SIGNED_IN
        fun since(at: Long) = if (at <= 0) Long.MAX_VALUE else now - at
        val channels = input.channelIds.associateWith { id ->
            val at = input.fetchedAt[id] ?: FetchedAt()
            buildSet {
                add(FeedKind.UPLOADS)
                val streams = when (trigger) {
                    Trigger.CHANNEL_ADDED -> true
                    Trigger.PULL -> since(at.streams) >= STREAMS_ON_PULL
                    else -> since(at.streams) >= STREAMS_EVERY
                }
                if (streams) add(FeedKind.STREAMS)
                val members = signedIn && !skipsMembers(id, input) && when (trigger) {
                    Trigger.CHANNEL_ADDED, Trigger.SIGN_IN -> true
                    Trigger.PULL -> since(at.members) >= MEMBERS_ON_PULL
                    else -> since(at.members) >= MEMBERS_EVERY
                }
                if (members) add(FeedKind.MEMBERS)
            }
        }
        val feeds = signedIn && when (trigger) {
            Trigger.PULL, Trigger.SIGN_IN -> true
            Trigger.CHANNEL_ADDED -> false
            Trigger.BACKGROUND -> since(input.feedsLoadedAt) >= FEEDS_IN_BACKGROUND
            Trigger.LAUNCH, Trigger.FOREGROUND, Trigger.TICK -> since(input.feedsLoadedAt) >= FEEDS_EVERY
        }
        val history = signedIn && input.syncWatched && when (trigger) {
            Trigger.CHANNEL_ADDED -> false
            Trigger.PULL, Trigger.SIGN_IN -> true
            else -> since(input.lastWatchSync) >= HISTORY_EVERY || input.pendingMarks > 0
        }
        val members = channels.values.any { FeedKind.MEMBERS in it }
        val probe = input.account == AccountState.EXPIRED && trigger != Trigger.CHANNEL_ADDED && since(input.lastProbeAt) >= PROBE_EVERY
        return Plan(channels, feeds, history, signedIn && (members || feeds), probe)
    }

    /**
     * The background job runs about every 15 minutes, and the check it starts takes a while; measured
     * from the end of that check, the next run would come a little early and be skipped (every 30
     * minutes in practice). So a check is due 15 minutes after the last one started, less a minute.
     */
    const val DUE_SLACK = MINUTE

    /**
     * Whether an automatic check (not pull, seed or sign-in) is due: about 15 minutes since the last
     * one started, and no backoff. A check that couldn't reach YouTube (offline) doesn't count.
     */
    fun isDue(trigger: Trigger, now: Long, last: CheckRecord?, backoffUntil: Long): Boolean {
        if (trigger.alwaysRuns) return true
        if (now < backoffUntil) return false
        if (last == null || last.offline) return true
        return now - last.startedAt >= CHECK_INTERVAL - DUE_SLACK
    }

    /** The next backoff after YouTube asked to slow down: 30 minutes, doubling, up to 4 hours. */
    fun nextBackoffMinutes(current: Int): Int = if (current <= 0) 30 else (current * 2).coerceAtMost(240)
}

package dev.stow.android.standalone

import dev.stow.android.standalone.CheckPlan.HOUR
import dev.stow.android.standalone.CheckPlan.MINUTE
import dev.stow.android.standalone.FeedKind.MEMBERS
import dev.stow.android.standalone.FeedKind.STREAMS
import dev.stow.android.standalone.FeedKind.UPLOADS
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CheckPlanTest {
    private val now = 1_800_000_000_000L
    private val id = CHANNEL_A

    private fun plan(trigger: Trigger, fetched: FetchedAt = FetchedAt(), account: AccountState = AccountState.SIGNED_OUT,
                     feedsLoadedAt: Long = 0, lastWatchSync: Long = 0, pending: Int = 0, sync: Boolean = true,
                     nonMember: Long? = null, noPlaylist: Long? = null, lastProbeAt: Long = 0) =
        CheckPlan.plan(CheckPlan.Input(trigger, now, listOf(id), mapOf(id to fetched), account,
                                       nonMember?.let { mapOf(id to it) }.orEmpty(), noPlaylist?.let { mapOf(id to it) }.orEmpty(),
                                       feedsLoadedAt, sync, lastWatchSync, pending, lastProbeAt))

    private fun ago(ms: Long) = now - ms
    private val automatic = listOf(Trigger.LAUNCH, Trigger.FOREGROUND, Trigger.TICK, Trigger.BACKGROUND)

    @Test fun uploadsAlways() {
        for (trigger in Trigger.entries) assertTrue(UPLOADS in plan(trigger).channels.getValue(id))
    }

    @Test fun streamsEverySixHoursHourlyOnPullAndOnAdd() {
        for (trigger in automatic) {
            assertTrue("never read: $trigger", STREAMS in plan(trigger).channels.getValue(id))
            assertFalse(STREAMS in plan(trigger, FetchedAt(streams = ago(5 * HOUR))).channels.getValue(id))
            assertTrue(STREAMS in plan(trigger, FetchedAt(streams = ago(6 * HOUR))).channels.getValue(id))
        }
        assertFalse(STREAMS in plan(Trigger.PULL, FetchedAt(streams = ago(59 * MINUTE))).channels.getValue(id))
        assertTrue(STREAMS in plan(Trigger.PULL, FetchedAt(streams = ago(HOUR))).channels.getValue(id))
        assertTrue(STREAMS in plan(Trigger.CHANNEL_ADDED, FetchedAt(streams = ago(MINUTE))).channels.getValue(id))
    }

    @Test fun membersOnlySignedInAndNotSkipped() {
        val signedIn = AccountState.SIGNED_IN
        for (trigger in automatic) {
            assertFalse(MEMBERS in plan(trigger).channels.getValue(id))
            assertFalse("expired", MEMBERS in plan(trigger, account = AccountState.EXPIRED).channels.getValue(id))
            assertTrue(MEMBERS in plan(trigger, account = signedIn).channels.getValue(id))
            assertFalse(MEMBERS in plan(trigger, FetchedAt(members = ago(59 * MINUTE)), signedIn).channels.getValue(id))
            assertTrue(MEMBERS in plan(trigger, FetchedAt(members = ago(60 * MINUTE)), signedIn).channels.getValue(id))
        }
        assertFalse(MEMBERS in plan(Trigger.PULL, FetchedAt(members = ago(14 * MINUTE)), signedIn).channels.getValue(id))
        assertTrue(MEMBERS in plan(Trigger.PULL, FetchedAt(members = ago(15 * MINUTE)), signedIn).channels.getValue(id))
        for (trigger in listOf(Trigger.CHANNEL_ADDED, Trigger.SIGN_IN)) {
            assertTrue(MEMBERS in plan(trigger, FetchedAt(members = ago(MINUTE)), signedIn).channels.getValue(id))
        }
        // Not a member, or no members playlist: skipped for a week, whatever the trigger.
        for (trigger in Trigger.entries) {
            assertFalse(MEMBERS in plan(trigger, account = signedIn, nonMember = ago(6 * 24 * HOUR)).channels.getValue(id))
            assertFalse(MEMBERS in plan(trigger, account = signedIn, noPlaylist = ago(HOUR)).channels.getValue(id))
        }
        assertTrue(MEMBERS in plan(Trigger.LAUNCH, account = signedIn, nonMember = ago(7 * 24 * HOUR)).channels.getValue(id))
    }

    @Test fun youtubesFeeds() {
        val signedIn = AccountState.SIGNED_IN
        for (trigger in Trigger.entries) assertFalse("signed out: $trigger", plan(trigger, feedsLoadedAt = 0).feeds)
        for (trigger in listOf(Trigger.LAUNCH, Trigger.FOREGROUND, Trigger.TICK)) {
            assertFalse(plan(trigger, account = signedIn, feedsLoadedAt = ago(19 * MINUTE)).feeds)
            assertTrue(plan(trigger, account = signedIn, feedsLoadedAt = ago(20 * MINUTE)).feeds)
        }
        assertFalse(plan(Trigger.BACKGROUND, account = signedIn, feedsLoadedAt = ago(119 * MINUTE)).feeds)
        assertTrue(plan(Trigger.BACKGROUND, account = signedIn, feedsLoadedAt = ago(2 * HOUR)).feeds)
        assertTrue(plan(Trigger.PULL, account = signedIn, feedsLoadedAt = ago(MINUTE)).feeds)
        assertTrue(plan(Trigger.SIGN_IN, account = signedIn, feedsLoadedAt = ago(MINUTE)).feeds)
        assertFalse(plan(Trigger.CHANNEL_ADDED, account = signedIn).feeds)
        assertFalse(plan(Trigger.PULL, account = AccountState.EXPIRED).feeds)
    }

    @Test fun historySync() {
        val signedIn = AccountState.SIGNED_IN
        assertFalse(plan(Trigger.LAUNCH, lastWatchSync = 0).history)
        assertTrue(plan(Trigger.LAUNCH, account = signedIn).history)
        assertFalse(plan(Trigger.LAUNCH, account = signedIn, lastWatchSync = ago(14 * MINUTE)).history)
        assertTrue("marks waiting", plan(Trigger.LAUNCH, account = signedIn, lastWatchSync = ago(MINUTE), pending = 1).history)
        assertTrue(plan(Trigger.BACKGROUND, account = signedIn, lastWatchSync = ago(15 * MINUTE)).history)
        assertTrue(plan(Trigger.PULL, account = signedIn, lastWatchSync = ago(MINUTE)).history)
        assertFalse("sync off", plan(Trigger.PULL, account = signedIn, sync = false).history)
        assertFalse(plan(Trigger.CHANNEL_ADDED, account = signedIn).history)
        assertFalse(plan(Trigger.PULL, account = AccountState.EXPIRED).history)
    }

    @Test fun accessChecksFollowMembersOrFeeds() {
        assertTrue(plan(Trigger.LAUNCH, account = AccountState.SIGNED_IN).accessChecks)
        assertFalse(plan(Trigger.LAUNCH, FetchedAt(members = ago(MINUTE)), AccountState.SIGNED_IN, feedsLoadedAt = ago(MINUTE)).accessChecks)
        assertTrue(plan(Trigger.PULL, FetchedAt(members = ago(MINUTE)), AccountState.SIGNED_IN, feedsLoadedAt = ago(MINUTE)).accessChecks)
        assertFalse(plan(Trigger.PULL).accessChecks)
    }

    @Test fun anExpiredSignInIsProbedHourly() {
        assertTrue(plan(Trigger.LAUNCH, account = AccountState.EXPIRED, lastProbeAt = ago(HOUR)).probe)
        assertFalse(plan(Trigger.PULL, account = AccountState.EXPIRED, lastProbeAt = ago(59 * MINUTE)).probe)
        assertFalse(plan(Trigger.LAUNCH, account = AccountState.SIGNED_IN).probe)
        assertFalse(plan(Trigger.CHANNEL_ADDED, account = AccountState.EXPIRED).probe)
    }

    private fun record(startedAgo: Long, took: Long = MINUTE, offline: Boolean = false) =
        CheckRecord("background", ago(startedAgo), ago(startedAgo) + took, 1, emptyList(), offline)

    @Test fun dueEveryFifteenMinutesUnlessBackingOff() {
        for (trigger in automatic) {
            assertTrue(CheckPlan.isDue(trigger, now, null, 0))
            assertFalse(CheckPlan.isDue(trigger, now, record(13 * MINUTE), 0))
            assertTrue(CheckPlan.isDue(trigger, now, record(15 * MINUTE), 0))
            assertFalse(CheckPlan.isDue(trigger, now, record(HOUR), now + MINUTE))
        }
        for (trigger in listOf(Trigger.PULL, Trigger.CHANNEL_ADDED, Trigger.SIGN_IN)) {
            assertTrue(CheckPlan.isDue(trigger, now, record(MINUTE), now + HOUR))
        }
    }

    @Test fun theNextBackgroundRunIsntSkippedBecauseTheLastCheckTookAWhile() {
        // Started 15 minutes ago (the last run of the 15-minute job), finished 2 minutes later:
        // the next run is due, not 30 minutes after.
        assertTrue(CheckPlan.isDue(Trigger.BACKGROUND, now, record(15 * MINUTE, took = 2 * MINUTE), 0))
        // The job may come a little early.
        assertTrue(CheckPlan.isDue(Trigger.BACKGROUND, now, record(14 * MINUTE + 30_000), 0))
    }

    @Test fun aCheckThatCouldntReachYouTubeDoesntMakeTheNextOneWait() {
        assertTrue(CheckPlan.isDue(Trigger.LAUNCH, now, record(MINUTE, offline = true), 0))
        assertFalse("backoff still counts", CheckPlan.isDue(Trigger.LAUNCH, now, record(MINUTE, offline = true), now + MINUTE))
    }

    @Test fun backoffDoublesUpToFourHours() {
        assertEquals(listOf(30, 60, 120, 240, 240), generateSequence(CheckPlan.nextBackoffMinutes(0)) { CheckPlan.nextBackoffMinutes(it) }.take(5).toList())
    }
}

package dev.stow.android.standalone

import dev.stow.android.account.InMemorySecretStore
import dev.stow.android.data.GroupChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * The standalone engine end to end, with youtube.com and yt-dlp faked: follow → seed, pulls, the
 * sign-in expiring, signing out, and leaving for the Mac and coming back. FakeWeb fails the test
 * on any Firebase host; nothing here has a Firebase class on its path.
 */
class StandaloneEngineTest {
    private lateinit var dir: File
    private lateinit var scope: CoroutineScope
    private val web = FakeWeb()
    private val vault = InMemorySecretStore()
    private val host = FakeHost()
    private var now = 1_800_000_000_000L
    private var feedsRejected = false
    private var history = """{"entries":[]}"""
    private var streamsTab = """{"entries":[{"id":"stream00001","title":"A stream","live_status":"was_live","timestamp":1700000000}]}"""
    private var videosTabFailure: String? = null
    private var videosTab = """{"channel_id":"$CHANNEL_A","channel":"Test","entries":[{"id":"tabvideo001","title":"From the tab","timestamp":1799000000,"duration":700},{"id":"tabshort001","url":"https://www.youtube.com/shorts/tabshort001","title":"Short"}]}"""

    private val uploads = RssFeed.playlistUrl(RssFeed.Playlists.uploads(CHANNEL_A))
    private val homeFeed = """{"entries":[
        {"id":"feedvideo01","title":"A video","channel_id":"$CHANNEL_B","channel":"Bee","duration":600,"timestamp":1799990000},
        {"id":"shortvideo1","url":"https://www.youtube.com/shorts/shortvideo1","title":"A Short","channel_id":"$CHANNEL_B"},
        {"id":"shortlength","title":"Short by length","channel_id":"$CHANNEL_B","duration":45},
        {"id":"livevideo01","title":"Live now","channel_id":"$CHANNEL_B","live_status":"is_live"},
        {"id":"upcomingvid","title":"Soon","channel_id":"$CHANNEL_B","live_status":"is_upcoming"},
        {"id":"membersvid1","title":"Members","channel_id":"$CHANNEL_B","availability":"subscriber_only","duration":900},
        {"id":"feedvideo01","title":"Repeat","channel_id":"$CHANNEL_B","duration":600}
    ]}""".replace("\n", "")  // yt-dlp -J prints one line

    private val tool = FakeTool { args, _ ->
        val target = args.last()
        when {
            target == ":ytrec" || target == ":ytsubs" -> if (args.contains("1")) ToolOutput("""{"entries":[]}""", feedsRejected)
                                                         else ToolOutput(homeFeed, feedsRejected)
            target == ":ythistory" -> ToolOutput(history)
            target.endsWith("/streams") -> ToolOutput(streamsTab)
            target.endsWith("/videos") -> videosTabFailure?.let { throw ToolFailure(it) } ?: ToolOutput(videosTab)
            "--mark-watched" in args -> ToolOutput("")
            "--skip-download" in args -> ToolOutput("""{"availability":"subscriber_only"}""")
            "UUMF" in target -> ToolOutput("""{"entries":[{"id":"memberonly1","title":"For members","live_status":"not_live"}]}""")
            "UUMV" in target -> throw ToolFailure("ERROR: The playlist does not exist.")
            else -> ToolOutput("{}")
        }
    }

    private lateinit var engine: Standalone

    @Before fun setUp() {
        dir = Files.createTempDirectory("stow-engine").toFile()
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        web.set(uploads, fixture("rss-uploads.xml"))
        web.set("https://www.youtube.com/channel/$CHANNEL_A", fixture("channel-page.html"))
        engine = newEngine()
    }

    @After fun tearDown() {
        scope.cancel()
        dir.deleteRecursively()
    }

    private fun published(id: String) = engine.state.value.recentVideos.getValue(CHANNEL_A).first { it.video.id == id }.video.publishedAt!!.time

    private fun newEngine() = Standalone(StandaloneStore(File(dir, "standalone.json")), vault, web, tool, host, scope, { now }, Dispatchers.Default)
        .also { it.load() }

    private fun <T> wait(block: suspend () -> T): T = runBlocking { withTimeout(10_000) { block() } }

    /** Until `condition` holds and no check is running. */
    private fun waitUntil(condition: () -> Boolean) = wait {
        while (!(condition() && !engine.checkStatus.value.isChecking)) kotlinx.coroutines.delay(10)
    }

    private fun followAndSeed() {
        assertTrue(engine.follow(ChannelInfo(CHANNEL_A, "Test")))
        waitUntil { engine.state.value.recentVideos[CHANNEL_A] != null }
    }

    @Test fun followingSeedsTheChannel() {
        followAndSeed()
        val channel = engine.channels.value.single()
        assertEquals(CHANNEL_A, channel.id)
        // Uploads from RSS plus the finished stream, newest first.
        assertEquals(listOf("vid00000001", "vid00000002", "stream00001"), channel.recent.map { it.video.id })
        assertTrue(channel.recent.all { it.video.channelTitle == "Test" })
        assertTrue(channel.recent.last().video.isPastStream)
        val fetched = engine.state.value.fetchedAt.getValue(CHANNEL_A)
        assertEquals(now, fetched.uploads)
        assertEquals(now, fetched.streams)
        assertEquals("signed out: no members feed", 0L, fetched.members)
        assertFalse(engine.follow(ChannelInfo(CHANNEL_A, "Test")))
        // Its picture and handle come from its page.
        wait { engine.state.first { it.channels.single().avatarUrl != null } }
        assertEquals("@TestéChannel", engine.state.value.channels.single().handle)
    }

    @Test fun addingByInputSaysWhenItsAlreadyThere() {
        web.set("https://www.youtube.com/@Test", fixture("channel-page.html"))
        val added = wait { engine.addChannel("@Test") }
        assertEquals(CHANNEL_A, added.id)
        assertEquals("Test & Channel", added.title)
        val error = runCatching { wait { engine.addChannel("https://www.youtube.com/channel/$CHANNEL_A") } }.exceptionOrNull()
        assertEquals("Test & Channel is already added.", error?.message)
    }

    @Test fun aPullAndAPullRightAfterIt() {
        followAndSeed()
        assertEquals(Standalone.Outcome.DONE, wait { engine.refresh() })
        val requests = web.requests.size
        now += 30_000
        assertEquals(Standalone.Outcome.DONE, wait { engine.refresh() })
        assertEquals("the second pull reuses the first", requests, web.requests.size)
        // Not due again for 15 minutes.
        assertEquals(Standalone.Outcome.NOT_DUE, wait { engine.checkIfDue(Trigger.FOREGROUND) })
        now += CheckPlan.CHECK_INTERVAL
        assertEquals(Standalone.Outcome.DONE, wait { engine.checkIfDue(Trigger.FOREGROUND) })
    }

    @Test fun youtubeSlowingDownBacksOff() {
        followAndSeed()
        web.set(uploads, "", 429)
        assertEquals(Standalone.Outcome.SLOWED_DOWN, wait { engine.refresh() })
        val s = engine.state.value
        assertEquals(30, s.backoffMinutes)
        assertEquals(now + 30 * CheckPlan.MINUTE, s.backoffUntil)
        now += CheckPlan.CHECK_INTERVAL
        assertEquals("automatic checks wait", Standalone.Outcome.NOT_DUE, wait { engine.checkIfDue(Trigger.BACKGROUND) })
        web.set(uploads, fixture("rss-uploads.xml"))
        now += CheckPlan.MINUTE * 2
        assertEquals("a pull doesn't", Standalone.Outcome.DONE, wait { engine.refresh() })
        assertEquals(0L, engine.state.value.backoffUntil)
        assertEquals(0, engine.state.value.backoffMinutes)
    }

    @Test fun aBrokenPlaylistFeedFallsBackToTheVideosTab() {
        web.set(uploads, "", 503)
        followAndSeed()
        assertEquals(listOf("tabvideo001", "stream00001"), engine.channels.value.single().recent.map { it.video.id })
        assertEquals("not a slow-down", 0L, engine.state.value.backoffUntil)
    }

    @Test fun offlineIsANetworkFailure() {
        followAndSeed()
        web.failAll = true
        assertEquals(Standalone.Outcome.NETWORK, wait { engine.refresh() })
        assertEquals(1, engine.state.value.failedCheckStreak)
        assertTrue(engine.channels.value.single().recent.isNotEmpty())
        assertTrue(engine.state.value.lastCheck!!.offline)
    }

    @Test fun anOfflineCheckDoesntMakeTheNextOneWait() {
        followAndSeed()
        web.failAll = true
        assertEquals(Standalone.Outcome.NETWORK, wait { engine.checkIfDue(Trigger.LAUNCH) })
        web.failAll = false
        now += CheckPlan.MINUTE
        assertEquals("back online: due right away", Standalone.Outcome.DONE, wait { engine.checkIfDue(Trigger.FOREGROUND) })
        assertFalse(engine.state.value.lastCheck!!.offline)
        now += CheckPlan.MINUTE
        assertEquals(Standalone.Outcome.NOT_DUE, wait { engine.checkIfDue(Trigger.FOREGROUND) })
    }

    @Test fun aLiveTabWithoutStatesIsAskedAgain() {
        // An older yt-dlp: the Live tab's entries say nothing about being live, upcoming or past.
        streamsTab = """{"entries":[{"id":"stream00001","title":"A stream"}]}"""
        followAndSeed()
        assertEquals(0L, engine.state.value.fetchedAt.getValue(CHANNEL_A).streams)
        assertFalse(engine.channels.value.single().recent.any { it.video.isPastStream })
        streamsTab = """{"entries":[{"id":"stream00001","title":"A stream","live_status":"was_live","timestamp":1700000000}]}"""
        now += CheckPlan.MINUTE
        assertEquals(Standalone.Outcome.DONE, wait { engine.checkIfDue(Trigger.LAUNCH) })
        assertEquals(now, engine.state.value.fetchedAt.getValue(CHANNEL_A).streams)
        assertTrue(engine.channels.value.single().recent.any { it.video.isPastStream })
    }

    @Test fun aSeedCountsAsReadingTheChannels() {
        assertEquals(0L, engine.checkStatus.value.lastReadAt)
        followAndSeed()
        assertEquals("a seed isn't the last check", null, engine.state.value.lastCheck)
        assertEquals(now, engine.checkStatus.value.lastReadAt)
    }

    @Test fun signedInReadsYouTubesFeedsWithoutShortsOrLive() {
        followAndSeed()
        assertEquals(Standalone.SignInResult.Done, wait { engine.signIn(fixture("fake-cookies.txt"), Standalone.SOURCE_FILE) })
        assertEquals(AccountState.SIGNED_IN, engine.account.value.state)
        assertEquals("file", engine.account.value.source)
        assertNotNull(vault.load())
        waitUntil { engine.state.value.accountFeeds != null && engine.state.value.lastWatchSync > 0 }
        // The members-only one shows once its access is known (watchable).
        wait { engine.youtubeFeeds.first { feeds -> feeds.recommended.any { it.id == "membersvid1" } } }
        assertEquals(listOf("feedvideo01", "membersvid1"), engine.youtubeFeeds.value.recommended.map { it.id })
        assertTrue(tool.ran(":ytsubs"))
        // The members feed was read with the cookies, and its video became watchable.
        wait { engine.channels.first { c -> c.single().recent.any { it.video.id == "memberonly1" } } }
        assertEquals(MemberAccess.Watchable, engine.state.value.memberAccess["memberonly1"])
    }

    @Test fun rejectedCookiesArentStored() {
        feedsRejected = true
        val result = wait { engine.signIn(fixture("fake-cookies.txt"), Standalone.SOURCE_FILE) }
        assertEquals(Standalone.SignInResult.Failed(Standalone.REJECTED), result)
        assertNull(vault.load())
        assertEquals(AccountState.SIGNED_OUT, engine.account.value.state)
        assertEquals(Standalone.SignInResult.Failed(Standalone.NO_SIGN_IN_IN_FILE),
                     wait { engine.signIn("# Netscape HTTP Cookie File\n.example.com\tTRUE\t/\tTRUE\t0\tA\tb\n", Standalone.SOURCE_FILE) })
    }

    @Test fun youtubeSigningYouOutIsNoticedOnce() {
        followAndSeed()
        feedsRejected = true
        wait { engine.signIn(fixture("fake-cookies.txt"), Standalone.SOURCE_FILE, verify = false) }
        waitUntil { engine.account.value.state == AccountState.EXPIRED }
        assertEquals(1, host.signedOutNotices)
        val feedReads = tool.runs.count { it.first.last() == ":ytrec" }
        now += CheckPlan.MINUTE
        wait { engine.refresh() }
        assertEquals("no second notice", 1, host.signedOutNotices)
        assertEquals("feeds skipped while expired", feedReads, tool.runs.count { it.first.last() == ":ytrec" })
        // An hour on, a probe that YouTube accepts signs it back in.
        feedsRejected = false
        now += CheckPlan.HOUR
        wait { engine.refresh() }
        assertEquals(AccountState.SIGNED_IN, engine.account.value.state)
    }

    @Test fun signingOutClearsEverythingItRead() {
        followAndSeed()
        wait { engine.signIn(fixture("fake-cookies.txt"), Standalone.SOURCE_FILE) }
        waitUntil { engine.state.value.accountFeeds != null }
        engine.onWatched("vid00000001", true)
        engine.signOut()
        val s = engine.state.value
        assertNull(vault.load())
        assertEquals(AccountState.SIGNED_OUT, s.account.state)
        assertNull(s.accountFeeds)
        assertTrue(s.memberAccess.isEmpty() && s.youTubeHistory.isEmpty() && s.pendingYouTubeWatched.isEmpty())
        assertEquals(0L, s.lastWatchSync)
        assertEquals(1, host.webDataCleared)
        assertTrue(engine.youtubeFeeds.value.isEmpty)
        // The members-only video hides again (its access is unknown); the rest stay.
        assertFalse(engine.channels.value.single().recent.any { it.video.id == "memberonly1" })
        assertTrue(engine.channels.value.single().recent.any { it.video.id == "vid00000001" })
    }

    @Test fun watchedOnYouTubeBeforeStowFoundItIsWatchedHere() {
        history = """{"entries":[{"id":"vid00000002"}]}"""
        wait { engine.signIn(fixture("fake-cookies.txt"), Standalone.SOURCE_FILE) }
        waitUntil { engine.state.value.youTubeHistory.isNotEmpty() }
        followAndSeed()
        assertTrue("vid00000002" in host.watched)
        assertFalse("vid00000001" in host.watched)
    }

    @Test fun watchedHereGoesToYouTube() {
        wait { engine.signIn(fixture("fake-cookies.txt"), Standalone.SOURCE_FILE) }
        waitUntil { engine.checkStatus.value.lastCheck != null }
        engine.onWatched("vid00000001", true)
        wait { engine.state.first { it.pendingYouTubeWatched.isEmpty() } }
        assertTrue(tool.runs.any { (args, cookies) -> "--mark-watched" in args && args.last().endsWith("vid00000001") && cookies != null })
        // Turning sync off drops what's waiting.
        engine.setSyncWatched(false)
        engine.onWatched("vid00000002", true)
        assertTrue(engine.state.value.pendingYouTubeWatched.isEmpty())
    }

    @Test fun groupsFollowWhatTheyHoldAndLoseWhatsRemoved() {
        followAndSeed()
        val followed = engine.editGroupsLocally { listOf(dev.stow.android.data.ChannelGroup("g", "News", listOf(GroupChannel(CHANNEL_A, "Test")))) }
        assertTrue(followed.isEmpty())
        val more = engine.setInGroup("g", GroupChannel(CHANNEL_B, "Bee"), true)
        assertEquals(listOf(CHANNEL_B), more.map { it.id })
        assertTrue(engine.state.value.isFollowed(CHANNEL_B))
        assertEquals("Test", engine.unfollow(CHANNEL_A))
        assertEquals(listOf(CHANNEL_B), engine.groups.value.single().channels.map { it.id })
        assertNull(engine.state.value.recentVideos[CHANNEL_A])
        assertNull(engine.state.value.fetchedAt[CHANNEL_A])
    }

    @Test fun movingChannels() {
        engine.addChannels(listOf(ChannelInfo(CHANNEL_A, "A"), ChannelInfo(CHANNEL_B, "B")))
        engine.moveChannel(CHANNEL_B, -1)
        assertEquals(listOf(CHANNEL_B, CHANNEL_A), engine.state.value.channels.map { it.id })
        engine.moveChannel(CHANNEL_B, -1)
        assertEquals(listOf(CHANNEL_B, CHANNEL_A), engine.state.value.channels.map { it.id })
    }

    @Test fun leavingForTheMacAndComingBack() {
        followAndSeed()
        engine.editGroupsLocally { listOf(dev.stow.android.data.ChannelGroup("g", "News", listOf(GroupChannel(CHANNEL_A, "Test")))) }
        wait { engine.signIn(fixture("fake-cookies.txt"), Standalone.SOURCE_FILE) }
        waitUntil { engine.state.value.lastWatchSync > 0 }
        wait { engine.leave() }
        assertNull("signed out of YouTube", vault.load())
        assertTrue("standalone.json kept", File(dir, "standalone.json").exists())
        // Back to standalone: a fresh engine (as after the switch) has it all back.
        val back = newEngine()
        assertEquals(listOf(CHANNEL_A), back.state.value.channels.map { it.id })
        assertEquals("News", back.groups.value.single().name)
        assertTrue(back.channels.value.single().recent.isNotEmpty())
        assertEquals(AccountState.SIGNED_OUT, back.account.value.state)
    }

    @Test fun theMacsChannelsAreKeptWhenSwitching() {
        val mac = listOf(dev.stow.android.data.Channel(CHANNEL_B, "Bee", null, null, 0, emptyList()))
        engine.adoptMac(mac, emptyList())
        wait { engine.flush() }
        assertEquals(listOf(CHANNEL_B), newEngine().state.value.channels.map { it.id })
    }

    // YouTube's RSS down: yt-dlp's approximate dates

    @Test fun theVideosTabsApproximateDatesDontReplaceTheFeeds() {
        followAndSeed()
        val fromFeed = published("vid00000001")
        // The playlist feeds fail; the Videos tab rounds every date to the same day.
        web.set(uploads, "", 503)
        val day = 1_799_000_000L
        videosTab = """{"channel_id":"$CHANNEL_A","channel":"Test","entries":[
            {"id":"tabvideo001","title":"Newest","timestamp":$day,"duration":700},
            {"id":"vid00000001","title":"Known","timestamp":$day,"duration":700},
            {"id":"tabvideo002","title":"Older","timestamp":$day,"duration":700},
            {"id":"tabvideo003","title":"Oldest","timestamp":$day,"duration":700}]}""".replace("\n", "")
        assertEquals(Standalone.Outcome.DONE, wait { engine.refresh() })
        assertEquals("a feed's date stays", fromFeed, published("vid00000001"))
        // The tab's order is kept: each one a minute before the one listed above it.
        assertEquals(day * 1000, published("tabvideo001"))
        assertEquals(day * 1000 - 2 * 60_000, published("tabvideo002"))
        assertEquals(day * 1000 - 3 * 60_000, published("tabvideo003"))
        val order = engine.channels.value.single().recent.map { it.video.id }
        assertTrue(order.indexOf("tabvideo001") < order.indexOf("tabvideo002") && order.indexOf("tabvideo002") < order.indexOf("tabvideo003"))
        // Checked again, still from the tab: the dates don't move.
        now += CheckPlan.HOUR
        videosTab = videosTab.replace("$day", "${day + 86_400}")
        assertEquals(Standalone.Outcome.DONE, wait { engine.refresh() })
        assertEquals(day * 1000 - 2 * 60_000, published("tabvideo002"))
        // The feed back: its date wins over the tab's.
        web.set(uploads, fixture("rss-uploads.xml"))
        videosTab = videosTab.replace("tabvideo002", "vid00000002")
        now += CheckPlan.HOUR
        assertEquals(Standalone.Outcome.DONE, wait { engine.refresh() })
        assertEquals(fromFeed, published("vid00000001"))
    }

    @Test fun aLiveTabWithoutItsFeedKeepsTheFirstDate() {
        // No UULV feed (FakeWeb answers 404): the Live tab's dates are yt-dlp's.
        followAndSeed()
        val first = published("stream00001")
        streamsTab = streamsTab.replace("1700000000", "1700086400")
        now += 24 * CheckPlan.HOUR
        assertEquals(Standalone.Outcome.DONE, wait { engine.refresh() })
        assertEquals(first, published("stream00001"))
    }

    // Seeds

    @Test fun aSeedLeavesTheScheduleTheStreakAndTheBackoff() {
        followAndSeed()
        web.set(uploads, "", 429)
        assertEquals(Standalone.Outcome.SLOWED_DOWN, wait { engine.refresh() })
        val before = engine.state.value
        assertEquals(1, before.failedCheckStreak)
        assertEquals(30, before.backoffMinutes)
        // A new channel's first fetch works: none of that changes.
        web.set(RssFeed.playlistUrl(RssFeed.Playlists.uploads(CHANNEL_B)), fixture("rss-uploads.xml"))
        now += CheckPlan.MINUTE
        assertTrue(engine.follow(ChannelInfo(CHANNEL_B, "Bee")))
        waitUntil { engine.state.value.recentVideos[CHANNEL_B] != null }
        val after = engine.state.value
        assertEquals(before.lastCheck, after.lastCheck)
        assertEquals(1, after.failedCheckStreak)
        assertEquals(30, after.backoffMinutes)
        assertEquals("the backoff isn't cleared", before.backoffUntil, after.backoffUntil)
        assertEquals("automatic checks still wait", Standalone.Outcome.NOT_DUE, wait { engine.checkIfDue(Trigger.FOREGROUND) })
        // A seed YouTube slows down still doubles it.
        val channelC = "UC" + "c".repeat(22)
        web.set(RssFeed.playlistUrl(RssFeed.Playlists.uploads(channelC)), "", 503)
        videosTabFailure = "ERROR: HTTP Error 503: Service Unavailable"
        now += CheckPlan.MINUTE
        assertTrue(engine.follow(ChannelInfo(channelC, "Sea")))
        waitUntil { engine.state.value.backoffMinutes == 60 }
        assertEquals(now + 60 * CheckPlan.MINUTE, engine.state.value.backoffUntil)
        assertEquals(before.lastCheck, engine.state.value.lastCheck)
        assertEquals(1, engine.state.value.failedCheckStreak)
    }

    // The vault

    @Test fun aSignInLeftFromBeforeIsDeletedAtStart() {
        vault.save("left over")
        newEngine()
        assertFalse(vault.hasItem())
        // An unreadable one (a key without its file) too.
        vault.unreadableLeftover = true
        newEngine()
        assertFalse(vault.hasItem())
    }

    @Test fun aSignedInPhoneKeepsItsSignInAtStart() {
        wait { engine.signIn(fixture("fake-cookies.txt"), Standalone.SOURCE_FILE, verify = false) }
        wait { engine.flush() }
        val back = newEngine()
        assertEquals(AccountState.SIGNED_IN, back.account.value.state)
        assertNotNull(vault.load())
    }

    @Test fun aSignInTheVaultCantKeepFails() {
        vault.failSaves = true
        val result = wait { engine.signIn(fixture("fake-cookies.txt"), Standalone.SOURCE_FILE) }
        assertEquals(Standalone.SignInResult.Failed(Standalone.NOT_KEPT), result)
        assertEquals("Couldn't keep the sign-in on this phone. Try again.", Standalone.NOT_KEPT)
        assertEquals(AccountState.SIGNED_OUT, engine.account.value.state)
        assertNull(vault.load())
        // Signing out with a refusing vault doesn't throw.
        engine.signOut()
        assertEquals(AccountState.SIGNED_OUT, engine.account.value.state)
    }
}

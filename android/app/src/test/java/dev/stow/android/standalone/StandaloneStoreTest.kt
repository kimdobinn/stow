package dev.stow.android.standalone

import dev.stow.android.data.ChannelGroup
import dev.stow.android.data.GroupChannel
import dev.stow.android.data.Video
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.Date

class StandaloneStoreTest {
    private val video = Video("vid00000001", CHANNEL_A, "Test", "A video", Date(1_700_000_000_000L), "https://thumb", false, "wasLive", 3600)
    private val state = StandaloneState(
        channels = listOf(FollowedChannel(CHANNEL_A, "Test", "@test", "https://avatar", 1), FollowedChannel(CHANNEL_B, "Other")),
        fetchedAt = mapOf(CHANNEL_A to FetchedAt(1, 2, 3)),
        recentVideos = mapOf(CHANNEL_A to listOf(RecentEntry(video, 5), RecentEntry(video.copy(id = "vid00000002", publishedAt = null, liveStatus = null,
                                                                                               durationSeconds = null, thumbnailUrl = null, isMembersOnly = true), 6))),
        groups = listOf(ChannelGroup("g1", "News", listOf(GroupChannel(CHANNEL_A, "Test")))),
        memberAccess = mapOf("a" to MemberAccess.Watchable, "b" to MemberAccess.Locked("Gold"), "c" to MemberAccess.Locked(null), "d" to MemberAccess.NowPublic),
        nonMemberChannels = mapOf(CHANNEL_B to 7),
        noMembersPlaylist = mapOf(CHANNEL_A to 8),
        accountFeeds = StoredFeeds(listOf(video), listOf(video.copy(id = "vid00000003")), mapOf(CHANNEL_A to "https://a"), 9),
        channelAvatars = mapOf(CHANNEL_B to "https://b"),
        account = AccountInfo(AccountState.EXPIRED, 10, "file", 11),
        syncWatchedWithYouTube = false,
        youTubeHistory = listOf("h1", "h2"),
        pendingYouTubeWatched = listOf("p1"),
        lastWatchSync = 12,
        lastCheck = CheckRecord("pull", 13, 14, 2, listOf("an error")),
        lastPullAt = 15,
        failedCheckStreak = 1,
        backoffUntil = 16,
        backoffMinutes = 30,
        channelErrors = mapOf(CHANNEL_B to "Channel not found"),
    )

    @Test fun roundTrips() {
        assertEquals(state, StandaloneJson.decode(StandaloneJson.encode(state)))
        val offline = state.copy(lastCheck = CheckRecord("launch", 1, 2, 3, listOf("offline"), offline = true))
        assertEquals(offline, StandaloneJson.decode(StandaloneJson.encode(offline)))
        assertFalse("only said when true", JSONObject(StandaloneJson.encode(state)).getJSONObject("lastCheck").has("offline"))
        assertEquals(StandaloneState(), StandaloneJson.decode(StandaloneJson.encode(StandaloneState())))
    }

    @Test fun theSchemasNamesAndForms() {
        val o = JSONObject(StandaloneJson.encode(state))
        assertEquals(1, o.getInt("version"))
        assertEquals("avatarURL", o.getJSONArray("channels").getJSONObject(0).keys().asSequence().first { it.startsWith("avatar") })
        val v = o.getJSONObject("recentVideos").getJSONArray(CHANNEL_A).getJSONObject(0)
        assertEquals(1_700_000_000_000L, v.getLong("publishedAt"))
        assertEquals("wasLive", v.getString("liveStatus"))
        assertEquals("https://thumb", v.getString("thumbnailURL"))
        assertEquals(5, v.getLong("foundAt"))
        assertEquals("locked:Gold", o.getJSONObject("memberAccess").getString("b"))
        assertEquals("expired", o.getJSONObject("account").getString("state"))
        assertFalse("never cookie values", o.getJSONObject("account").has("cookies"))
    }

    @Test fun keysFromANewerVersionAreKept() {
        val newer = JSONObject(StandaloneJson.encode(state)).put("futureThing", JSONObject().put("x", 1)).put("futureFlag", true).toString()
        val decoded = StandaloneJson.decode(newer)
        assertEquals(state, decoded.copy(unknown = emptyMap()))
        val saved = JSONObject(StandaloneJson.encode(decoded.copy(failedCheckStreak = 2)))
        assertEquals(1, saved.getJSONObject("futureThing").getInt("x"))
        assertTrue(saved.getBoolean("futureFlag"))
        assertEquals(2, saved.getInt("failedCheckStreak"))
    }

    @Test fun savesAtomicallyAndLoads() {
        val dir = Files.createTempDirectory("stow").toFile()
        try {
            val store = StandaloneStore(File(dir, "standalone.json"))
            assertEquals(StandaloneState(), store.load())
            store.save(state)
            assertEquals(state, store.load())
            assertFalse(File(dir, "standalone.json.tmp").exists())
            File(dir, "standalone.json").writeText("{ broken")
            assertEquals(StandaloneState(), store.load())
        } finally {
            dir.deleteRecursively()
        }
    }
}

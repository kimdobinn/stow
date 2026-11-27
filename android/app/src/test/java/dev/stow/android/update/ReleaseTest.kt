package dev.stow.android.update

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VersionsTest {
    @Test fun comparesNumbersNotText() {
        assertTrue(Versions.isNewer("0.10.0", "0.9.1"))
        assertTrue(Versions.isNewer("0.8.2", "0.8.1"))
        assertTrue(Versions.isNewer("1.0.0", "0.99.99"))
        assertFalse(Versions.isNewer("0.9.1", "0.10.0"))
    }

    @Test fun sameVersionIsNotNewer() {
        assertFalse(Versions.isNewer("0.8.1", "0.8.1"))
        assertEquals(0, Versions.compare("1.0", "1.0.0"))
        assertEquals(0, Versions.compare("v1.2.3", "1.2.3"))
    }

    @Test fun extraPartsCount() {
        assertTrue(Versions.isNewer("0.8.1.1", "0.8.1"))
        assertFalse(Versions.isNewer("0.8", "0.8.1"))
    }

    @Test fun ignoresSuffixes() {
        assertEquals(0, Versions.compare("0.8.1-debug", "0.8.1"))
        assertTrue(Versions.isNewer("0.9.0-rc1", "0.8.1"))
    }
}

class ReleaseTest {
    private fun asset(name: String, size: Long = 1234, url: String = "https://github.com/kimdobinn/stow/releases/download/x/$name") =
        JSONObject().put("name", name).put("size", size).put("state", "uploaded").put("browser_download_url", url)

    private fun release(tag: String, vararg assets: JSONObject, prerelease: Boolean = false, draft: Boolean = false, body: String = "- Something") =
        JSONObject().put("tag_name", tag).put("prerelease", prerelease).put("draft", draft).put("body", body)
            .put("assets", JSONArray(assets.toList()))

    @Test fun readsAPhoneRelease() {
        val r = Release.parse(release("v0.8.2", asset("Stow-0.8.2.apk", 98_765_432), body = "- Fix\r\n- Faster"))!!
        assertEquals("0.8.2", r.version)
        assertEquals("Stow-0.8.2.apk", r.apkName)
        assertEquals(98_765_432L, r.apkSize)
        assertEquals("https://github.com/kimdobinn/stow/releases/download/x/Stow-0.8.2.apk", r.apkUrl)
        assertEquals("- Fix\n- Faster", r.notes)
    }

    @Test fun skipsIphoneAndMacReleases() {
        assertNull(Release.parse(release("ios-v0.1.0", asset("Stow.ipa"), prerelease = true)))
        assertNull(Release.parse(release("mac-v1.2.0", asset("Stow.zip"), prerelease = true)))
        // Even if one weren't marked as a pre-release.
        assertNull(Release.parse(release("ios-v0.1.0", asset("Stow-0.1.0.apk"))))
        assertNull(Release.parse(release("mac-v1.2.0", asset("Stow-1.2.0.apk"))))
    }

    @Test fun skipsPreReleasesAndDrafts() {
        assertNull(Release.parse(release("v0.9.0", asset("Stow-0.9.0.apk"), prerelease = true)))
        assertNull(Release.parse(release("v0.9.0", asset("Stow-0.9.0.apk"), draft = true)))
    }

    @Test fun needsAVersionTag() {
        assertNull(Release.parse(release("latest", asset("Stow.apk"))))
        assertNull(Release.parse(release("v0.9.0-beta", asset("Stow.apk"))))
        assertNull(Release.parse(release("0.9.0", asset("Stow-0.9.0.apk"))))
    }

    @Test fun needsAnApk() {
        assertNull(Release.parse(release("v0.9.0")))
        assertNull(Release.parse(release("v0.9.0", asset("Stow-0.9.0.zip"), asset("notes.txt"))))
        assertNull(Release.parse(JSONObject().put("tag_name", "v0.9.0")))
        // Still uploading, or empty.
        assertNull(Release.parse(release("v0.9.0", asset("Stow-0.9.0.apk").put("state", "new"))))
        assertNull(Release.parse(release("v0.9.0", asset("Stow-0.9.0.apk", size = 0))))
    }

    @Test fun prefersTheVersionsOwnApk() {
        val r = Release.parse(release("v0.9.0", asset("other.apk", 1), asset("Stow-0.9.0.apk", 2), asset("Stow-0.9.0.apk.sha256", 3)))!!
        assertEquals("Stow-0.9.0.apk", r.apkName)
        assertEquals(2L, r.apkSize)
    }

    @Test fun takesAnyApkOtherwise() {
        val r = Release.parse(release("v0.9.0", asset("README.md"), asset("app-release.APK", 7)))!!
        assertEquals("app-release.APK", r.apkName)
    }

    @Test fun readsGithubsJson() {
        // Trimmed from api.github.com/repos/…/releases/latest.
        val json = """
            {"url":"https://api.github.com/repos/kimdobinn/stow/releases/1","tag_name":"v0.10.0","name":"Stow 0.10.0",
             "draft":false,"prerelease":false,"body":"- Updates from Settings",
             "assets":[{"name":"Stow-0.10.0.apk","state":"uploaded","size":123456789,"content_type":"application/vnd.android.package-archive",
                        "browser_download_url":"https://github.com/kimdobinn/stow/releases/download/v0.10.0/Stow-0.10.0.apk"}]}
        """
        val r = Release.parse(json)!!
        assertEquals("0.10.0", r.version)
        assertTrue(Versions.isNewer(r.version, "0.9.1"))
        assertEquals(123_456_789L, r.apkSize)
    }

    @Test fun roundTripsThroughPrefs() {
        val r = Release("0.8.2", "- Fix", "Stow-0.8.2.apk", "https://example.com/Stow-0.8.2.apk", 42)
        assertEquals(r, Release.fromJson(r.toJson()))
        assertNull(Release.fromJson(null))
        assertNull(Release.fromJson("not json"))
    }
}

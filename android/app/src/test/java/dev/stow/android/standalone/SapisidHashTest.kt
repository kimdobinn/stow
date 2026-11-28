package dev.stow.android.standalone

import dev.stow.android.account.Cookie
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.security.MessageDigest

class SapisidHashTest {
    private fun sha1(text: String) = MessageDigest.getInstance("SHA-1").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }

    @Test fun theHashIsTimestampAndSha1() {
        // sha1("1700000000 abc/def https://www.youtube.com")
        val expected = "1700000000_" + sha1("1700000000 abc/def https://www.youtube.com")
        assertEquals(expected, SubscriptionsImport.sapisidHash(1_700_000_000, "abc/def"))
        assertEquals(51, expected.length)
    }

    @Test fun theAuthorizationHeaderHasAllThree() {
        val cookies = listOf(Cookie(".youtube.com", "SAPISID", "s"), Cookie(".youtube.com", "__Secure-1PAPISID", "one"),
                             Cookie(".youtube.com", "__Secure-3PAPISID", "three"))
        val ts = 1_700_000_000L
        assertEquals("SAPISIDHASH ${SubscriptionsImport.sapisidHash(ts, "s")} SAPISID1PHASH ${SubscriptionsImport.sapisidHash(ts, "one")} " +
                     "SAPISID3PHASH ${SubscriptionsImport.sapisidHash(ts, "three")}", SubscriptionsImport.authorization(cookies, ts))
        // Without SAPISID, SAPISIDHASH uses the 3P one.
        assertEquals("SAPISIDHASH ${SubscriptionsImport.sapisidHash(ts, "three")} SAPISID3PHASH ${SubscriptionsImport.sapisidHash(ts, "three")}",
                     SubscriptionsImport.authorization(listOf(cookies[2]), ts))
        assertNull(SubscriptionsImport.authorization(emptyList(), ts))
    }

    @Test fun continuationHeaders() {
        val config = JSONObject("""{"SESSION_INDEX":"1","INNERTUBE_CONTEXT_CLIENT_NAME":1,"INNERTUBE_CLIENT_VERSION":"2.2026","DELEGATED_SESSION_ID":"42"}""")
        val headers = SubscriptionsImport.continuationHeaders(config, listOf(Cookie(".youtube.com", "SAPISID", "s")), 10)
        assertEquals("application/json", headers["Content-Type"])
        assertEquals("https://www.youtube.com", headers["X-Origin"])
        assertEquals("https://www.youtube.com", headers["Origin"])
        assertEquals("1", headers["X-Goog-AuthUser"])
        assertEquals("1", headers["X-Youtube-Client-Name"])
        assertEquals("2.2026", headers["X-Youtube-Client-Version"])
        assertEquals("42", headers["X-Goog-PageId"])
        assertEquals("SAPISIDHASH ${SubscriptionsImport.sapisidHash(10, "s")}", headers["Authorization"])
        val plain = SubscriptionsImport.continuationHeaders(JSONObject(), emptyList(), 10)
        assertEquals("0", plain["X-Goog-AuthUser"])
        assertNull(plain["X-Goog-PageId"])
        assertNull(plain["Authorization"])
    }
}

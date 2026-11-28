package dev.stow.android.account

import dev.stow.android.standalone.fixture
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NetscapeCookiesTest {
    private val now = 1_800_000_000_000L
    private val nowSeconds = now / 1000

    @Test fun formatSortsKeepsOnlyYouTubeAndGoogleAndGivesSessionCookiesAYear() {
        val text = NetscapeCookies.format(listOf(
            Cookie(".youtube.com", "SAPISID", "s", expiry = 2_000_000_000),
            Cookie("www.youtube.com", "PREF", "p", path = "/", secure = false),
            Cookie(".google.com", "SID", "g", expiry = 2_000_000_000),
            Cookie(".example.com", "X", "x"),
            Cookie(".youtube.com", "BAD", "a\tb"),
            Cookie(".youtube.com", "ALSOBAD", "a\nb"),
            Cookie(".youtube.com", "LOGIN_INFO", "l", expiry = 2_000_000_000),
        ), now)
        val lines = text.lines()
        assertEquals("# Netscape HTTP Cookie File", lines[0])
        assertEquals("", lines[1])
        assertEquals(listOf(
            ".google.com\tTRUE\t/\tTRUE\t2000000000\tSID\tg",
            ".youtube.com\tTRUE\t/\tTRUE\t2000000000\tLOGIN_INFO\tl",
            ".youtube.com\tTRUE\t/\tTRUE\t2000000000\tSAPISID\ts",
            // Host-only (no leading dot): FALSE; a session cookie lasts a year from now.
            "www.youtube.com\tFALSE\t/\tFALSE\t${nowSeconds + 365 * 24 * 3600}\tPREF\tp",
        ), lines.drop(2).filter { it.isNotEmpty() })
        assertTrue(text.endsWith("\n"))
    }

    @Test fun parseReadsHttpOnlyLinesAndSkipsTheRest() {
        val cookies = NetscapeCookies.parse("""
            # Netscape HTTP Cookie File
            # a comment

            #HttpOnly_.youtube.com	TRUE	/	TRUE	2000000000	LOGIN_INFO	abc
            .youtube.com	TRUE	/	TRUE	0	PREF	f6=8
            .example.com	TRUE	/	TRUE	2000000000	OTHER	x
            accounts.google.com	FALSE	/	TRUE	2000000000	LSID	l
            .youtube.com	TRUE	/	TRUE	too few
        """.trimIndent().replace("    ", ""))
        assertEquals(listOf("LOGIN_INFO", "PREF", "LSID"), cookies.map { it.name })
        assertTrue(cookies[0].httpOnly)
        assertNull("0 means a session cookie", cookies[1].expiry)
        assertEquals("f6=8", cookies[1].value)
        assertFalse(cookies[2].includeSubdomains)
    }

    @Test fun theSharedFakeCookiesAreASignIn() {
        val cookies = NetscapeCookies.parse(fixture("fake-cookies.txt"))
        assertEquals(3, cookies.size)
        assertTrue(NetscapeCookies.isSignedIn(cookies, now))
        assertEquals("LOGIN_INFO=FAKE;SAPISID=fake/fake;__Secure-3PAPISID=fake/fake", NetscapeCookies.sessionFingerprint(cookies, now))
        assertEquals(4102444800L, NetscapeCookies.loginInfoExpiry(cookies))
    }

    @Test fun signedInNeedsUnexpiredLoginInfoAndASapisidOnYouTube() {
        val login = Cookie(".youtube.com", "LOGIN_INFO", "l", expiry = nowSeconds + 100)
        val sapisid = Cookie(".youtube.com", "__Secure-1PAPISID", "s")
        assertNotNull(NetscapeCookies.sessionFingerprint(listOf(login, sapisid), now))
        assertNull(NetscapeCookies.sessionFingerprint(listOf(login), now))
        assertNull(NetscapeCookies.sessionFingerprint(listOf(sapisid), now))
        assertNull("expired", NetscapeCookies.sessionFingerprint(listOf(login.copy(expiry = nowSeconds - 1), sapisid), now))
        assertNull("google.com isn't enough", NetscapeCookies.sessionFingerprint(listOf(login, sapisid.copy(domain = ".google.com")), now))
        assertTrue(NetscapeCookies.sessionFingerprint(listOf(login, sapisid), now) != NetscapeCookies.sessionFingerprint(listOf(login.copy(value = "new"), sapisid), now))
    }

    @Test fun cookieInfoStringsBecomeCookies() {
        val withDomain = NetscapeCookies.parseCookieInfo(
            "LOGIN_INFO=AFmmF2s; Domain=.youtube.com; Path=/; Expires=Fri, 01 Jan 2027 00:00:00 GMT; Secure; HttpOnly", "www.youtube.com", now)!!
        assertEquals(Cookie(".youtube.com", "LOGIN_INFO", "AFmmF2s", "/", true, 1798761600L, true), withDomain)
        val noDot = NetscapeCookies.parseCookieInfo("SID=x; domain=google.com; path=/", "www.google.com", now)!!
        assertEquals(".google.com", noDot.domain)
        assertFalse(noDot.secure)
        // No Domain: host-only for the URL's host.
        val hostOnly = NetscapeCookies.parseCookieInfo("YSC=abc; Path=/; Secure", "www.youtube.com", now)!!
        assertEquals("www.youtube.com", hostOnly.domain)
        assertFalse(hostOnly.includeSubdomains)
        assertNull(hostOnly.expiry)
        val maxAge = NetscapeCookies.parseCookieInfo("VISITOR=v; Max-Age=3600; Domain=.youtube.com", "m.youtube.com", now)!!
        assertEquals(nowSeconds + 3600, maxAge.expiry)
        val dashed = NetscapeCookies.parseCookieInfo("A=b; Expires=Fri, 01-Jan-2027 00:00:00 GMT", "www.youtube.com", now)!!
        assertEquals(1798761600L, dashed.expiry)
        assertNull(NetscapeCookies.parseCookieInfo("garbage", "www.youtube.com", now))
        assertEquals("host-prefixed cookies keep the exact host", "www.youtube.com",
                     NetscapeCookies.parseCookieInfo("__Host-X=1; Path=/; Secure", "www.youtube.com", now)!!.domain)
    }

    @Test fun theFallbackWritesWholeSiteCookiesForFourHundredDays() {
        val cookies = NetscapeCookies.fromCookieHeader("LOGIN_INFO=l; SAPISID=s=x; __Host-GAPS=g; bad", "www.youtube.com", now)
        assertEquals(listOf("LOGIN_INFO", "SAPISID", "__Host-GAPS"), cookies.map { it.name })
        assertEquals("s=x", cookies[1].value)
        assertEquals(listOf(".youtube.com", ".youtube.com", "www.youtube.com"), cookies.map { it.domain })
        assertTrue(cookies.all { it.secure && it.path == "/" && it.expiry == nowSeconds + 400L * 24 * 3600 })
        assertEquals(".google.com", NetscapeCookies.fromCookieHeader("SID=1", "accounts.google.com", now).single().domain)
        assertTrue(NetscapeCookies.fromCookieHeader("A=1", "example.com", now).isEmpty())
        // Read from www then m: www's copy wins.
        val merged = NetscapeCookies.deduplicate(
            NetscapeCookies.fromCookieHeader("PREF=www", "www.youtube.com", now) + NetscapeCookies.fromCookieHeader("PREF=m", "m.youtube.com", now))
        assertEquals("www", merged.single().value)
        // The fallback's cookies are a sign-in yt-dlp accepts.
        assertTrue(NetscapeCookies.isSignedIn(cookies, now))
    }

    @Test fun aCookieHeaderForAHost() {
        val cookies = listOf(Cookie(".youtube.com", "A", "1"), Cookie("www.youtube.com", "B", "2"), Cookie("m.youtube.com", "C", "3"),
                             Cookie(".google.com", "D", "4"), Cookie(".youtube.com", "A", "dup"))
        assertEquals("A=1; B=2", NetscapeCookies.header(cookies, "www.youtube.com"))
    }

    @Test fun formatThenParseRoundTrips() {
        val cookies = NetscapeCookies.parse(fixture("fake-cookies.txt"))
        assertEquals(cookies, NetscapeCookies.parse(NetscapeCookies.format(cookies, now)))
    }
}

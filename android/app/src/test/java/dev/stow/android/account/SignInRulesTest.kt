package dev.stow.android.account

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SignInRulesTest {
    @Test fun theUserAgentReadsAsChrome() {
        val webView = "Mozilla/5.0 (Linux; Android 16; sdk_gphone64_arm64 Build/BP22.250221.010; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/141.0.7390.122 Mobile Safari/537.36"
        assertEquals("Mozilla/5.0 (Linux; Android 16; sdk_gphone64_arm64 Build/BP22.250221.010) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.7390.122 Mobile Safari/537.36",
                     SignInRules.userAgent(webView))
    }

    @Test fun googleRefusingIsNoticed() {
        assertTrue(SignInRules.isBlocked("https://accounts.google.com/v3/signin/rejected?continue=x", "Sign in"))
        assertTrue(SignInRules.isBlocked("https://accounts.google.com/signin/rejected", null))
        assertTrue(SignInRules.isBlocked("https://accounts.google.com/x", "This browser or app may not be secure"))
        assertFalse(SignInRules.isBlocked("https://accounts.google.com/v3/signin/identifier?flow=rejected", "Sign in"))
    }

    @Test fun doneOnceYouTubeHasANewSession() {
        assertTrue(SignInRules.isDone("www.youtube.com", loading = false, fingerprint = "a", initialFingerprint = null))
        assertFalse(SignInRules.isDone("m.youtube.com", loading = true, fingerprint = "a", initialFingerprint = null))
        assertFalse(SignInRules.isDone("accounts.google.com", loading = false, fingerprint = "a", initialFingerprint = null))
        assertFalse(SignInRules.isDone("www.youtube.com", loading = false, fingerprint = null, initialFingerprint = null))
        assertFalse(SignInRules.isDone("www.youtube.com", loading = false, fingerprint = "a", initialFingerprint = "a"))
    }

    @Test fun aRefusedSessionDoesntCountAgainButANewOneDoes() {
        val sessions = SignInRules.Sessions()
        assertFalse("still loading", sessions.take("www.youtube.com", loading = true, fingerprint = "a"))
        assertTrue(sessions.take("www.youtube.com", loading = false, fingerprint = "a"))
        // YouTube refused it; whatever survived the wipe doesn't start another round.
        assertFalse(sessions.take("www.youtube.com", loading = false, fingerprint = "a"))
        assertFalse("back on Google's login", sessions.take("accounts.google.com", loading = false, fingerprint = null))
        // Signed in again: a new session.
        assertTrue(sessions.take("m.youtube.com", loading = false, fingerprint = "b"))
        assertEquals("b", sessions.taken)
    }
}

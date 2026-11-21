package dev.stow.android.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The fixed vector both sides check, so the phone and the Mac agree on the signature. */
class RemoteSignerTest {
    private val key = ByteArray(32) { it.toByte() }
    private val body = """{"action":"next"}""".toByteArray()
    private val nonce = "000102030405060708090a0b0c0d0e0f"

    @Test
    fun canonicalStringMatchesTheContract() {
        assertEquals(
            "POST\n/v1/action\n1700000000000\n$nonce\n282c6f52c450254aa3d4a831f1aa199bd994919d2bb8ec7d6f7e9f24930740dc",
            RemoteSigner.canonical("post", "/v1/action", 1_700_000_000_000, nonce, body),
        )
    }

    /** Computed independently with `openssl dgst -sha256 -mac HMAC` and Python's hmac module. */
    @Test
    fun signatureMatchesTheFixedVector() {
        assertEquals("PI4O5q6x-pwCSpqtifcwo-3o8yaRdPW8i2hdhCKcCDE",
                     RemoteSigner.sign(key, "POST", "/v1/action", 1_700_000_000_000, nonce, body))
    }

    @Test
    fun emptyBodyHashesEmptyInput() {
        assertTrue(RemoteSigner.canonical("GET", "/v1/state", 1, nonce, ByteArray(0))
                       .endsWith("\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))
    }

    @Test
    fun headersCarryTimeNonceAndSignature() {
        val headers = RemoteSigner.headers(key, "POST", "/v1/action", body, time = 1_700_000_000_000, nonce = nonce)
        assertEquals("1700000000000", headers[RemoteSigner.HEADER_TIME])
        assertEquals(nonce, headers[RemoteSigner.HEADER_NONCE])
        assertEquals("PI4O5q6x-pwCSpqtifcwo-3o8yaRdPW8i2hdhCKcCDE", headers[RemoteSigner.HEADER_SIGNATURE])
    }

    @Test
    fun noncesAreFreshLowercaseHex() {
        val first = RemoteSigner.newNonce()
        assertTrue(first.matches(Regex("[0-9a-f]{32}")))
        assertNotEquals(first, RemoteSigner.newNonce())
    }
}

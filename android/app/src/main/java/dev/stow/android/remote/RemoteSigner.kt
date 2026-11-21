package dev.stow.android.remote

import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Signs alarm-remote requests the way the Mac checks them: HMAC-SHA256 with the pairing key over
 * method, path, time, nonce and the body's hash. Plain JVM APIs only, so it runs in unit tests.
 */
object RemoteSigner {
    const val HEADER_TIME = "X-Stow-Time"
    const val HEADER_NONCE = "X-Stow-Nonce"
    const val HEADER_SIGNATURE = "X-Stow-Signature"

    private val random = SecureRandom()

    fun canonical(method: String, path: String, time: Long, nonce: String, body: ByteArray): String =
        listOf(method.uppercase(), path, time.toString(), nonce, hex(sha256(body))).joinToString("\n")

    fun sign(key: ByteArray, method: String, path: String, time: Long, nonce: String, body: ByteArray): String {
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(key, "HmacSHA256")) }
        val digest = mac.doFinal(canonical(method, path, time, nonce, body).toByteArray(Charsets.UTF_8))
        return Base64.getUrlEncoder().withoutPadding().encodeToString(digest)
    }

    /** The three auth headers for one request; a fresh nonce each time, since the Mac refuses repeats. */
    fun headers(key: ByteArray, method: String, path: String, body: ByteArray,
                time: Long = System.currentTimeMillis(), nonce: String = newNonce()): Map<String, String> = mapOf(
        HEADER_TIME to time.toString(),
        HEADER_NONCE to nonce,
        HEADER_SIGNATURE to sign(key, method, path, time, nonce, body),
    )

    fun newNonce(): String = hex(ByteArray(16).also(random::nextBytes))

    private fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)

    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }
}

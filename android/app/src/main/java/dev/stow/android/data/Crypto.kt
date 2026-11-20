package dev.stow.android.data

import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Opens what the Mac sealed with CryptoKit's ChaChaPoly: 12-byte nonce, ciphertext, 16-byte tag. */
object Crypto {
    fun open(sealed: ByteArray, key: ByteArray): ByteArray {
        require(sealed.size > 28) { "Sealed data is too short" }
        val cipher = Cipher.getInstance("ChaCha20-Poly1305")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "ChaCha20"), IvParameterSpec(sealed.copyOfRange(0, 12)))
        return cipher.doFinal(sealed, 12, sealed.size - 12)
    }
}

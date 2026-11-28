package dev.stow.android.account

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import java.io.File
import java.io.IOException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Where the YouTube cookies.txt is kept; the only copy on the phone. */
interface SecretStore {
    fun load(): String?
    /** null deletes it. Throws when the store refuses, so a sign-in that wasn't kept isn't reported as one. */
    fun save(text: String?)
    /** Whether anything of a sign-in is kept, readable or not (a reinstall's or restore's leftovers count). */
    fun hasItem(): Boolean = load() != null
}

/** For tests: nothing leaves memory. `failSaves` makes saving throw, as a store that refuses would. */
class InMemorySecretStore(private var text: String? = null) : SecretStore {
    var failSaves = false
    /** A leftover the store can't read (a key without its file, or the reverse). */
    var unreadableLeftover = false
    override fun load(): String? = text
    override fun save(text: String?) {
        if (failSaves) throw IOException("the store refused")
        this.text = text
        unreadableLeftover = false
    }
    override fun hasItem(): Boolean = text != null || unreadableLeftover
}

/**
 * The YouTube cookies, encrypted with an AES-256-GCM key in the AndroidKeyStore (never leaves the
 * phone's secure hardware, no user authentication so background checks can use it):
 * `files/youtube/cookies.bin` is the 12-byte IV followed by the ciphertext and tag. A file that
 * no longer decrypts (key lost, backup restored on another phone) is deleted: signed out.
 */
class CookieVault(context: Context) : SecretStore {
    private val dir = File(context.filesDir, "youtube")
    private val file = File(dir, "cookies.bin")

    @Synchronized
    override fun load(): String? {
        if (!file.exists()) return null
        return try {
            val bytes = file.readBytes()
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(create = false) ?: error("no key"), GCMParameterSpec(128, bytes, 0, IV_BYTES))
            String(cipher.doFinal(bytes, IV_BYTES, bytes.size - IV_BYTES), Charsets.UTF_8)
        } catch (e: Exception) {
            Log.w("Stow", "The saved YouTube sign-in can't be read; signing out", e)
            file.delete()
            null
        }
    }

    /** The file or the AndroidKeyStore key, even when they no longer go together. */
    @Synchronized
    override fun hasItem(): Boolean = file.exists() || runCatching { keyStore().containsAlias(ALIAS) }.getOrDefault(false)

    @Synchronized
    override fun save(text: String?) {
        if (text == null) {
            File(dir, "cookies.bin.tmp").delete()
            if (file.exists() && !file.delete()) throw IOException("Couldn't delete the saved YouTube sign-in")
            keyStore().deleteEntry(ALIAS)
            return
        }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key(create = true))
        val sealed = cipher.iv + cipher.doFinal(text.toByteArray(Charsets.UTF_8))
        dir.mkdirs()
        val temp = File(dir, "cookies.bin.tmp")
        temp.writeBytes(sealed)
        if (!temp.renameTo(file)) {
            file.delete()
            if (!temp.renameTo(file)) {
                temp.delete()
                throw IOException("Couldn't save the YouTube sign-in")
            }
        }
    }

    private fun keyStore() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun key(create: Boolean): SecretKey? {
        (keyStore().getKey(ALIAS, null) as? SecretKey)?.let { return it }
        if (!create) return null
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setRandomizedEncryptionRequired(true)
            .setUserAuthenticationRequired(false)
            .build())
        return generator.generateKey()
    }

    companion object {
        const val ALIAS = "stow.youtube.cookies"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val IV_BYTES = 12
    }
}

package app.direct.messaging.platform

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.ProviderException
import app.direct.core.store.SecretStore
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Secrets are encrypted with a non-exportable AES-256-GCM key in the Android Keystore
 * (StrongBox when the device has it) and the ciphertext is kept in noBackupFilesDir.
 * The raw identity seed and store key never touch SharedPreferences or plain files.
 */
class KeystoreSecretStore(context: Context) : SecretStore {
    private val dir = File(context.noBackupFilesDir, "secrets").apply { mkdirs() }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance(PROVIDER).apply { load(null) }
        (keyStore.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return try {
            generate(strongBox = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
        } catch (_: ProviderException) {
            // StrongBoxUnavailableException (API 28+) is a ProviderException.
            generate(strongBox = false)
        }
    }

    private fun generate(strongBox: Boolean): SecretKey {
        val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setRandomizedEncryptionRequired(true)
            .apply { if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) setIsStrongBoxBacked(true) }
            .build()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER).run {
            init(spec)
            generateKey()
        }
    }

    private fun file(name: String): File {
        require(name.matches(Regex("^[a-z0-9.]+$"))) { "Secret names are lowercase letters, digits, and dots." }
        return File(dir, "$name.bin")
    }

    @Synchronized
    override fun read(name: String): ByteArray? {
        val target = file(name)
        if (!target.exists()) return null
        val sealed = target.readBytes()
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, sealed, 0, IV_BYTES))
        cipher.updateAAD(name.toByteArray())
        return cipher.doFinal(sealed, IV_BYTES, sealed.size - IV_BYTES)
    }

    @Synchronized
    override fun write(name: String, value: ByteArray) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        cipher.updateAAD(name.toByteArray())
        val sealed = cipher.iv + cipher.doFinal(value)
        val target = file(name)
        val temp = File(dir, "$name.tmp")
        temp.writeBytes(sealed)
        Files.move(temp.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    }

    @Synchronized
    override fun delete(name: String) {
        file(name).delete()
    }

    private companion object {
        const val PROVIDER = "AndroidKeyStore"
        const val ALIAS = "direct.secrets.v1"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
    }
}

package app.direct.core.crypto

import app.direct.core.Encoding
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.bouncycastle.crypto.agreement.X25519Agreement
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters

class SealException(message: String) : Exception(message)

internal object AesGcm {
    fun encrypt(key: ByteArray, nonce: ByteArray, aad: ByteArray, plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(aad)
        return cipher.doFinal(plaintext)
    }

    fun decrypt(key: ByteArray, nonce: ByteArray, aad: ByteArray, ciphertext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(aad)
        return cipher.doFinal(ciphertext)
    }
}

/**
 * version(1) || ephemeral X25519 public(32) || nonce(12) || AES-256-GCM(ciphertext || tag).
 * key = HKDF-SHA256(X25519(ephemeral, recipient), salt = ephemeral public, info = "DIRECT-SEAL-v1").
 * This is a one-shot sealed box, not the Signal Double Ratchet.
 */
object Seal {
    private const val VERSION: Byte = 1
    private val INFO = Encoding.utf8("DIRECT-SEAL-v1")
    private val DB_AAD = Encoding.utf8("DIRECT-DB-v1")

    private fun shared(secret: ByteArray, publicKey: ByteArray): ByteArray {
        val agreement = X25519Agreement()
        agreement.init(X25519PrivateKeyParameters(secret, 0))
        val out = ByteArray(agreement.agreementSize)
        agreement.calculateAgreement(X25519PublicKeyParameters(publicKey, 0), out, 0)
        return out
    }

    fun seal(recipientAgreementPublic: ByteArray, plaintext: ByteArray, aad: ByteArray): ByteArray {
        val ephemeralSecret = Encoding.randomBytes(32)
        val ephemeralPublic = X25519PrivateKeyParameters(ephemeralSecret, 0).generatePublicKey().encoded
        val key = Hkdf.sha256(shared(ephemeralSecret, recipientAgreementPublic), ephemeralPublic, INFO, 32)
        val nonce = Encoding.randomBytes(12)
        val ciphertext = AesGcm.encrypt(key, nonce, aad, plaintext)
        ephemeralSecret.fill(0)
        key.fill(0)
        return byteArrayOf(VERSION) + ephemeralPublic + nonce + ciphertext
    }

    fun open(agreementSecret: ByteArray, payload: ByteArray, aad: ByteArray): ByteArray {
        if (payload.size < 1 + 32 + 12 + 16 || payload[0] != VERSION) throw SealException("Sealed payload is not a DIRECT envelope.")
        val ephemeralPublic = payload.copyOfRange(1, 33)
        val nonce = payload.copyOfRange(33, 45)
        return try {
            val key = Hkdf.sha256(shared(agreementSecret, ephemeralPublic), ephemeralPublic, INFO, 32)
            AesGcm.decrypt(key, nonce, aad, payload.copyOfRange(45, payload.size)).also { key.fill(0) }
        } catch (_: Exception) {
            throw SealException("Sealed payload failed authentication.")
        }
    }

    /** Same layout as packages/crypto sealDatabase: version || nonce || AES-256-GCM, aad "DIRECT-DB-v1". */
    fun sealAtRest(key: ByteArray, plaintext: ByteArray): ByteArray {
        if (key.size != 32) throw SealException("Storage key must be 32 bytes.")
        val nonce = Encoding.randomBytes(12)
        return byteArrayOf(VERSION) + nonce + AesGcm.encrypt(key, nonce, DB_AAD, plaintext)
    }

    fun openAtRest(key: ByteArray, payload: ByteArray): ByteArray {
        if (payload.size < 1 + 12 + 16 || payload[0] != VERSION) throw SealException("Encrypted store header is not recognized.")
        return try {
            AesGcm.decrypt(key, payload.copyOfRange(1, 13), DB_AAD, payload.copyOfRange(13, payload.size))
        } catch (_: Exception) {
            throw SealException("Storage key does not match this file.")
        }
    }
}

package app.direct.core.crypto

import app.direct.core.Encoding
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.HKDFBytesGenerator
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.params.HKDFParameters
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer

class IdentityException(message: String) : Exception(message)

val DIRECT_ID_PATTERN = Regex("^dir_[0-9A-HJKMNP-TV-Z]{16}$")

object DirectIds {
    fun fromSigningPublic(signingPublic: ByteArray): String =
        "dir_${Encoding.crockford(Encoding.sha256(signingPublic).copyOfRange(0, 10))}"

    fun did(directId: String): String = "did:direct:$directId"

    /** Accepts `dir_` in any case and returns the canonical form, or null when it is not a DIRECT ID. */
    fun normalize(input: String): String? {
        val trimmed = input.trim()
        if (trimmed.length != 20 || !trimmed.startsWith("dir_", ignoreCase = true)) return null
        val id = "dir_" + trimmed.substring(4).uppercase()
        return if (DIRECT_ID_PATTERN.matches(id)) id else null
    }
}

internal object Hkdf {
    fun sha256(ikm: ByteArray, salt: ByteArray?, info: ByteArray, length: Int): ByteArray {
        val generator = HKDFBytesGenerator(SHA256Digest())
        generator.init(HKDFParameters(ikm, salt, info))
        return ByteArray(length).also { generator.generateBytes(it, 0, length) }
    }
}

object Signatures {
    fun sign(signingSecret: ByteArray, message: ByteArray): ByteArray {
        val signer = Ed25519Signer()
        signer.init(true, Ed25519PrivateKeyParameters(signingSecret, 0))
        signer.update(message, 0, message.size)
        return signer.generateSignature()
    }

    fun verify(signingPublic: ByteArray, message: ByteArray, signature: ByteArray): Boolean = try {
        val verifier = Ed25519Signer()
        verifier.init(false, Ed25519PublicKeyParameters(signingPublic, 0))
        verifier.update(message, 0, message.size)
        verifier.verifySignature(signature)
    } catch (_: Exception) {
        false
    }
}

/**
 * The 32-byte seed is the Ed25519 signing secret. The X25519 agreement secret is
 * HKDF-SHA256(seed, info = "DIRECT-X25519-v1"). Same derivation as packages/crypto.
 */
class IdentityKeys private constructor(val seed: ByteArray) {
    val signingPublic: ByteArray = Ed25519PrivateKeyParameters(seed, 0).generatePublicKey().encoded
    val agreementSecret: ByteArray = Hkdf.sha256(seed, null, Encoding.utf8("DIRECT-X25519-v1"), 32)
    val agreementPublic: ByteArray = X25519PrivateKeyParameters(agreementSecret, 0).generatePublicKey().encoded
    val directId: String = DirectIds.fromSigningPublic(signingPublic)

    fun sign(message: ByteArray): ByteArray = Signatures.sign(seed, message)

    fun wipe() {
        seed.fill(0)
        agreementSecret.fill(0)
    }

    companion object {
        fun fromSeed(seed: ByteArray): IdentityKeys {
            if (seed.size != 32) throw IdentityException("Identity seed must be 32 bytes.")
            return IdentityKeys(seed.copyOf())
        }

        fun generate(): IdentityKeys = IdentityKeys(Encoding.randomBytes(32))
    }
}

data class PublicBundle(
    val name: String,
    val directId: String,
    val did: String,
    val deviceId: String,
    val signingKey: String,
    val agreementKey: String,
    val agreementSig: String,
    val fingerprint: String,
) {
    val signingPublic: ByteArray get() = Encoding.fromBase64Url(signingKey)
    val agreementPublic: ByteArray get() = Encoding.fromBase64Url(agreementKey)

    /** Compact JSON in the field order of packages/crypto encodeBundle, so the bootstrap's directId check matches. */
    fun encode(): String = JsonObject(
        linkedMapOf(
            "v" to JsonPrimitive(1),
            "name" to JsonPrimitive(name),
            "directId" to JsonPrimitive(directId),
            "did" to JsonPrimitive(did),
            "deviceId" to JsonPrimitive(deviceId),
            "signingKey" to JsonPrimitive(signingKey),
            "agreementKey" to JsonPrimitive(agreementKey),
            "agreementSig" to JsonPrimitive(agreementSig),
            "fingerprint" to JsonPrimitive(fingerprint),
        ),
    ).toString()
}

object Bundles {
    const val MAX_NAME_UTF16 = 32

    fun fingerprint(signingPublic: ByteArray, agreementPublic: ByteArray): String {
        val hex = Encoding.hex(Encoding.sha256(signingPublic, agreementPublic).copyOfRange(0, 16)).uppercase()
        return hex.chunked(4).joinToString(" ")
    }

    private fun agreementPayload(name: String, agreementPublic: ByteArray): ByteArray =
        Encoding.utf8(name) + byteArrayOf(0) + agreementPublic

    fun create(keys: IdentityKeys, displayName: String, deviceId: String): PublicBundle {
        val name = displayName.trim()
        if (name.length > MAX_NAME_UTF16) throw IdentityException("Display name is too long.")
        return PublicBundle(
            name = name,
            directId = keys.directId,
            did = DirectIds.did(keys.directId),
            deviceId = deviceId,
            signingKey = Encoding.base64Url(keys.signingPublic),
            agreementKey = Encoding.base64Url(keys.agreementPublic),
            agreementSig = Encoding.base64Url(keys.sign(agreementPayload(name, keys.agreementPublic))),
            fingerprint = fingerprint(keys.signingPublic, keys.agreementPublic),
        )
    }

    /** Verifies the DIRECT ID, DID, agreement signature, and fingerprint before returning the bundle. */
    fun parse(serialized: String): PublicBundle {
        val json = try {
            Json.parseToJsonElement(serialized.trim()) as? JsonObject
        } catch (_: Exception) {
            null
        } ?: throw IdentityException("Identity bundle is not valid JSON.")
        fun field(name: String): String? = (json[name] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
        val version = (json["v"] as? JsonPrimitive)?.intOrNull
        val name = field("name") ?: ""
        val directId = field("directId")
        val signingKey = field("signingKey")
        val agreementKey = field("agreementKey")
        val agreementSig = field("agreementSig")
        if (version != 1 || directId == null || signingKey == null || agreementKey == null || agreementSig == null) {
            throw IdentityException("Identity bundle is missing required fields.")
        }
        val signingPublic: ByteArray
        val agreementPublic: ByteArray
        val signature: ByteArray
        try {
            signingPublic = Encoding.fromBase64Url(signingKey)
            agreementPublic = Encoding.fromBase64Url(agreementKey)
            signature = Encoding.fromBase64Url(agreementSig)
        } catch (_: IllegalArgumentException) {
            throw IdentityException("Identity bundle keys are not base64url.")
        }
        if (signingPublic.size != 32 || agreementPublic.size != 32) throw IdentityException("Identity bundle keys have the wrong length.")
        val derived = DirectIds.fromSigningPublic(signingPublic)
        if (derived != directId || field("did") != DirectIds.did(derived)) {
            throw IdentityException("DIRECT ID does not match the signing key.")
        }
        if (!Signatures.verify(signingPublic, agreementPayload(name, agreementPublic), signature)) {
            throw IdentityException("Agreement key signature is not valid.")
        }
        val fingerprint = fingerprint(signingPublic, agreementPublic)
        if (field("fingerprint") != fingerprint) throw IdentityException("Fingerprint does not match the published keys.")
        if (name.length > MAX_NAME_UTF16) throw IdentityException("Display name is too long.")
        return PublicBundle(name, directId, DirectIds.did(directId), field("deviceId") ?: "", signingKey, agreementKey, agreementSig, fingerprint)
    }
}

package app.direct.core.protocol

import app.direct.core.Encoding
import app.direct.core.crypto.IdentityKeys
import app.direct.core.crypto.Seal
import app.direct.core.crypto.Signatures
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

class EnvelopeException(message: String) : Exception(message)

enum class EnvelopeType(val wire: String) {
    MESSAGE("message"),
    ACK("ack"),
    READ("read"),
    PROFILE("profile"),
    CALL("call"),
    GROUP("group"),
    FEED("feed");

    companion object {
        fun fromWire(value: String?): EnvelopeType? = entries.firstOrNull { it.wire == value }
    }
}

/**
 * Signed, sealed unit that moves between devices over the data channel.
 * Field order, canonical string, and AAD match packages/protocol/src/envelope.ts.
 */
data class Envelope(
    val id: String,
    val type: EnvelopeType,
    val from: String,
    val to: String,
    val deviceId: String,
    val createdAt: Long,
    val expiresAt: Long,
    val ciphertext: String,
    val signature: String,
) {
    val v: Int get() = 1

    fun canonical(): ByteArray = Encoding.utf8(listOf(v, id, type.wire, from, to, deviceId, createdAt, expiresAt, ciphertext).joinToString("|"))

    fun encode(): String = JsonObject(
        linkedMapOf(
            "v" to JsonPrimitive(v),
            "id" to JsonPrimitive(id),
            "type" to JsonPrimitive(type.wire),
            "from" to JsonPrimitive(from),
            "to" to JsonPrimitive(to),
            "deviceId" to JsonPrimitive(deviceId),
            "createdAt" to JsonPrimitive(createdAt),
            "expiresAt" to JsonPrimitive(expiresAt),
            "ciphertext" to JsonPrimitive(ciphertext),
            "signature" to JsonPrimitive(signature),
        ),
    ).toString()

    companion object {
        fun aad(id: String, type: EnvelopeType, from: String, to: String, createdAt: Long): ByteArray =
            Encoding.utf8("1|${type.wire}|$id|$from|$to|$createdAt")
    }
}

data class EnvelopeHeader(val id: String, val type: EnvelopeType, val from: String, val to: String)

object Envelopes {
    const val MAX_BYTES = 256 * 1024
    const val CLOCK_SKEW_MS = 60_000L

    fun seal(
        sender: IdentityKeys,
        deviceId: String,
        recipientId: String,
        recipientAgreementPublic: ByteArray,
        id: String,
        type: EnvelopeType,
        plaintext: ByteArray,
        createdAt: Long,
        ttlMs: Long,
    ): Envelope {
        val aad = Envelope.aad(id, type, sender.directId, recipientId, createdAt)
        val ciphertext = Encoding.base64Url(Seal.seal(recipientAgreementPublic, plaintext, aad))
        val unsigned = Envelope(id, type, sender.directId, recipientId, deviceId, createdAt, createdAt + ttlMs, ciphertext, "")
        return unsigned.copy(signature = Encoding.base64Url(sender.sign(unsigned.canonical())))
    }

    fun open(recipient: IdentityKeys, envelope: Envelope): ByteArray = Seal.open(
        recipient.agreementSecret,
        Encoding.fromBase64Url(envelope.ciphertext),
        Envelope.aad(envelope.id, envelope.type, envelope.from, envelope.to, envelope.createdAt),
    )

    private fun parse(bytes: ByteArray): JsonObject {
        if (bytes.size > MAX_BYTES) throw EnvelopeException("Envelope is too large.")
        return try {
            Json.parseToJsonElement(Encoding.text(bytes)) as? JsonObject
        } catch (_: Exception) {
            null
        } ?: throw EnvelopeException("Envelope is not valid JSON.")
    }

    private fun JsonObject.text(name: String): String? = (this[name] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    fun peek(bytes: ByteArray): EnvelopeHeader? = try {
        val json = parse(bytes)
        val type = EnvelopeType.fromWire(json.text("type"))
        val id = json.text("id")
        val from = json.text("from")
        val to = json.text("to")
        if (type == null || id == null || from == null || to == null) null else EnvelopeHeader(id, type, from, to)
    } catch (_: EnvelopeException) {
        null
    }

    /** Parses and verifies the sender signature and time window. Does not decrypt. */
    fun decode(bytes: ByteArray, senderSigningPublic: ByteArray, now: Long): Envelope {
        val json = parse(bytes)
        val version = (json["v"] as? JsonPrimitive)?.intOrNull
        val type = EnvelopeType.fromWire(json.text("type"))
        val id = json.text("id")
        val from = json.text("from")
        val to = json.text("to")
        val deviceId = json.text("deviceId")
        val createdAt = (json["createdAt"] as? JsonPrimitive)?.longOrNull
        val expiresAt = (json["expiresAt"] as? JsonPrimitive)?.longOrNull
        val ciphertext = json.text("ciphertext")
        val signature = json.text("signature")
        if (version != 1 || type == null || id.isNullOrEmpty() || from == null || to == null || deviceId == null ||
            createdAt == null || expiresAt == null || ciphertext == null || signature.isNullOrEmpty()
        ) {
            throw EnvelopeException("Envelope is malformed.")
        }
        if (createdAt > now + CLOCK_SKEW_MS) throw EnvelopeException("Envelope is too far in the future.")
        if (expiresAt + CLOCK_SKEW_MS < now) throw EnvelopeException("Envelope has expired.")
        val envelope = Envelope(id, type, from, to, deviceId, createdAt, expiresAt, ciphertext, signature)
        val signatureBytes = try {
            Encoding.fromBase64Url(signature)
        } catch (_: IllegalArgumentException) {
            throw EnvelopeException("Envelope signature is not valid.")
        }
        if (!Signatures.verify(senderSigningPublic, envelope.canonical(), signatureBytes)) {
            throw EnvelopeException("Envelope signature is not valid.")
        }
        return envelope
    }
}

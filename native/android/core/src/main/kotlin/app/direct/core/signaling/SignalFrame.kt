package app.direct.core.signaling

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull

/** Frames from contracts/signaling.json. Nothing here can carry message text. */
sealed interface SignalFrame {
    data class Hello(val from: String, val bundle: String, val nonce: String? = null, val proof: String? = null) : SignalFrame
    data class Challenge(val nonce: String) : SignalFrame
    data class Lookup(val requestId: String, val directId: String) : SignalFrame
    data class Watch(val ids: List<String>) : SignalFrame

    sealed interface Negotiation : SignalFrame {
        val to: String
        val from: String
    }
    data class Offer(override val to: String, override val from: String, val sdp: String) : Negotiation
    data class Answer(override val to: String, override val from: String, val sdp: String) : Negotiation
    data class Ice(
        override val to: String,
        override val from: String,
        val candidate: String,
        val sdpMid: String?,
        val sdpMLineIndex: Int?,
    ) : Negotiation

    data class LookupResult(val requestId: String, val directId: String, val present: Boolean, val bundle: String?) : SignalFrame
    data class Unreachable(val to: String) : SignalFrame
    data class Presence(val directId: String, val online: Boolean) : SignalFrame
}

object SignalCodec {
    const val MAX_SIGNAL_CHARS = 64 * 1024
    const val MAX_WATCH = 256

    private fun obj(vararg pairs: Pair<String, JsonElement>) = JsonObject(linkedMapOf(*pairs))
    private fun str(value: String?): JsonElement = if (value == null) JsonNull else JsonPrimitive(value)

    fun encode(frame: SignalFrame): String = when (frame) {
        is SignalFrame.Hello -> {
            val fields = linkedMapOf("kind" to str("hello"), "from" to str(frame.from), "bundle" to str(frame.bundle))
            if (frame.nonce != null && frame.proof != null) {
                fields["nonce"] = str(frame.nonce)
                fields["proof"] = str(frame.proof)
            }
            JsonObject(fields)
        }
        is SignalFrame.Challenge -> obj("kind" to str("challenge"), "nonce" to str(frame.nonce))
        is SignalFrame.Lookup -> obj("kind" to str("lookup"), "requestId" to str(frame.requestId), "directId" to str(frame.directId))
        is SignalFrame.Watch -> obj("kind" to str("watch"), "ids" to JsonArray(frame.ids.take(MAX_WATCH).map(::JsonPrimitive)))
        is SignalFrame.Offer -> obj(
            "kind" to str("offer"), "to" to str(frame.to), "from" to str(frame.from),
            "description" to obj("type" to str("offer"), "sdp" to str(frame.sdp)),
        )
        is SignalFrame.Answer -> obj(
            "kind" to str("answer"), "to" to str(frame.to), "from" to str(frame.from),
            "description" to obj("type" to str("answer"), "sdp" to str(frame.sdp)),
        )
        is SignalFrame.Ice -> obj(
            "kind" to str("ice"), "to" to str(frame.to), "from" to str(frame.from),
            "candidate" to obj(
                "candidate" to str(frame.candidate),
                "sdpMid" to str(frame.sdpMid),
                "sdpMLineIndex" to (frame.sdpMLineIndex?.let(::JsonPrimitive) ?: JsonNull),
            ),
        )
        is SignalFrame.LookupResult -> obj(
            "kind" to str("lookup"), "requestId" to str(frame.requestId), "directId" to str(frame.directId),
            "present" to JsonPrimitive(frame.present), "bundle" to str(frame.bundle),
        )
        is SignalFrame.Unreachable -> obj("kind" to str("unreachable"), "to" to str(frame.to))
        is SignalFrame.Presence -> obj("kind" to str("presence"), "directId" to str(frame.directId), "online" to JsonPrimitive(frame.online))
    }.toString()

    private fun JsonObject.text(name: String): String? = (this[name] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    /** Decodes a frame from either direction. Unknown or malformed frames return null. */
    fun decode(text: String): SignalFrame? {
        if (text.length > MAX_SIGNAL_CHARS + 8192) return null
        val json = try {
            Json.parseToJsonElement(text) as? JsonObject
        } catch (_: Exception) {
            null
        } ?: return null
        val to = json.text("to")
        val from = json.text("from")
        return when (json.text("kind")) {
            "hello" -> SignalFrame.Hello(from ?: return null, json.text("bundle") ?: return null, json.text("nonce"), json.text("proof"))
            "challenge" -> SignalFrame.Challenge(json.text("nonce") ?: return null)
            "lookup" -> {
                val requestId = json.text("requestId") ?: return null
                val directId = json.text("directId") ?: return null
                val present = (json["present"] as? JsonPrimitive)?.booleanOrNull
                if (present == null) SignalFrame.Lookup(requestId, directId)
                else SignalFrame.LookupResult(requestId, directId, present, json.text("bundle"))
            }
            "watch" -> SignalFrame.Watch((json["ids"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull } ?: return null)
            "offer", "answer" -> {
                val description = json["description"] as? JsonObject ?: return null
                val sdp = description.text("sdp") ?: return null
                if (to == null || from == null) return null
                if (json.text("kind") == "offer") SignalFrame.Offer(to, from, sdp) else SignalFrame.Answer(to, from, sdp)
            }
            "ice" -> {
                val candidate = json["candidate"] as? JsonObject ?: return null
                SignalFrame.Ice(
                    to ?: return null,
                    from ?: return null,
                    candidate.text("candidate") ?: return null,
                    candidate.text("sdpMid"),
                    (candidate["sdpMLineIndex"] as? JsonPrimitive)?.intOrNull,
                )
            }
            "unreachable" -> SignalFrame.Unreachable(to ?: return null)
            "presence" -> SignalFrame.Presence(
                json.text("directId") ?: return null,
                (json["online"] as? JsonPrimitive)?.booleanOrNull ?: return null,
            )
            else -> null
        }
    }
}

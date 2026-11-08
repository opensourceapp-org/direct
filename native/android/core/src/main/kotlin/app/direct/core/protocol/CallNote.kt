package app.direct.core.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull

/**
 * A live call signal sealed to one contact. It is not a chat message and it is not queued:
 * an invite that cannot be written now is dropped. The bootstrap never sees this JSON.
 */
object CallNotes {
    val OPS = setOf("invite", "accept", "reject", "busy", "hangup", "offer", "answer", "ice")

    data class Note(
        val op: String,
        val id: String,
        val kind: String? = null,
        val sdp: String? = null,
        val candidate: String? = null,
        val mid: String? = null,
        val line: Int? = null,
    )

    fun encode(note: Note): String = buildString {
        append("{\"v\":1,\"op\":").append(quote(note.op))
        append(",\"id\":").append(quote(note.id))
        note.kind?.let { append(",\"kind\":").append(quote(it)) }
        note.sdp?.let { append(",\"sdp\":").append(quote(it)) }
        note.candidate?.let { append(",\"candidate\":").append(quote(it)) }
        note.mid?.let { append(",\"mid\":").append(quote(it)) }
        note.line?.let { append(",\"line\":").append(it) }
        append('}')
    }

    fun parse(text: String): Note? {
        val json = try {
            Json.parseToJsonElement(text) as? JsonObject
        } catch (_: Exception) {
            null
        } ?: return null
        val version = (json["v"] as? JsonPrimitive)?.intOrNull ?: (json["v"] as? JsonPrimitive)?.content?.toIntOrNull()
        if (version != 1) return null
        val op = json.string("op") ?: return null
        val id = json.string("id") ?: return null
        if (op !in OPS || id.isBlank() || id.length > 80) return null
        val kind = json.string("kind")?.takeIf { it == "audio" || it == "video" }
        val sdp = json.string("sdp")?.takeIf { it.length in 1..100_000 }
        val candidate = json.string("candidate")?.takeIf { it.length in 1..8_000 }
        val mid = json.string("mid")?.takeIf { it.length in 1..32 }
        val line = (json["line"] as? JsonPrimitive)?.intOrNull?.takeIf { it in 0..64 }
        return when (op) {
            "invite" -> Note(op, id, kind = kind ?: "audio")
            "offer", "answer" -> if (sdp == null) null else Note(op, id, sdp = sdp)
            "ice" -> if (candidate == null) null else Note(op, id, candidate = candidate, mid = mid ?: "0", line = line ?: 0)
            else -> Note(op, id)
        }
    }

    private fun JsonObject.string(name: String): String? = (this[name] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    private fun quote(value: String): String = buildString {
        append('"')
        for (char in value) {
            when (char) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> if (char.code < 0x20) append("\\u%04x".format(char.code)) else append(char)
            }
        }
        append('"')
    }
}

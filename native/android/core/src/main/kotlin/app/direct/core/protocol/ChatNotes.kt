package app.direct.core.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull

/**
 * Edit, delete, and react travel as ordinary `message` envelopes whose plaintext starts with [PREFIX].
 * The original chat id is inside the JSON, so a new envelope cannot be mistaken for a new bubble.
 * The bootstrap never sees this.
 */
object ChatNotes {
    const val PREFIX = "DIRECT-CHAT/1\n"
    val OPS = setOf("edit", "delete", "react")
    val EMOJIS = listOf("❤️", "👍", "👎", "😂", "😮", "😢", "🙏", "🔥")

    data class Note(
        val op: String,
        val messageId: String,
        val body: String? = null,
        val groupId: String? = null,
    )

    fun parsePrefixed(text: String): Note? {
        if (!text.startsWith(PREFIX)) return null
        return parse(text.removePrefix(PREFIX))
    }

    fun encode(note: Note): String = PREFIX + buildString {
        append("{\"v\":1,\"op\":").append(quote(note.op))
        append(",\"id\":").append(quote(note.messageId))
        note.body?.let { append(",\"body\":").append(quote(it)) }
        note.groupId?.let { append(",\"groupId\":").append(quote(it)) }
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
        val messageId = json.string("id") ?: return null
        if (op !in OPS || messageId.length !in 4..80) return null
        val body = json.string("body")?.takeIf { it.length in 1..8_000 }
        val groupId = json.string("groupId")?.takeIf { GroupNotes.isGroupId(it) }
        return when (op) {
            "edit" -> if (body == null) null else Note(op, messageId, body, groupId)
            "delete" -> Note(op, messageId, groupId = groupId)
            "react" -> {
                val emoji = json.string("body")?.takeIf { it in EMOJIS } ?: return null
                Note(op, messageId, emoji, groupId)
            }
            else -> null
        }
    }

    private fun JsonObject.string(name: String): String? =
        (this[name] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

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

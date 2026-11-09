package app.direct.core.protocol

import app.direct.core.crypto.DirectIds
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull

/**
 * Group membership and group chat plaintext. Invites use envelope type `group`.
 * Chat text is a normal `message` whose plaintext starts with [PREFIX], so a 1:1
 * body is never mistaken for a group payload. Each member still receives their
 * own sealed copy; the bootstrap never sees this JSON.
 */
object GroupNotes {
    const val PREFIX = "DIRECT-GROUP/1\n"
    const val MAX_MEMBERS = 16
    val OPS = setOf("invite", "text", "leave")
    private val GROUP_ID = Regex("^grp_[0-9a-f]{32}$")

    data class Note(
        val op: String,
        val groupId: String,
        val name: String? = null,
        val members: List<String> = emptyList(),
        val mid: String? = null,
        val body: String? = null,
    )

    fun isGroupId(value: String): Boolean = GROUP_ID.matches(value)

    fun parsePrefixed(text: String): Note? {
        if (!text.startsWith(PREFIX)) return null
        return parse(text.removePrefix(PREFIX))
    }

    fun encodeText(groupId: String, mid: String, body: String): String =
        PREFIX + encode(Note("text", groupId, mid = mid, body = body))

    fun encode(note: Note): String = buildString {
        append("{\"v\":1,\"op\":").append(quote(note.op))
        append(",\"groupId\":").append(quote(note.groupId))
        note.name?.let { append(",\"name\":").append(quote(it)) }
        if (note.members.isNotEmpty()) {
            append(",\"members\":[")
            note.members.forEachIndexed { index, id ->
                if (index > 0) append(',')
                append(quote(id))
            }
            append(']')
        }
        note.mid?.let { append(",\"mid\":").append(quote(it)) }
        note.body?.let { append(",\"body\":").append(quote(it)) }
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
        val groupId = json.string("groupId") ?: return null
        if (op !in OPS || !isGroupId(groupId)) return null
        val name = json.string("name")?.trim()?.takeIf { it.length in 1..32 }
        val members = (json["members"] as? JsonArray)
            ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull?.let(DirectIds::normalize) }
            ?.distinct()
            .orEmpty()
        if (members.size > MAX_MEMBERS) return null
        val mid = json.string("mid")?.takeIf { it.length in 4..80 }
        val body = json.string("body")?.takeIf { it.length in 1..8_000 }
        return when (op) {
            "invite" -> {
                if (name == null || members.size < 2) null
                else Note(op, groupId, name = name, members = members)
            }
            "text" -> if (mid == null || body == null) null else Note(op, groupId, mid = mid, body = body)
            else -> Note(op, groupId, name = name, members = members)
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

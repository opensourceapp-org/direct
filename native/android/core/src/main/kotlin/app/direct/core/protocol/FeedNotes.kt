package app.direct.core.protocol

import app.direct.core.Encoding
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

/**
 * A story or profile post sealed to accepted contacts. The bootstrap never sees the bytes.
 * Puts are chunked like chat media. Deletes, likes, and comments are short JSON notes.
 */
object FeedNotes {
    const val PART_PREFIX = "DIRECT-FEED/1\n"
    const val JOB_PREFIX = "DIRECT-FEED-JOB/1\n"
    const val STORY = "story"
    const val POST = "post"
    const val STORY_TTL_MS = 24L * 60 * 60 * 1000
    const val MAX_STORIES = 20
    const val MAX_POSTS = 60
    const val MAX_CAPTION = 200
    const val MAX_COMMENT = 500
    const val MAX_COMMENTS = 100
    val CHANNELS = setOf(STORY, POST)
    val KINDS = setOf("image", "video", "gif")
    val SOCIAL_OPS = setOf("like", "comment")

    data class Part(
        val id: String,
        val channel: String,
        val kind: String,
        val mime: String,
        val name: String,
        val caption: String,
        val createdAt: Long,
        val expiresAt: Long?,
        val part: Int,
        val parts: Int,
    )

    data class Delete(val channel: String, val id: String)

    data class Social(
        val op: String,
        val id: String,
        val body: String? = null,
        val commentId: String? = null,
        val createdAt: Long? = null,
    )

    data class Job(
        val id: String,
        val channel: String,
        val kind: String,
        val mime: String,
        val name: String,
        val caption: String,
        val createdAt: Long,
        val expiresAt: Long?,
        val parts: Int,
        val nextPart: Int,
        val fileName: String,
    )

    fun encodePart(part: Part, chunk: ByteArray): ByteArray {
        val fields = mutableListOf(
            "v" to "1",
            "op" to "put",
            "id" to part.id,
            "channel" to part.channel,
            "kind" to part.kind,
            "mime" to part.mime,
            "name" to part.name,
            "caption" to part.caption,
            "createdAt" to part.createdAt.toString(),
            "part" to part.part.toString(),
            "parts" to part.parts.toString(),
        )
        val numbers = mutableSetOf("v", "createdAt", "part", "parts")
        if (part.expiresAt != null) {
            fields += "expiresAt" to part.expiresAt.toString()
            numbers += "expiresAt"
        }
        return Encoding.utf8(PART_PREFIX + json(*fields.toTypedArray(), numbers = numbers) + "\n") + chunk
    }

    fun decodePart(plaintext: ByteArray): Pair<Part, ByteArray>? {
        val prefix = Encoding.utf8(PART_PREFIX)
        if (plaintext.size < prefix.size || !plaintext.copyOfRange(0, prefix.size).contentEquals(prefix)) return null
        val rest = plaintext.copyOfRange(prefix.size, plaintext.size)
        val newline = rest.indexOf(0x0A)
        if (newline < 0) return null
        val json = Json.parseToJsonElement(Encoding.text(rest.copyOfRange(0, newline))) as? JsonObject ?: return null
        if (json.text("op") != "put") return null
        val part = Part(
            id = json.text("id") ?: return null,
            channel = json.text("channel") ?: return null,
            kind = json.text("kind") ?: return null,
            mime = json.text("mime") ?: return null,
            name = json.text("name") ?: "",
            caption = json.text("caption") ?: "",
            createdAt = json.long("createdAt") ?: return null,
            expiresAt = json.long("expiresAt"),
            part = json.int("part") ?: return null,
            parts = json.int("parts") ?: return null,
        )
        if (part.channel !in CHANNELS || part.kind !in KINDS) return null
        if (part.part < 0 || part.parts <= 0 || part.part >= part.parts) return null
        if (part.id.length !in 4..80) return null
        return part to rest.copyOfRange(newline + 1, rest.size)
    }

    fun encodeDelete(channel: String, id: String): String =
        PART_PREFIX + json("v" to "1", "op" to "delete", "channel" to channel, "id" to id, numbers = setOf("v"))

    fun decodeDelete(plaintext: String): Delete? {
        if (!plaintext.startsWith(PART_PREFIX)) return null
        val rest = plaintext.removePrefix(PART_PREFIX).trim()
        val json = try {
            Json.parseToJsonElement(rest) as? JsonObject
        } catch (_: Exception) {
            null
        } ?: return null
        if (json.text("op") != "delete") return null
        val channel = json.text("channel") ?: return null
        val id = json.text("id") ?: return null
        if (channel !in CHANNELS || id.length !in 4..80) return null
        return Delete(channel, id)
    }

    fun encodeLike(id: String): String =
        PART_PREFIX + json("v" to "1", "op" to "like", "id" to id, numbers = setOf("v"))

    fun encodeComment(id: String, commentId: String, body: String, createdAt: Long): String =
        PART_PREFIX + json(
            "v" to "1",
            "op" to "comment",
            "id" to id,
            "commentId" to commentId,
            "body" to body,
            "createdAt" to createdAt.toString(),
            numbers = setOf("v", "createdAt"),
        )

    fun decodeSocial(plaintext: String): Social? {
        if (!plaintext.startsWith(PART_PREFIX)) return null
        val rest = plaintext.removePrefix(PART_PREFIX).trim()
        val json = try {
            Json.parseToJsonElement(rest) as? JsonObject
        } catch (_: Exception) {
            null
        } ?: return null
        val op = json.text("op") ?: return null
        if (op !in SOCIAL_OPS) return null
        val id = json.text("id") ?: return null
        if (id.length !in 4..80) return null
        return when (op) {
            "like" -> Social(op, id)
            "comment" -> {
                val body = json.text("body")?.trim()?.take(MAX_COMMENT) ?: return null
                if (body.isEmpty()) return null
                val commentId = json.text("commentId") ?: return null
                if (commentId.length !in 4..80) return null
                Social(op, id, body, commentId, json.long("createdAt"))
            }
            else -> null
        }
    }

    fun encodeJob(job: Job): String {
        val fields = mutableListOf(
            "id" to job.id,
            "channel" to job.channel,
            "kind" to job.kind,
            "mime" to job.mime,
            "name" to job.name,
            "caption" to job.caption,
            "createdAt" to job.createdAt.toString(),
            "parts" to job.parts.toString(),
            "nextPart" to job.nextPart.toString(),
            "fileName" to job.fileName,
        )
        val numbers = mutableSetOf("createdAt", "parts", "nextPart")
        if (job.expiresAt != null) {
            fields += "expiresAt" to job.expiresAt.toString()
            numbers += "expiresAt"
        }
        return JOB_PREFIX + json(*fields.toTypedArray(), numbers = numbers)
    }

    fun parseJob(payload: String): Job? {
        if (!payload.startsWith(JOB_PREFIX)) return null
        val json = Json.parseToJsonElement(payload.removePrefix(JOB_PREFIX)) as? JsonObject ?: return null
        return Job(
            id = json.text("id") ?: return null,
            channel = json.text("channel") ?: return null,
            kind = json.text("kind") ?: return null,
            mime = json.text("mime") ?: return null,
            name = json.text("name") ?: "",
            caption = json.text("caption") ?: "",
            createdAt = json.long("createdAt") ?: return null,
            expiresAt = json.long("expiresAt"),
            parts = json.int("parts") ?: return null,
            nextPart = json.int("nextPart") ?: return null,
            fileName = json.text("fileName") ?: return null,
        )
    }

    fun isJob(payload: String): Boolean = payload.startsWith(JOB_PREFIX)

    private fun json(vararg pairs: Pair<String, String>, numbers: Set<String>): String = buildString {
        append('{')
        pairs.forEachIndexed { index, (key, value) ->
            if (index > 0) append(',')
            append('"').append(key).append("\":")
            if (key in numbers) append(value) else append(quote(value))
        }
        append('}')
    }

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

    private fun JsonObject.text(name: String): String? = (this[name] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    private fun JsonObject.int(name: String): Int? {
        val value = this[name] as? JsonPrimitive ?: return null
        return value.intOrNull ?: value.contentOrNull?.toIntOrNull()
    }

    private fun JsonObject.long(name: String): Long? {
        val value = this[name] ?: return null
        if (value is JsonNull) return null
        val primitive = value as? JsonPrimitive ?: return null
        return primitive.longOrNull ?: primitive.contentOrNull?.toLongOrNull()
    }
}

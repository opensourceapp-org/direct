package app.direct.core.protocol

import app.direct.core.Encoding
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull

/**
 * A photo, video, GIF, sticker, or voice note sealed inside a normal envelope.
 * The plaintext is `DIRECT-MEDIA/1`, one JSON header line, then the raw chunk.
 * Chunks travel on the data channel. The bootstrap never sees them.
 */
object MediaNotes {
    const val PART_PREFIX = "DIRECT-MEDIA/1\n"
    const val JOB_PREFIX = "DIRECT-MEDIA-JOB/1\n"
    const val DEFAULT_CHUNK = 96 * 1024
    const val MAX_BYTES = 6 * 1024 * 1024
    const val MAX_AVATAR_BYTES = 48_000
    val KINDS = setOf("image", "video", "gif", "sticker", "audio")

    data class Part(
        val mediaId: String,
        val kind: String,
        val mime: String,
        val name: String,
        val part: Int,
        val parts: Int,
        val caption: String,
        val groupId: String? = null,
        val feedId: String? = null,
        val feedOwnerId: String? = null,
    )

    data class Job(
        val kind: String,
        val mime: String,
        val name: String,
        val caption: String,
        val parts: Int,
        val nextPart: Int,
        val fileName: String,
        val feedId: String? = null,
        val feedOwnerId: String? = null,
    )

    fun label(kind: String?): String? = when (kind) {
        "image" -> "Photo"
        "video" -> "Video"
        "gif" -> "GIF"
        "sticker" -> "Sticker"
        "audio" -> "Voice message"
        else -> null
    }

    fun split(bytes: ByteArray, chunkBytes: Int): List<ByteArray> {
        val size = chunkBytes.coerceAtLeast(1)
        if (bytes.isEmpty()) return listOf(ByteArray(0))
        val out = ArrayList<ByteArray>((bytes.size / size) + 1)
        var index = 0
        while (index < bytes.size) {
            val end = minOf(index + size, bytes.size)
            out += bytes.copyOfRange(index, end)
            index = end
        }
        return out
    }

    fun encodePart(part: Part, chunk: ByteArray): ByteArray {
        val fields = mutableListOf(
            "mediaId" to part.mediaId,
            "kind" to part.kind,
            "mime" to part.mime,
            "name" to part.name,
            "part" to part.part.toString(),
            "parts" to part.parts.toString(),
            "caption" to part.caption,
        )
        part.groupId?.let { fields += "groupId" to it }
        part.feedId?.let { fields += "feedId" to it }
        part.feedOwnerId?.let { fields += "feedOwnerId" to it }
        val header = json(*fields.toTypedArray(), numbers = setOf("part", "parts"))
        return Encoding.utf8(PART_PREFIX + header + "\n") + chunk
    }

    fun decodePart(plaintext: ByteArray): Pair<Part, ByteArray>? {
        val prefix = Encoding.utf8(PART_PREFIX)
        if (plaintext.size < prefix.size || !plaintext.copyOfRange(0, prefix.size).contentEquals(prefix)) return null
        val rest = plaintext.copyOfRange(prefix.size, plaintext.size)
        val newline = rest.indexOf(0x0A)
        if (newline < 0) return null
        val json = Json.parseToJsonElement(Encoding.text(rest.copyOfRange(0, newline))) as? JsonObject ?: return null
        val part = Part(
            mediaId = json.text("mediaId") ?: return null,
            kind = json.text("kind") ?: return null,
            mime = json.text("mime") ?: return null,
            name = json.text("name") ?: "",
            part = json.int("part") ?: return null,
            parts = json.int("parts") ?: return null,
            caption = json.text("caption") ?: "",
            groupId = json.text("groupId")?.takeIf { GroupNotes.isGroupId(it) },
            feedId = json.text("feedId").validFeedId(),
            feedOwnerId = json.text("feedOwnerId").validFeedId(),
        )
        if (part.part < 0 || part.parts <= 0 || part.part >= part.parts) return null
        if (part.kind !in KINDS) return null
        return part to rest.copyOfRange(newline + 1, rest.size)
    }

    fun encodeJob(job: Job): String {
        val fields = mutableListOf(
            "kind" to job.kind,
            "mime" to job.mime,
            "name" to job.name,
            "caption" to job.caption,
            "parts" to job.parts.toString(),
            "nextPart" to job.nextPart.toString(),
            "fileName" to job.fileName,
        )
        job.feedId?.let { fields += "feedId" to it }
        job.feedOwnerId?.let { fields += "feedOwnerId" to it }
        return JOB_PREFIX + json(*fields.toTypedArray(), numbers = setOf("parts", "nextPart"))
    }

    fun parseJob(payload: String): Job? {
        if (!payload.startsWith(JOB_PREFIX)) return null
        val json = Json.parseToJsonElement(payload.removePrefix(JOB_PREFIX)) as? JsonObject ?: return null
        return Job(
            kind = json.text("kind") ?: return null,
            mime = json.text("mime") ?: return null,
            name = json.text("name") ?: "",
            caption = json.text("caption") ?: "",
            parts = json.int("parts") ?: return null,
            nextPart = json.int("nextPart") ?: return null,
            fileName = json.text("fileName") ?: return null,
            feedId = json.text("feedId").validFeedId(),
            feedOwnerId = json.text("feedOwnerId").validFeedId(),
        )
    }

    fun String?.validFeedId(): String? = this?.takeIf { it.length in 4..80 }

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

    private fun JsonObject.int(name: String): Int? = (this[name] as? JsonPrimitive)?.intOrNull
}

/** What a QR code carries: the signed bundle, the server address, plus an optional status and photo. The share sheet sends a picture of that code, not this JSON as the message. */
object ProfileCards {
    data class Card(val bundle: String, val status: String, val avatarJpeg: ByteArray?, val bootstrap: String = "")

    fun encode(bundle: String, status: String, avatarJpeg: ByteArray?, bootstrap: String = ""): String {
        val avatar = avatarJpeg?.takeIf { it.size in 1..MediaNotes.MAX_AVATAR_BYTES }?.let { Encoding.base64Url(it) }
        val server = bootstrap.trim()
        return buildString {
            append("{\"v\":1,\"bundle\":").append(quote(bundle))
            append(",\"status\":").append(quote(status.trim()))
            if (avatar != null) append(",\"avatar\":").append(quote(avatar))
            if (server.isNotEmpty()) append(",\"bootstrap\":").append(quote(server))
            append('}')
        }
    }

    /** A card, or a bare identity bundle. */
    fun parse(text: String): Card {
        val trimmed = text.trim()
        val json = try {
            Json.parseToJsonElement(trimmed) as? JsonObject
        } catch (_: Exception) {
            null
        }
        val bundle = json?.let { (it["bundle"] as? JsonPrimitive)?.takeIf { primitive -> primitive.isString }?.contentOrNull }
        if (bundle != null) {
            val status = (json["status"] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull.orEmpty()
            val avatar = (json["avatar"] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull?.let { Encoding.fromBase64Url(it) }
            val bootstrap = (json["bootstrap"] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull.orEmpty()
            return Card(bundle, status, avatar, bootstrap)
        }
        return Card(trimmed, "", null)
    }

    private fun quote(value: String): String = quoteJson(value)
}

/**
 * The display photo and status sealed to a contact. The bootstrap never sees this.
 * `avatar` null clears the photo. A missing `avatar` leaves the saved photo alone.
 */
object ProfileNotes {
    data class Note(val status: String, val avatarJpeg: ByteArray?, val clearAvatar: Boolean)

    fun encode(status: String, avatarJpeg: ByteArray?): String {
        val avatar = avatarJpeg?.takeIf { it.size in 3..MediaNotes.MAX_AVATAR_BYTES && it[0] == 0xFF.toByte() && it[1] == 0xD8.toByte() }
            ?.let(Encoding::base64Url)
        return buildString {
            append("{\"v\":1,\"status\":").append(quoteJson(status.trim().take(80)))
            append(",\"avatar\":")
            if (avatar == null) append("null") else append(quoteJson(avatar))
            append('}')
        }
    }

    fun parse(text: String): Note? {
        val json = try {
            Json.parseToJsonElement(text) as? JsonObject
        } catch (_: Exception) {
            null
        } ?: return null
        val version = (json["v"] as? JsonPrimitive)?.intOrNull ?: (json["v"] as? JsonPrimitive)?.contentOrNull?.toIntOrNull()
        if (version != 1 || json["status"] !is JsonPrimitive) return null
        val status = (json["status"] as JsonPrimitive).contentOrNull ?: return null
        return when (val avatar = json["avatar"]) {
            null -> Note(status, null, false)
            is JsonNull -> Note(status, null, true)
            is JsonPrimitive -> {
                if (!avatar.isString) return null
                val bytes = avatar.content.let { runCatching { Encoding.fromBase64Url(it) }.getOrNull() }
                val jpeg = bytes?.takeIf { it.size in 3..MediaNotes.MAX_AVATAR_BYTES && it[0] == 0xFF.toByte() && it[1] == 0xD8.toByte() }
                if (jpeg == null) Note(status, null, false) else Note(status, jpeg, false)
            }
            else -> null
        }
    }
}

private fun quoteJson(value: String): String = buildString {
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

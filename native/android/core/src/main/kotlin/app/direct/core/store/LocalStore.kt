package app.direct.core.store

import app.direct.core.Encoding
import app.direct.core.crypto.Seal
import app.direct.core.delivery.MessageState
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class Profile(
    val name: String,
    val deviceId: String,
    val directId: String,
    /** A short line the user wrote, shared only when they show their QR or use Share. */
    val status: String = "",
    /** Small JPEG, base64url. Null until they choose a photo. */
    val avatarJpegBase64: String? = null,
)

@Serializable
data class Settings(
    val bootstrapUrl: String? = null,
    val bootstrapDefaultVersion: Int = 0,
    /** Off by default. When true, other phones on this server may see this contact as a suggestion. */
    val discoverable: Boolean = false,
)

@Serializable
data class ContactRecord(
    val directId: String,
    val name: String,
    val bundle: String,
    val fingerprint: String,
    val verified: Boolean = false,
    /** False while this contact is only a message request. */
    val accepted: Boolean = true,
    val blocked: Boolean = false,
    val createdAt: Long,
    /** Status text copied from their QR. It is not signed. */
    val about: String = "",
    val avatarJpegBase64: String? = null,
)

@Serializable
data class GroupRecord(
    val id: String,
    val name: String,
    val members: List<String>,
    val createdBy: String,
    val createdAt: Long,
)

@Serializable
enum class Direction { OUTGOING, INCOMING }

@Serializable
data class MessageReaction(val emoji: String, val fromId: String)

fun List<MessageReaction>.toggling(fromId: String, emoji: String): List<MessageReaction> {
    val current = find { it.fromId == fromId }?.emoji
    return if (current == emoji) filter { it.fromId != fromId }
    else filter { it.fromId != fromId } + MessageReaction(emoji, fromId)
}

@Serializable
data class MessageRecord(
    val id: String,
    val peerId: String,
    val direction: Direction,
    val body: String,
    val createdAt: Long,
    /** Outgoing only. */
    val state: MessageState? = null,
    /** Incoming only: a read receipt was queued. */
    val read: Boolean = false,
    val lastError: String? = null,
    val updatedAt: Long = createdAt,
    /** image, video, gif, sticker, or audio. Null for a text message. */
    val mediaKind: String? = null,
    val mediaMime: String? = null,
    val mediaName: String? = null,
    /** File name inside the media directory. The bytes are not in this snapshot. */
    val mediaFile: String? = null,
    /** Incoming group messages: the member who wrote it. */
    val senderId: String? = null,
    val edited: Boolean = false,
    val deleted: Boolean = false,
    val forwarded: Boolean = false,
    val reactions: List<MessageReaction> = emptyList(),
    /** When set, this bubble is a shared feed post. Tap opens that post. */
    val feedPostId: String? = null,
    val feedOwnerId: String? = null,
)

@Serializable
data class FeedLike(val fromId: String, val emoji: String = "❤️")

@Serializable
data class FeedComment(val id: String, val fromId: String, val body: String, val createdAt: Long)

fun List<FeedLike>.togglingReaction(fromId: String, emoji: String = "❤️"): List<FeedLike> {
    val current = firstOrNull { it.fromId == fromId }
    return if (current?.emoji == emoji) filter { it.fromId != fromId }
    else filter { it.fromId != fromId } + FeedLike(fromId, emoji)
}

@Serializable
data class FeedItem(
    val id: String,
    val ownerId: String,
    val channel: String,
    val kind: String,
    val mime: String,
    val name: String,
    val caption: String = "",
    val createdAt: Long,
    val expiresAt: Long? = null,
    val mediaFile: String,
    val seen: Boolean = false,
    val likes: List<FeedLike> = emptyList(),
    val comments: List<FeedComment> = emptyList(),
    val tags: List<String> = emptyList(),
)

@Serializable
enum class QueueKind { MESSAGE, RECEIPT }

@Serializable
data class QueueItem(
    /** Envelope id. For 1:1 MESSAGE items this is also the message id. */
    val id: String,
    val peerId: String,
    val kind: QueueKind,
    /** Signed, sealed envelope JSON. Never plaintext. */
    val payload: String,
    val attempts: Int = 0,
    val nextAttemptAt: Long,
    val expiresAt: Long,
    val sentAt: Long? = null,
    val lastError: String? = null,
    /** Group fan-out: the local message this envelope belongs to. */
    val messageId: String? = null,
) {
    fun logicalId(): String = messageId ?: id
}

@Serializable
data class Snapshot(
    val version: Int = 1,
    val profile: Profile? = null,
    val settings: Settings = Settings(),
    val contacts: List<ContactRecord> = emptyList(),
    val messages: List<MessageRecord> = emptyList(),
    val queue: List<QueueItem> = emptyList(),
    val groups: List<GroupRecord> = emptyList(),
    val feed: List<FeedItem> = emptyList(),
    /** Post ids this phone has saved, newest first. Not shared with contacts. */
    val savedPosts: List<String> = emptyList(),
)

/**
 * The whole local database: profile, contacts, messages, and the outgoing queue.
 * It is written as one AES-256-GCM sealed file (same layout as packages/crypto sealDatabase)
 * with an atomic replace, so a crash leaves either the previous or the next complete state.
 * The key comes from [IdentityVault.storageKey], which lives in the platform secret store.
 * Not thread-safe: DirectNode confines all access to one coroutine dispatcher.
 */
class LocalStore private constructor(private val file: File?, private val key: ByteArray?, snapshot: Snapshot) {
    var profile: Profile? = snapshot.profile
    var settings: Settings = snapshot.settings
    private val contacts = LinkedHashMap(snapshot.contacts.associateBy { it.directId })
    private val messages = LinkedHashMap(snapshot.messages.associateBy { it.id })
    private val queue = LinkedHashMap(snapshot.queue.associateBy { it.id })
    private val groups = LinkedHashMap(snapshot.groups.associateBy { it.id })
    private val feedItems = LinkedHashMap(snapshot.feed.associateBy { it.id })
    private val savedPosts = snapshot.savedPosts.toMutableList()

    fun contact(directId: String): ContactRecord? = contacts[directId]
    fun contacts(): List<ContactRecord> = contacts.values.toList()
    fun putContact(contact: ContactRecord) {
        contacts[contact.directId] = contact
    }
    fun removeContact(directId: String) {
        contacts.remove(directId)
    }

    fun message(id: String): MessageRecord? = messages[id]
    fun messages(): List<MessageRecord> = messages.values.toList()
    fun messagesWith(peerId: String): List<MessageRecord> = messages.values.filter { it.peerId == peerId }.sortedBy { it.createdAt }
    fun putMessage(message: MessageRecord) {
        messages[message.id] = message
    }
    fun removeMessage(id: String) {
        messages.remove(id)
    }

    fun queued(id: String): QueueItem? = queue[id]
    fun queue(): List<QueueItem> = queue.values.toList()
    fun putQueued(item: QueueItem) {
        queue[item.id] = item
    }
    fun removeQueued(id: String) {
        queue.remove(id)
    }
    fun removeQueuedForMessage(messageId: String) {
        queue.keys.filter { id -> queue[id]?.logicalId() == messageId }.forEach { queue.remove(it) }
    }

    fun group(id: String): GroupRecord? = groups[id]
    fun groups(): List<GroupRecord> = groups.values.toList()
    fun putGroup(group: GroupRecord) {
        groups[group.id] = group
    }
    fun removeGroup(id: String) {
        groups.remove(id)
    }

    fun feed(id: String): FeedItem? = feedItems[id]
    fun feed(): List<FeedItem> = feedItems.values.toList()
    fun putFeed(item: FeedItem) {
        feedItems[item.id] = item
    }
    fun removeFeed(id: String) {
        feedItems.remove(id)
        savedPosts.remove(id)
    }
    fun savedPosts(): List<String> = savedPosts.toList()
    /** Returns true when the post is saved after the toggle. */
    fun toggleSaved(id: String): Boolean {
        val existing = savedPosts.indexOf(id)
        if (existing >= 0) {
            savedPosts.removeAt(existing)
            return false
        }
        savedPosts.add(0, id)
        while (savedPosts.size > MAX_SAVED) savedPosts.removeAt(savedPosts.lastIndex)
        return true
    }
    fun pruneFeed(now: Long): List<FeedItem> {
        val expired = feedItems.values.filter { item -> item.expiresAt != null && item.expiresAt <= now }
        expired.forEach { removeFeed(it.id) }
        return expired
    }

    fun snapshot(): Snapshot = Snapshot(
        1, profile, settings,
        contacts.values.toList(), messages.values.toList(), queue.values.toList(), groups.values.toList(),
        feedItems.values.toList(), savedPosts.toList(),
    )

    fun save() {
        val target = file ?: return
        val sealed = Seal.sealAtRest(key!!, Encoding.utf8(json.encodeToString(Snapshot.serializer(), snapshot())))
        target.parentFile?.mkdirs()
        val temp = File(target.parentFile, "${target.name}.tmp")
        temp.writeBytes(sealed)
        Files.move(temp.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    }

    companion object {
        private const val MAX_SAVED = 200
        private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

        /** Opens or creates the sealed file. A wrong key throws instead of wiping data. */
        fun open(file: File, key: ByteArray): LocalStore {
            require(key.size == 32) { "Storage key must be 32 bytes." }
            if (!file.exists()) return LocalStore(file, key.copyOf(), Snapshot())
            val plain = Seal.openAtRest(key, file.readBytes())
            return LocalStore(file, key.copyOf(), json.decodeFromString(Snapshot.serializer(), Encoding.text(plain)))
        }

        fun inMemory(): LocalStore = LocalStore(null, null, Snapshot())
    }
}

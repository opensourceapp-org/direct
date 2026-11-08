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
data class Settings(val bootstrapUrl: String? = null)

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
enum class Direction { OUTGOING, INCOMING }

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
)

@Serializable
enum class QueueKind { MESSAGE, RECEIPT }

@Serializable
data class QueueItem(
    /** Envelope id. For MESSAGE items this is also the message id. */
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
)

@Serializable
data class Snapshot(
    val version: Int = 1,
    val profile: Profile? = null,
    val settings: Settings = Settings(),
    val contacts: List<ContactRecord> = emptyList(),
    val messages: List<MessageRecord> = emptyList(),
    val queue: List<QueueItem> = emptyList(),
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

    fun queued(id: String): QueueItem? = queue[id]
    fun queue(): List<QueueItem> = queue.values.toList()
    fun putQueued(item: QueueItem) {
        queue[item.id] = item
    }
    fun removeQueued(id: String) {
        queue.remove(id)
    }

    fun snapshot(): Snapshot = Snapshot(1, profile, settings, contacts.values.toList(), messages.values.toList(), queue.values.toList())

    fun save() {
        val target = file ?: return
        val sealed = Seal.sealAtRest(key!!, Encoding.utf8(json.encodeToString(Snapshot.serializer(), snapshot())))
        target.parentFile?.mkdirs()
        val temp = File(target.parentFile, "${target.name}.tmp")
        temp.writeBytes(sealed)
        Files.move(temp.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    }

    companion object {
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

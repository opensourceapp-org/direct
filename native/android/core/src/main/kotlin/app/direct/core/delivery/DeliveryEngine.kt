package app.direct.core.delivery

import app.direct.core.Encoding
import app.direct.core.crypto.Bundles
import app.direct.core.crypto.IdentityKeys
import app.direct.core.crypto.PublicBundle
import app.direct.core.protocol.EnvelopeType
import app.direct.core.protocol.Envelopes
import app.direct.core.protocol.GroupNotes
import app.direct.core.protocol.MediaNotes
import app.direct.core.protocol.ProfileNotes
import app.direct.core.store.ContactRecord
import app.direct.core.store.GroupRecord
import app.direct.core.store.Direction
import app.direct.core.store.LocalStore
import app.direct.core.store.MessageRecord
import app.direct.core.store.QueueItem
import app.direct.core.store.QueueKind
import java.io.File

/** Moves envelope bytes to a peer. Implemented by the WebRTC data channel on each platform. */
interface PeerLinks {
    fun isConnected(peerId: String): Boolean

    /** Opens a direct channel if needed. False when the peer cannot be reached now. */
    suspend fun connect(peerId: String): Boolean

    /** Writes to an open channel. True means the bytes were handed to the channel, not that they arrived. */
    suspend fun send(peerId: String, payload: ByteArray): Boolean
}

class DeliveryRejected(message: String) : Exception(message)

enum class ReceiveOutcome { STORED, DUPLICATE, RECEIPT, IGNORED }

/**
 * Outgoing envelopes are sealed and persisted before any network attempt, and stay in the
 * queue until a signed receipt arrives or they expire. Writing to a channel is SENT, not delivered.
 * All calls must come from one coroutine dispatcher (DirectNode guarantees this).
 */
class DeliveryEngine(
    private val store: LocalStore,
    private val identity: () -> Pair<IdentityKeys, String>?,
    private val links: PeerLinks,
    private val clock: () -> Long,
    private val random: () -> Double = Math::random,
    val ttlMs: Long = DEFAULT_TTL_MS,
    val receiptTimeoutMs: Long = RECEIPT_TIMEOUT_MS,
    private val mediaDirectory: File? = null,
    private val mediaChunkBytes: Int = MediaNotes.DEFAULT_CHUNK,
) {
    private var flushing = false
    private var rerun = false
    private val bundles = HashMap<String, PublicBundle>()

    /** Plaintext of a call signal, invoked on the node dispatcher before [receive] returns. */
    var onCall: ((String) -> Unit)? = null

    /** A new incoming chat message, photo, or group invite the UI can turn into a notification. */
    var onInbound: ((MessageRecord) -> Unit)? = null

    fun queueText(peerId: String, text: String): MessageRecord {
        val (keys, deviceId) = identity() ?: throw DeliveryRejected("Create an identity before sending.")
        val body = text.trim()
        if (body.isEmpty()) throw DeliveryRejected("Message is empty.")
        if (body.length > MAX_BODY) throw DeliveryRejected("Message is too long.")
        val contact = store.contact(peerId) ?: throw DeliveryRejected("That contact is not on this device.")
        if (contact.blocked) throw DeliveryRejected("This contact is blocked.")
        val now = clock()
        val id = Encoding.newId("msg")
        val envelope = Envelopes.seal(keys, deviceId, peerId, bundleFor(contact).agreementPublic, id, EnvelopeType.MESSAGE, Encoding.utf8(body), now, ttlMs)
        val message = MessageRecord(id, peerId, Direction.OUTGOING, body, now, MessageState.QUEUED)
        store.putMessage(message)
        store.putQueued(QueueItem(id, peerId, QueueKind.MESSAGE, envelope.encode(), 0, now, envelope.expiresAt))
        store.save()
        return message
    }

    /** Seals one copy of [body] to each group member. The thread shows a single local message. */
    fun queueGroupText(group: GroupRecord, selfId: String, body: String): MessageRecord {
        val (keys, deviceId) = identity() ?: throw DeliveryRejected("Create an identity before sending.")
        val text = body.trim()
        if (text.isEmpty()) throw DeliveryRejected("Message is empty.")
        if (text.length > MAX_BODY) throw DeliveryRejected("Message is too long.")
        val members = group.members.filter { it != selfId }
        if (members.isEmpty()) throw DeliveryRejected("A group needs someone else in it.")
        val now = clock()
        val id = Encoding.newId("msg")
        val plain = Encoding.utf8(GroupNotes.encodeText(group.id, id, text))
        val message = MessageRecord(id, group.id, Direction.OUTGOING, text, now, MessageState.QUEUED, senderId = selfId)
        store.putMessage(message)
        for (peerId in members) {
            val contact = store.contact(peerId) ?: continue
            if (contact.blocked) continue
            val envelopeId = Encoding.newId("msg")
            val envelope = Envelopes.seal(keys, deviceId, peerId, bundleFor(contact).agreementPublic, envelopeId, EnvelopeType.MESSAGE, plain, now, ttlMs)
            store.putQueued(QueueItem(envelopeId, peerId, QueueKind.MESSAGE, envelope.encode(), 0, now, envelope.expiresAt, messageId = id))
        }
        if (store.queue().none { it.logicalId() == id }) throw DeliveryRejected("No reachable members in this group.")
        store.save()
        return message
    }

    fun queueGroupInvite(group: GroupRecord, selfId: String) {
        val (keys, deviceId) = identity() ?: return
        val members = group.members.filter { it != selfId }
        val now = clock()
        val plain = Encoding.utf8(GroupNotes.encode(GroupNotes.Note("invite", group.id, name = group.name, members = group.members)))
        for (peerId in members) {
            val contact = store.contact(peerId) ?: continue
            if (contact.blocked || !contact.accepted) continue
            val envelope = Envelopes.seal(
                keys, deviceId, peerId, bundleFor(contact).agreementPublic,
                Encoding.newId("grp"), EnvelopeType.GROUP, plain, now, ttlMs,
            )
            store.putQueued(QueueItem(envelope.id, peerId, QueueKind.RECEIPT, envelope.encode(), 0, now, envelope.expiresAt))
        }
        if (members.isNotEmpty()) store.save()
    }

    /**
     * Seals [bytes] into chunked envelopes and queues them. The file stays on this device
     * so the bubble can show it, and so a restart can send whatever has not been written yet.
     */
    fun queueMedia(peerId: String, kind: String, mime: String, name: String, bytes: ByteArray, caption: String): MessageRecord {
        if (identity() == null) throw DeliveryRejected("Create an identity before sending.")
        if (kind !in MediaNotes.KINDS) throw DeliveryRejected("That attachment is not supported.")
        if (bytes.isEmpty()) throw DeliveryRejected("That file is empty.")
        if (bytes.size > MediaNotes.MAX_BYTES) throw DeliveryRejected("That file is over 6 MB. Choose a shorter one.")
        val directory = mediaDirectory ?: throw DeliveryRejected("Attachments need local storage.")
        val contact = store.contact(peerId) ?: throw DeliveryRejected("That contact is not on this device.")
        if (contact.blocked) throw DeliveryRejected("This contact is blocked.")
        val now = clock()
        val id = Encoding.newId("med")
        val fileName = "$id.bin"
        directory.mkdirs()
        File(directory, fileName).writeBytes(bytes)
        val parts = MediaNotes.split(bytes, mediaChunkBytes).size
        val cleanCaption = caption.trim()
        val job = MediaNotes.Job(kind, mime, name, cleanCaption, parts, 0, fileName)
        val message = MessageRecord(
            id, peerId, Direction.OUTGOING, cleanCaption, now, MessageState.QUEUED,
            mediaKind = kind, mediaMime = mime, mediaName = name, mediaFile = fileName,
        )
        store.putMessage(message)
        store.putQueued(QueueItem(id, peerId, QueueKind.MESSAGE, MediaNotes.encodeJob(job), 0, now, now + ttlMs))
        store.save()
        return message
    }

    /** Seals one copy of an attachment to each group member. The file is stored once on this phone. */
    fun queueGroupMedia(
        group: GroupRecord,
        selfId: String,
        kind: String,
        mime: String,
        name: String,
        bytes: ByteArray,
        caption: String,
    ): MessageRecord {
        if (identity() == null) throw DeliveryRejected("Create an identity before sending.")
        if (kind !in MediaNotes.KINDS) throw DeliveryRejected("That attachment is not supported.")
        if (bytes.isEmpty()) throw DeliveryRejected("That file is empty.")
        if (bytes.size > MediaNotes.MAX_BYTES) throw DeliveryRejected("That file is over 6 MB. Choose a shorter one.")
        val directory = mediaDirectory ?: throw DeliveryRejected("Attachments need local storage.")
        val members = group.members.filter { it != selfId }
        if (members.isEmpty()) throw DeliveryRejected("A group needs someone else in it.")
        val now = clock()
        val id = Encoding.newId("med")
        val fileName = "$id.bin"
        directory.mkdirs()
        File(directory, fileName).writeBytes(bytes)
        val parts = MediaNotes.split(bytes, mediaChunkBytes).size
        val cleanCaption = caption.trim()
        val job = MediaNotes.Job(kind, mime, name, cleanCaption, parts, 0, fileName)
        val message = MessageRecord(
            id, group.id, Direction.OUTGOING, cleanCaption, now, MessageState.QUEUED,
            mediaKind = kind, mediaMime = mime, mediaName = name, mediaFile = fileName, senderId = selfId,
        )
        store.putMessage(message)
        if (!enqueueGroupMedia(group, selfId, id, job, now)) throw DeliveryRejected("No reachable members in this group.")
        store.save()
        return message
    }

    /** Requeues a FAILED message with a fresh envelope under the same id. The recipient deduplicates by id. */
    fun retry(messageId: String): Boolean {
        val message = store.message(messageId) ?: return false
        val state = message.state ?: return false
        val next = DeliveryStateMachine.next(state, DeliveryEvent.RETRY) ?: return false
        val group = store.group(message.peerId)
        if (group != null) {
            val selfId = identity()?.first?.directId ?: return false
            val now = clock()
            store.putMessage(message.copy(state = next, lastError = null, updatedAt = now))
            val remaining = store.queue().filter { it.logicalId() == messageId && it.kind == QueueKind.MESSAGE }
            if (remaining.isNotEmpty()) {
                for (item in remaining) {
                    store.putQueued(item.copy(sentAt = null, nextAttemptAt = now, lastError = null, payload = rewind(item.payload)))
                }
                store.save()
                return true
            }
            val mediaFile = message.mediaFile
            if (mediaFile != null && message.mediaKind != null) {
                val directory = mediaDirectory ?: return false
                if (!File(directory, mediaFile).exists()) return false
                val parts = MediaNotes.split(File(directory, mediaFile).readBytes(), mediaChunkBytes).size
                val job = MediaNotes.Job(
                    message.mediaKind, message.mediaMime ?: "application/octet-stream", message.mediaName ?: "",
                    message.body, parts, 0, mediaFile,
                )
                if (!enqueueGroupMedia(group, selfId, message.id, job, now)) return false
                store.save()
                return true
            }
            val (keys, deviceId) = identity() ?: return false
            val plain = Encoding.utf8(GroupNotes.encodeText(group.id, message.id, message.body))
            var any = false
            for (peerId in group.members.filter { it != selfId }) {
                val contact = store.contact(peerId) ?: continue
                if (contact.blocked) continue
                val envelopeId = Encoding.newId("msg")
                val envelope = Envelopes.seal(keys, deviceId, peerId, bundleFor(contact).agreementPublic, envelopeId, EnvelopeType.MESSAGE, plain, now, ttlMs)
                store.putQueued(QueueItem(envelopeId, peerId, QueueKind.MESSAGE, envelope.encode(), 0, now, envelope.expiresAt, messageId = message.id))
                any = true
            }
            if (!any) return false
            store.save()
            return true
        }
        val (keys, deviceId) = identity() ?: return false
        val contact = store.contact(message.peerId) ?: return false
        if (contact.blocked) return false
        val now = clock()
        val mediaFile = message.mediaFile
        if (mediaFile != null && message.mediaKind != null) {
            val directory = mediaDirectory ?: return false
            if (!File(directory, mediaFile).exists()) return false
            val parts = MediaNotes.split(File(directory, mediaFile).readBytes(), mediaChunkBytes).size
            val job = MediaNotes.Job(message.mediaKind, message.mediaMime ?: "application/octet-stream", message.mediaName ?: "", message.body, parts, 0, mediaFile)
            store.putMessage(message.copy(state = next, lastError = null, updatedAt = now))
            store.putQueued(QueueItem(message.id, message.peerId, QueueKind.MESSAGE, MediaNotes.encodeJob(job), 0, now, now + ttlMs))
            store.save()
            return true
        }
        val envelope = Envelopes.seal(keys, deviceId, message.peerId, bundleFor(contact).agreementPublic, message.id, EnvelopeType.MESSAGE, Encoding.utf8(message.body), now, ttlMs)
        store.putMessage(message.copy(state = next, lastError = null, updatedAt = now))
        store.putQueued(QueueItem(message.id, message.peerId, QueueKind.MESSAGE, envelope.encode(), 0, now, envelope.expiresAt))
        store.save()
        return true
    }

    /** After a restart nothing is in flight. SENDING and SENT go back to QUEUED and retry now. */
    fun recover() {
        val now = clock()
        for (item in store.queue()) {
            if (item.kind == QueueKind.MESSAGE) transition(item.logicalId(), DeliveryEvent.RECOVERED, null)
            store.queued(item.id)?.let { queued ->
                store.putQueued(queued.copy(sentAt = null, nextAttemptAt = minOf(queued.nextAttemptAt, now), payload = rewind(queued.payload)))
            }
        }
        store.save()
    }

    /**
     * Seals the current photo and status for each accepted contact.
     * Queued like a receipt: it is not a chat message, and it leaves the queue once written.
     */
    fun shareProfile(peerId: String? = null) {
        val (keys, deviceId) = identity() ?: return
        val profile = store.profile ?: return
        val jpeg = profile.avatarJpegBase64?.let { runCatching { Encoding.fromBase64Url(it) }.getOrNull() }
        val plain = Encoding.utf8(ProfileNotes.encode(profile.status, jpeg))
        val now = clock()
        val targets = store.contacts().filter { it.accepted && !it.blocked && (peerId == null || it.directId == peerId) }
        for (contact in targets) {
            val envelope = Envelopes.seal(
                keys, deviceId, contact.directId, bundleFor(contact).agreementPublic,
                "profile_${contact.directId}", EnvelopeType.PROFILE, plain, now, ttlMs,
            )
            store.putQueued(QueueItem("profile_${contact.directId}", contact.directId, QueueKind.RECEIPT, envelope.encode(), 0, now, now + ttlMs))
        }
        if (targets.isNotEmpty()) store.save()
    }

    /** The peer just became reachable. Retry everything queued for it without waiting for backoff. */
    fun peerOnline(peerId: String) {
        val now = clock()
        var changed = false
        for (item in store.queue()) {
            if (item.peerId != peerId || item.sentAt != null || item.nextAttemptAt <= now) continue
            store.putQueued(item.copy(nextAttemptAt = now))
            changed = true
        }
        if (changed) store.save()
    }

    /** Recipient blocked: fail its outgoing messages and drop pending receipts. */
    fun rejectPeer(peerId: String) {
        for (item in store.queue().filter { it.peerId == peerId }) {
            if (item.kind == QueueKind.MESSAGE) {
                val others = store.queue().any { it.id != item.id && it.logicalId() == item.logicalId() && it.kind == QueueKind.MESSAGE && it.peerId != peerId }
                if (!others) transition(item.logicalId(), DeliveryEvent.REJECTED, "Blocked on this device.")
            }
            store.removeQueued(item.id)
        }
        store.save()
    }

    /** Earliest time the queue needs attention: a retry, a receipt timeout, or an expiry. */
    fun nextWakeAt(): Long? = store.queue().minOfOrNull { item ->
        minOf(item.expiresAt, item.sentAt?.let { it + receiptTimeoutMs } ?: item.nextAttemptAt)
    }

    fun pendingCount(): Int = store.queue().count { it.kind == QueueKind.MESSAGE }

    fun awaitingReceipt(): Boolean = store.queue().any { it.sentAt != null }

    suspend fun flush() {
        if (flushing) {
            rerun = true
            return
        }
        flushing = true
        try {
            do {
                rerun = false
                flushOnce()
            } while (rerun)
        } finally {
            flushing = false
        }
    }

    private suspend fun flushOnce() {
        if (identity() == null) return
        val now = clock()
        expireAndTimeout(now)
        val due = store.queue()
            .filter { it.sentAt == null && it.nextAttemptAt <= now }
            .sortedBy { it.nextAttemptAt }
        for ((peerId, items) in due.groupBy { it.peerId }) {
            val contact = store.contact(peerId)
            if (contact == null || contact.blocked) {
                rejectPeer(peerId)
                continue
            }
            for (item in items) {
                if (item.kind == QueueKind.MESSAGE && !MediaNotes.isJob(item.payload)) transition(item.logicalId(), DeliveryEvent.ATTEMPT, null)
                store.putQueued(item.copy(attempts = item.attempts + 1))
            }
            store.save()
            val connected = links.isConnected(peerId) || links.connect(peerId)
            for (item in items) {
                val current = store.queued(item.id) ?: continue
                if (!connected) {
                    unreachable(current, "Recipient unavailable")
                    continue
                }
                if (MediaNotes.isJob(current.payload)) {
                    sendMediaChunks(current)
                    continue
                }
                if (links.send(peerId, Encoding.utf8(current.payload))) {
                    val latest = store.queued(item.id) ?: continue
                    if (latest.kind == QueueKind.RECEIPT) {
                        store.removeQueued(latest.id)
                    } else {
                        transition(latest.logicalId(), DeliveryEvent.WRITTEN, null)
                        store.putQueued(latest.copy(sentAt = clock(), lastError = null))
                    }
                } else {
                    unreachable(current, "Channel closed before the write")
                }
            }
            store.save()
        }
    }

    private fun unreachable(item: QueueItem, reason: String) {
        val fanOut = item.messageId != null && item.messageId != item.id
        if (item.kind == QueueKind.MESSAGE && !fanOut) {
            if (transition(item.logicalId(), DeliveryEvent.UNREACHABLE, reason) == null && MediaNotes.isJob(item.payload)) {
                store.message(item.logicalId())?.let { store.putMessage(it.copy(lastError = reason, updatedAt = clock())) }
            }
        } else if (item.kind == QueueKind.MESSAGE) {
            store.message(item.logicalId())?.let { store.putMessage(it.copy(lastError = reason, updatedAt = clock())) }
        }
        store.queued(item.id)?.let {
            store.putQueued(it.copy(nextAttemptAt = clock() + Backoff.delayMs(it.attempts, random), lastError = reason))
        }
    }

    private fun expireAndTimeout(now: Long) {
        for (item in store.queue()) {
            if (item.expiresAt <= now) {
                if (item.kind == QueueKind.MESSAGE) {
                    val others = store.queue().any { it.id != item.id && it.logicalId() == item.logicalId() && it.kind == QueueKind.MESSAGE }
                    if (!others) transition(item.logicalId(), DeliveryEvent.EXPIRED, "Expired before the recipient confirmed it.")
                }
                store.removeQueued(item.id)
                continue
            }
            val sentAt = item.sentAt ?: continue
            if (sentAt + receiptTimeoutMs > now) continue
            val fanOut = item.messageId != null && item.messageId != item.id
            if (item.kind == QueueKind.MESSAGE && !fanOut) transition(item.logicalId(), DeliveryEvent.RECEIPT_TIMEOUT, "No receipt yet")
            store.queued(item.id)?.let {
                store.putQueued(it.copy(sentAt = null, payload = rewind(it.payload), nextAttemptAt = now + Backoff.delayMs(it.attempts, random), lastError = "No receipt yet"))
            }
        }
    }

    /** Applies a state-machine event. Leaving the awaiting states drops the queue entry. */
    private fun transition(messageId: String, event: DeliveryEvent, error: String?): MessageState? {
        val message = store.message(messageId) ?: return null
        val state = message.state ?: return null
        val next = DeliveryStateMachine.next(state, event) ?: return null
        val settled = next == MessageState.ACCEPTED || next == MessageState.ACKNOWLEDGED
        store.putMessage(message.copy(state = next, lastError = if (settled) null else error ?: message.lastError, updatedAt = clock()))
        if (!next.awaitingReceipt) store.removeQueuedForMessage(messageId)
        return next
    }

    /**
     * Verifies and stores one envelope from [peerId]. The caller must already have a contact
     * for the sender (an unknown sender is saved as a request before this is called).
     */
    fun receive(peerId: String, bytes: ByteArray): ReceiveOutcome {
        val (keys, _) = identity() ?: return ReceiveOutcome.IGNORED
        val header = Envelopes.peek(bytes) ?: return ReceiveOutcome.IGNORED
        if (header.to != keys.directId || header.from != peerId) return ReceiveOutcome.IGNORED
        val contact = store.contact(peerId) ?: return ReceiveOutcome.IGNORED
        if (contact.blocked) return ReceiveOutcome.IGNORED
        val bundle = bundleFor(contact)
        val envelope = try {
            Envelopes.decode(bytes, bundle.signingPublic, clock())
        } catch (_: Exception) {
            return ReceiveOutcome.IGNORED
        }
        val opened = try {
            Envelopes.open(keys, envelope)
        } catch (_: Exception) {
            return ReceiveOutcome.IGNORED
        }
        val mediaPart = MediaNotes.decodePart(opened)
        if (mediaPart != null) {
            if (envelope.type != EnvelopeType.MESSAGE) return ReceiveOutcome.IGNORED
            return ingestMedia(peerId, contact, mediaPart.first, mediaPart.second, envelope.createdAt)
        }
        val plaintext = Encoding.text(opened)
        if (envelope.type == EnvelopeType.CALL) {
            if (!contact.accepted) return ReceiveOutcome.IGNORED
            onCall?.invoke(plaintext)
            return ReceiveOutcome.RECEIPT
        }
        if (envelope.type == EnvelopeType.GROUP) {
            return ingestInvite(peerId, plaintext, envelope.createdAt)
        }
        if (envelope.type == EnvelopeType.PROFILE) {
            val note = ProfileNotes.parse(plaintext) ?: return ReceiveOutcome.IGNORED
            val jpeg = note.avatarJpeg
            val avatar = when {
                note.clearAvatar -> null
                jpeg != null -> Encoding.base64Url(jpeg)
                else -> contact.avatarJpegBase64
            }
            store.putContact(contact.copy(about = note.status.trim().take(80), avatarJpegBase64 = avatar))
            store.save()
            return ReceiveOutcome.STORED
        }
        if (envelope.type != EnvelopeType.MESSAGE) {
            val (kind, messageId) = plaintext.split(":", limit = 2).let { if (it.size == 2) it[0] to it[1] else return ReceiveOutcome.IGNORED }
            if (kind != envelope.type.wire) return ReceiveOutcome.IGNORED
            val message = store.message(messageId) ?: return ReceiveOutcome.IGNORED
            if (message.direction != Direction.OUTGOING) return ReceiveOutcome.IGNORED
            val inGroup = store.group(message.peerId)?.members?.contains(peerId) == true
            if (message.peerId != peerId && !inGroup) return ReceiveOutcome.IGNORED
            if (envelope.type == EnvelopeType.ACK) {
                store.queue().firstOrNull { it.logicalId() == messageId && it.peerId == peerId }?.let { store.removeQueued(it.id) }
                val remaining = store.queue().any { it.logicalId() == messageId && it.kind == QueueKind.MESSAGE }
                if (!remaining) transition(messageId, DeliveryEvent.DELIVERY_RECEIPT, null)
            } else {
                transition(messageId, DeliveryEvent.READ_RECEIPT, null)
            }
            store.save()
            return ReceiveOutcome.RECEIPT
        }
        val grouped = GroupNotes.parsePrefixed(plaintext)
        if (grouped != null) {
            return ingestGroupText(peerId, contact, grouped, envelope.createdAt)
        }
        if (store.message(envelope.id) != null) {
            queueReceipt(contact, EnvelopeType.ACK, envelope.id)
            store.save()
            return ReceiveOutcome.DUPLICATE
        }
        val stored = MessageRecord(envelope.id, peerId, Direction.INCOMING, plaintext, envelope.createdAt)
        store.putMessage(stored)
        queueReceipt(contact, EnvelopeType.ACK, envelope.id)
        store.save()
        onInbound?.invoke(stored)
        return ReceiveOutcome.STORED
    }

    /** Queues signed `read` receipts for unread incoming messages from [peerId]. */
    fun markRead(peerId: String): Int {
        val group = store.group(peerId)
        if (group != null) {
            val unread = store.messagesWith(peerId).filter { it.direction == Direction.INCOMING && !it.read }
            for (message in unread) {
                store.putMessage(message.copy(read = true, updatedAt = clock()))
                if (message.mediaKind == "call" || message.mediaKind == "group") continue
                val targetId = message.senderId ?: continue
                val target = store.contact(targetId) ?: continue
                if (target.blocked) continue
                queueReceipt(target, EnvelopeType.READ, message.id)
            }
            if (unread.isNotEmpty()) store.save()
            return unread.size
        }
        val contact = store.contact(peerId) ?: return 0
        if (contact.blocked || !contact.accepted) return 0
        val unread = store.messagesWith(peerId).filter { it.direction == Direction.INCOMING && !it.read }
        for (message in unread) {
            store.putMessage(message.copy(read = true, updatedAt = clock()))
            if (message.mediaKind == "call") continue
            val targetId = message.senderId ?: peerId
            val target = store.contact(targetId) ?: continue
            if (target.blocked) continue
            queueReceipt(target, EnvelopeType.READ, message.id)
        }
        if (unread.isNotEmpty()) store.save()
        return unread.size
    }

    /** A call signal is sealed and returned. The caller writes it now. It is not queued. */
    fun sealCall(peerId: String, plain: String): ByteArray? {
        val (keys, deviceId) = identity() ?: return null
        val contact = store.contact(peerId) ?: return null
        if (!contact.accepted || contact.blocked) return null
        val bundle = try {
            bundleFor(contact)
        } catch (_: Exception) {
            return null
        }
        val now = clock()
        val envelope = Envelopes.seal(
            keys, deviceId, peerId, bundle.agreementPublic,
            Encoding.newId("call"), EnvelopeType.CALL, Encoding.utf8(plain), now, ttlMs,
        )
        return Encoding.utf8(envelope.encode())
    }

    private fun queueReceipt(contact: ContactRecord, type: EnvelopeType, messageId: String) {
        val (keys, deviceId) = identity() ?: return
        val now = clock()
        val envelope = Envelopes.seal(
            keys, deviceId, contact.directId, bundleFor(contact).agreementPublic,
            Encoding.newId(type.wire), type, Encoding.utf8("${type.wire}:$messageId"), now, ttlMs,
        )
        store.putQueued(QueueItem(envelope.id, contact.directId, QueueKind.RECEIPT, envelope.encode(), 0, now, envelope.expiresAt))
    }

    private fun rewind(payload: String): String {
        val job = MediaNotes.parseJob(payload) ?: return payload
        return MediaNotes.encodeJob(job.copy(nextPart = 0))
    }

    private fun enqueueGroupMedia(group: GroupRecord, selfId: String, messageId: String, job: MediaNotes.Job, now: Long): Boolean {
        var any = false
        for (peerId in group.members.filter { it != selfId }) {
            val contact = store.contact(peerId) ?: continue
            if (contact.blocked) continue
            store.putQueued(
                QueueItem(
                    Encoding.newId("med"), peerId, QueueKind.MESSAGE, MediaNotes.encodeJob(job),
                    0, now, now + ttlMs, messageId = messageId,
                ),
            )
            any = true
        }
        return any
    }

    /** Writes every remaining chunk. The message stays queued until the last chunk is on the channel. */
    private suspend fun sendMediaChunks(item: QueueItem) {
        val initial = MediaNotes.parseJob(item.payload) ?: return
        val (keys, deviceId) = identity() ?: return
        val contact = store.contact(item.peerId) ?: return
        val logicalId = item.logicalId()
        val directory = mediaDirectory
        val file = directory?.let { File(it, initial.fileName) }
        if (file == null || !file.exists()) {
            store.removeQueued(item.id)
            val others = store.queue().any { it.logicalId() == logicalId && it.kind == QueueKind.MESSAGE }
            if (!others) transition(logicalId, DeliveryEvent.EXPIRED, "The attachment is no longer on this phone.")
            return
        }
        val groupId = store.message(logicalId)?.peerId?.takeIf { GroupNotes.isGroupId(it) }
        val parts = MediaNotes.split(file.readBytes(), mediaChunkBytes)
        var part = initial.nextPart.coerceIn(0, parts.size)
        var job = initial
        while (part < parts.size) {
            val plain = MediaNotes.encodePart(
                MediaNotes.Part(logicalId, job.kind, job.mime, job.name, part, parts.size, job.caption, groupId),
                parts[part],
            )
            val envelope = Envelopes.seal(
                keys, deviceId, item.peerId, bundleFor(contact).agreementPublic,
                "${item.id}.$part", EnvelopeType.MESSAGE, plain, clock(), ttlMs,
            )
            if (!links.send(item.peerId, Encoding.utf8(envelope.encode()))) {
                val latest = store.queued(item.id) ?: return
                store.putQueued(
                    latest.copy(
                        payload = MediaNotes.encodeJob(job.copy(nextPart = part)),
                        nextAttemptAt = clock() + Backoff.delayMs(latest.attempts, random),
                        lastError = "Channel closed before the write",
                    ),
                )
                store.message(logicalId)?.let { store.putMessage(it.copy(lastError = "Channel closed before the write", updatedAt = clock())) }
                return
            }
            part += 1
            job = job.copy(nextPart = part)
            store.queued(item.id)?.let { store.putQueued(it.copy(payload = MediaNotes.encodeJob(job), lastError = null)) }
        }
        transition(logicalId, DeliveryEvent.ATTEMPT, null)
        transition(logicalId, DeliveryEvent.WRITTEN, null)
        store.queued(item.id)?.let { store.putQueued(it.copy(sentAt = clock(), lastError = null, payload = MediaNotes.encodeJob(job))) }
    }

    private fun ingestMedia(peerId: String, contact: ContactRecord, header: MediaNotes.Part, chunk: ByteArray, createdAt: Long): ReceiveOutcome {
        val directory = mediaDirectory ?: return ReceiveOutcome.IGNORED
        val selfId = identity()?.first?.directId
        val groupId = header.groupId
        val group = groupId?.let { store.group(it) }
        if (groupId != null && group != null && (peerId !in group.members || selfId !in group.members)) {
            return ReceiveOutcome.IGNORED
        }
        val threadId = groupId ?: peerId
        val senderId = if (groupId != null) peerId else null
        val partsDir = File(directory, "parts/${header.mediaId}")
        partsDir.mkdirs()
        File(partsDir, header.part.toString()).writeBytes(chunk)
        val complete = (0 until header.parts).all { File(partsDir, it.toString()).exists() }
        val label = MediaNotes.label(header.kind) ?: "Attachment"
        if (!complete) {
            val have = (0 until header.parts).count { File(partsDir, it.toString()).exists() }
            val body = "Receiving $label ($have/${header.parts})"
            val existing = store.message(header.mediaId)
            store.putMessage(
                existing?.copy(body = body, updatedAt = clock())
                    ?: MessageRecord(
                        header.mediaId, threadId, Direction.INCOMING, body, createdAt,
                        mediaKind = header.kind, mediaMime = header.mime, mediaName = header.name, senderId = senderId,
                    ),
            )
            store.save()
            return ReceiveOutcome.STORED
        }
        val assembled = (0 until header.parts).fold(ByteArray(0)) { acc, index -> acc + File(partsDir, index.toString()).readBytes() }
        val fileName = "${header.mediaId}.bin"
        File(directory, fileName).writeBytes(assembled)
        partsDir.deleteRecursively()
        val already = store.message(header.mediaId)?.mediaFile != null
        val caption = header.caption.ifBlank { label }
        val stored = MessageRecord(
            header.mediaId, threadId, Direction.INCOMING, caption, createdAt,
            mediaKind = header.kind, mediaMime = header.mime, mediaName = header.name, mediaFile = fileName,
            senderId = senderId,
        )
        store.putMessage(stored)
        queueReceipt(contact, EnvelopeType.ACK, header.mediaId)
        store.save()
        if (!already) onInbound?.invoke(stored)
        return if (already) ReceiveOutcome.DUPLICATE else ReceiveOutcome.STORED
    }

    private fun ingestInvite(peerId: String, plaintext: String, createdAt: Long): ReceiveOutcome {
        val note = GroupNotes.parse(plaintext) ?: return ReceiveOutcome.IGNORED
        if (note.op != "invite") return ReceiveOutcome.IGNORED
        val selfId = identity()?.first?.directId ?: return ReceiveOutcome.IGNORED
        if (selfId !in note.members || peerId !in note.members) return ReceiveOutcome.IGNORED
        val name = note.name ?: return ReceiveOutcome.IGNORED
        val existing = store.group(note.groupId)
        val group = GroupRecord(
            id = note.groupId,
            name = name,
            members = note.members,
            createdBy = existing?.createdBy ?: peerId,
            createdAt = existing?.createdAt ?: createdAt,
        )
        store.putGroup(group)
        if (existing == null) {
            val stored = MessageRecord(
                Encoding.newId("sys"),
                group.id,
                Direction.INCOMING,
                "${store.contact(peerId)?.name ?: peerId} added you to ${group.name}",
                createdAt,
                mediaKind = "group",
                senderId = peerId,
            )
            store.putMessage(stored)
            onInbound?.invoke(stored)
        }
        store.save()
        return ReceiveOutcome.STORED
    }

    private fun ingestGroupText(
        peerId: String,
        contact: ContactRecord,
        note: GroupNotes.Note,
        createdAt: Long,
    ): ReceiveOutcome {
        if (note.op != "text") return ReceiveOutcome.IGNORED
        val mid = note.mid ?: return ReceiveOutcome.IGNORED
        val body = note.body ?: return ReceiveOutcome.IGNORED
        val group = store.group(note.groupId) ?: return ReceiveOutcome.IGNORED
        if (peerId !in group.members) return ReceiveOutcome.IGNORED
        if (store.message(mid) != null) {
            queueReceipt(contact, EnvelopeType.ACK, mid)
            store.save()
            return ReceiveOutcome.DUPLICATE
        }
        val stored = MessageRecord(mid, group.id, Direction.INCOMING, body, createdAt, senderId = peerId)
        store.putMessage(stored)
        queueReceipt(contact, EnvelopeType.ACK, mid)
        store.save()
        onInbound?.invoke(stored)
        return ReceiveOutcome.STORED
    }

    private fun bundleFor(contact: ContactRecord): PublicBundle =
        bundles[contact.bundle] ?: Bundles.parse(contact.bundle).also { bundles[contact.bundle] = it }

    companion object {
        const val DEFAULT_TTL_MS = 7L * 24 * 60 * 60 * 1000
        const val RECEIPT_TIMEOUT_MS = 20_000L
        const val MAX_BODY = 8_000
    }
}

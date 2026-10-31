package app.direct.core.delivery

import app.direct.core.Encoding
import app.direct.core.crypto.Bundles
import app.direct.core.crypto.IdentityKeys
import app.direct.core.crypto.PublicBundle
import app.direct.core.protocol.EnvelopeType
import app.direct.core.protocol.Envelopes
import app.direct.core.store.ContactRecord
import app.direct.core.store.Direction
import app.direct.core.store.LocalStore
import app.direct.core.store.MessageRecord
import app.direct.core.store.QueueItem
import app.direct.core.store.QueueKind

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
) {
    private var flushing = false
    private var rerun = false
    private val bundles = HashMap<String, PublicBundle>()

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

    /** Requeues a FAILED message with a fresh envelope under the same id. The recipient deduplicates by id. */
    fun retry(messageId: String): Boolean {
        val message = store.message(messageId) ?: return false
        val state = message.state ?: return false
        val next = DeliveryStateMachine.next(state, DeliveryEvent.RETRY) ?: return false
        val (keys, deviceId) = identity() ?: return false
        val contact = store.contact(message.peerId) ?: return false
        if (contact.blocked) return false
        val now = clock()
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
            if (item.kind == QueueKind.MESSAGE) transition(item.id, DeliveryEvent.RECOVERED, null)
            store.queued(item.id)?.let { store.putQueued(it.copy(sentAt = null, nextAttemptAt = minOf(it.nextAttemptAt, now))) }
        }
        store.save()
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
            if (item.kind == QueueKind.MESSAGE) transition(item.id, DeliveryEvent.REJECTED, "Blocked on this device.")
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
                if (item.kind == QueueKind.MESSAGE) transition(item.id, DeliveryEvent.ATTEMPT, null)
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
                if (links.send(peerId, Encoding.utf8(current.payload))) {
                    val latest = store.queued(item.id) ?: continue
                    if (latest.kind == QueueKind.RECEIPT) {
                        store.removeQueued(latest.id)
                    } else if (transition(latest.id, DeliveryEvent.WRITTEN, null) == MessageState.SENT) {
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
        if (item.kind == QueueKind.MESSAGE) transition(item.id, DeliveryEvent.UNREACHABLE, reason)
        store.queued(item.id)?.let {
            store.putQueued(it.copy(nextAttemptAt = clock() + Backoff.delayMs(it.attempts, random), lastError = reason))
        }
    }

    private fun expireAndTimeout(now: Long) {
        for (item in store.queue()) {
            if (item.expiresAt <= now) {
                if (item.kind == QueueKind.MESSAGE) transition(item.id, DeliveryEvent.EXPIRED, "Expired before the recipient confirmed it.")
                store.removeQueued(item.id)
                continue
            }
            val sentAt = item.sentAt ?: continue
            if (sentAt + receiptTimeoutMs > now) continue
            if (item.kind == QueueKind.MESSAGE) transition(item.id, DeliveryEvent.RECEIPT_TIMEOUT, "No receipt yet")
            store.queued(item.id)?.let {
                store.putQueued(it.copy(sentAt = null, nextAttemptAt = now + Backoff.delayMs(it.attempts, random), lastError = "No receipt yet"))
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
        if (!next.awaitingReceipt) store.removeQueued(messageId)
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
        val plaintext = try {
            Encoding.text(Envelopes.open(keys, envelope))
        } catch (_: Exception) {
            return ReceiveOutcome.IGNORED
        }
        if (envelope.type != EnvelopeType.MESSAGE) {
            val (kind, messageId) = plaintext.split(":", limit = 2).let { if (it.size == 2) it[0] to it[1] else return ReceiveOutcome.IGNORED }
            if (kind != envelope.type.wire) return ReceiveOutcome.IGNORED
            val message = store.message(messageId) ?: return ReceiveOutcome.IGNORED
            if (message.direction != Direction.OUTGOING || message.peerId != peerId) return ReceiveOutcome.IGNORED
            transition(messageId, if (envelope.type == EnvelopeType.ACK) DeliveryEvent.DELIVERY_RECEIPT else DeliveryEvent.READ_RECEIPT, null)
            store.save()
            return ReceiveOutcome.RECEIPT
        }
        if (store.message(envelope.id) != null) {
            queueReceipt(contact, EnvelopeType.ACK, envelope.id)
            store.save()
            return ReceiveOutcome.DUPLICATE
        }
        store.putMessage(MessageRecord(envelope.id, peerId, Direction.INCOMING, plaintext, envelope.createdAt))
        queueReceipt(contact, EnvelopeType.ACK, envelope.id)
        store.save()
        return ReceiveOutcome.STORED
    }

    /** Queues signed `read` receipts for unread incoming messages from [peerId]. */
    fun markRead(peerId: String): Int {
        val contact = store.contact(peerId) ?: return 0
        if (contact.blocked || !contact.accepted) return 0
        val unread = store.messagesWith(peerId).filter { it.direction == Direction.INCOMING && !it.read }
        for (message in unread) {
            store.putMessage(message.copy(read = true, updatedAt = clock()))
            queueReceipt(contact, EnvelopeType.READ, message.id)
        }
        if (unread.isNotEmpty()) store.save()
        return unread.size
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

    private fun bundleFor(contact: ContactRecord): PublicBundle =
        bundles[contact.bundle] ?: Bundles.parse(contact.bundle).also { bundles[contact.bundle] = it }

    companion object {
        const val DEFAULT_TTL_MS = 7L * 24 * 60 * 60 * 1000
        const val RECEIPT_TIMEOUT_MS = 20_000L
        const val MAX_BODY = 8_000
    }
}

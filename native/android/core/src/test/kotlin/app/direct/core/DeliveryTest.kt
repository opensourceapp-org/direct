package app.direct.core

import app.direct.core.crypto.Bundles
import app.direct.core.crypto.IdentityKeys
import app.direct.core.delivery.DeliveryEngine
import app.direct.core.delivery.DeliveryEvent
import app.direct.core.delivery.DeliveryEvent.ATTEMPT
import app.direct.core.delivery.DeliveryEvent.DELIVERY_RECEIPT
import app.direct.core.delivery.DeliveryEvent.EXPIRED
import app.direct.core.delivery.DeliveryEvent.READ_RECEIPT
import app.direct.core.delivery.DeliveryEvent.RECEIPT_TIMEOUT
import app.direct.core.delivery.DeliveryEvent.RECOVERED
import app.direct.core.delivery.DeliveryEvent.REJECTED
import app.direct.core.delivery.DeliveryEvent.RETRY
import app.direct.core.delivery.DeliveryEvent.UNREACHABLE
import app.direct.core.delivery.DeliveryEvent.WRITTEN
import app.direct.core.delivery.DeliveryStateMachine
import app.direct.core.delivery.MessageState
import app.direct.core.delivery.MessageState.ACCEPTED
import app.direct.core.delivery.MessageState.ACKNOWLEDGED
import app.direct.core.delivery.MessageState.FAILED
import app.direct.core.delivery.MessageState.QUEUED
import app.direct.core.delivery.MessageState.SENDING
import app.direct.core.delivery.MessageState.SENT
import app.direct.core.delivery.PeerLinks
import app.direct.core.delivery.ReceiveOutcome
import app.direct.core.protocol.ChatNotes
import app.direct.core.protocol.Envelopes
import app.direct.core.protocol.GroupNotes
import app.direct.core.store.ContactRecord
import app.direct.core.store.GroupRecord
import app.direct.core.store.LocalStore
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest

class StateMachineTest {
    private fun path(vararg events: DeliveryEvent): MessageState? =
        events.fold(QUEUED as MessageState?) { state, event -> state?.let { DeliveryStateMachine.next(it, event) } }

    @Test
    fun `happy path is queued sending sent accepted acknowledged`() {
        assertEquals(SENDING, path(ATTEMPT))
        assertEquals(SENT, path(ATTEMPT, WRITTEN))
        assertEquals(ACCEPTED, path(ATTEMPT, WRITTEN, DELIVERY_RECEIPT))
        assertEquals(ACKNOWLEDGED, path(ATTEMPT, WRITTEN, DELIVERY_RECEIPT, READ_RECEIPT))
    }

    @Test
    fun `offline and timeout go back to queued for retry`() {
        assertEquals(QUEUED, path(ATTEMPT, UNREACHABLE))
        assertEquals(QUEUED, path(ATTEMPT, WRITTEN, RECEIPT_TIMEOUT))
        assertEquals(SENT, path(ATTEMPT, UNREACHABLE, ATTEMPT, WRITTEN))
    }

    @Test
    fun `restart recovery requeues anything in flight`() {
        assertEquals(QUEUED, DeliveryStateMachine.next(SENDING, RECOVERED))
        assertEquals(QUEUED, DeliveryStateMachine.next(SENT, RECOVERED))
        assertNull(DeliveryStateMachine.next(QUEUED, RECOVERED))
        assertNull(DeliveryStateMachine.next(ACCEPTED, RECOVERED))
    }

    @Test
    fun `expiry and blocking fail only messages still awaiting a receipt`() {
        for (state in listOf(QUEUED, SENDING, SENT)) {
            assertEquals(FAILED, DeliveryStateMachine.next(state, EXPIRED))
            assertEquals(FAILED, DeliveryStateMachine.next(state, REJECTED))
        }
        assertNull(DeliveryStateMachine.next(ACCEPTED, EXPIRED))
        assertNull(DeliveryStateMachine.next(ACKNOWLEDGED, REJECTED))
        assertEquals(QUEUED, DeliveryStateMachine.next(FAILED, RETRY))
        assertNull(DeliveryStateMachine.next(QUEUED, RETRY))
    }

    @Test
    fun `late receipts still count and nothing leaves acknowledged`() {
        assertEquals(ACCEPTED, DeliveryStateMachine.next(QUEUED, DELIVERY_RECEIPT))
        assertEquals(ACCEPTED, DeliveryStateMachine.next(FAILED, DELIVERY_RECEIPT))
        assertEquals(ACKNOWLEDGED, DeliveryStateMachine.next(SENT, READ_RECEIPT))
        assertNull(DeliveryStateMachine.next(ACCEPTED, DELIVERY_RECEIPT))
        for (event in DeliveryEvent.entries) assertNull(DeliveryStateMachine.next(ACKNOWLEDGED, event))
        assertNull(DeliveryStateMachine.next(SENT, ATTEMPT))
        assertNull(DeliveryStateMachine.next(QUEUED, WRITTEN))
    }
}

class DeliveryEngineTest {
    private class Links : PeerLinks {
        var reachable = false
        val sent = mutableListOf<ByteArray>()
        var onSend: ((ByteArray) -> Unit)? = null
        override fun isConnected(peerId: String) = reachable
        override suspend fun connect(peerId: String) = reachable
        override suspend fun send(peerId: String, payload: ByteArray): Boolean {
            if (!reachable) return false
            sent += payload
            onSend?.invoke(payload)
            return true
        }
    }

    private class Device(name: String, val clock: () -> Long, links: PeerLinks) {
        val keys = IdentityKeys.generate()
        val deviceId = Encoding.newDeviceId()
        val bundle = Bundles.create(keys, name, deviceId)
        val store = LocalStore.inMemory()
        val engine = DeliveryEngine(store, { keys to deviceId }, links, clock, { 0.0 }, ttlMs = 60_000, receiptTimeoutMs = 5_000)

        fun know(other: Device, accepted: Boolean = true) = store.putContact(
            ContactRecord(other.keys.directId, other.bundle.name, other.bundle.encode(), other.bundle.fingerprint, accepted = accepted, createdAt = 0),
        )
    }

    @Test
    fun `offline recipient keeps the message queued with growing backoff`() = runTest {
        var now = 1_000L
        val links = Links()
        val ada = Device("Ada", { now }, links)
        val bo = Device("Bo", { now }, Links())
        ada.know(bo)
        val message = ada.engine.queueText(bo.keys.directId, "hello")
        assertEquals(QUEUED, ada.store.message(message.id)?.state)

        ada.engine.flush()
        val first = assertNotNull(ada.store.queued(message.id))
        assertEquals(QUEUED, ada.store.message(message.id)?.state)
        assertEquals(1, first.attempts)
        assertEquals(now + 1_000, first.nextAttemptAt)
        assertEquals("Recipient unavailable", first.lastError)

        now += 1_000
        ada.engine.flush()
        assertEquals(now + 2_000, ada.store.queued(message.id)?.nextAttemptAt)

        ada.engine.peerOnline(bo.keys.directId)
        assertEquals(now, ada.store.queued(message.id)?.nextAttemptAt)
    }

    @Test
    fun `written is sent, ack is accepted, read is acknowledged`() = runTest {
        var now = 1_000L
        val adaLinks = Links().apply { reachable = true }
        val boLinks = Links().apply { reachable = true }
        val ada = Device("Ada", { now }, adaLinks)
        val bo = Device("Bo", { now }, boLinks)
        ada.know(bo)
        bo.know(ada, accepted = false)
        val message = ada.engine.queueText(bo.keys.directId, "hello")
        ada.engine.flush()
        assertEquals(SENT, ada.store.message(message.id)?.state)

        assertEquals(ReceiveOutcome.STORED, bo.engine.receive(ada.keys.directId, adaLinks.sent.last()))
        assertEquals("hello", bo.store.message(message.id)?.body)
        bo.engine.flush()
        assertEquals(ReceiveOutcome.RECEIPT, ada.engine.receive(bo.keys.directId, boLinks.sent.last()))
        assertEquals(ACCEPTED, ada.store.message(message.id)?.state)
        assertNull(ada.store.queued(message.id))

        assertEquals(0, bo.engine.markRead(ada.keys.directId), "an unaccepted request sends no read receipt")
        bo.store.putContact(bo.store.contact(ada.keys.directId)!!.copy(accepted = true))
        assertEquals(1, bo.engine.markRead(ada.keys.directId))
        bo.engine.flush()
        assertEquals(ReceiveOutcome.RECEIPT, ada.engine.receive(bo.keys.directId, boLinks.sent.last()))
        assertEquals(ACKNOWLEDGED, ada.store.message(message.id)?.state)
        assertTrue(bo.store.queue().isEmpty(), "receipts leave the queue once written")
    }

    @Test
    fun `no receipt means resend, and the duplicate is acked without a second copy`() = runTest {
        var now = 1_000L
        val adaLinks = Links().apply { reachable = true }
        val boLinks = Links().apply { reachable = true }
        val ada = Device("Ada", { now }, adaLinks)
        val bo = Device("Bo", { now }, boLinks)
        ada.know(bo)
        bo.know(ada)
        val message = ada.engine.queueText(bo.keys.directId, "again")
        ada.engine.flush()
        bo.engine.receive(ada.keys.directId, adaLinks.sent.last())

        now += 5_000
        ada.engine.flush()
        assertEquals(QUEUED, ada.store.message(message.id)?.state)
        now += 1_000
        ada.engine.flush()
        assertEquals(SENT, ada.store.message(message.id)?.state)
        assertEquals(2, adaLinks.sent.size)
        assertEquals(ReceiveOutcome.DUPLICATE, bo.engine.receive(ada.keys.directId, adaLinks.sent.last()))
        assertEquals(1, bo.store.messagesWith(ada.keys.directId).size)
    }

    @Test
    fun `expiry fails the message and retry requeues it with a fresh envelope`() = runTest {
        var now = 1_000L
        val links = Links()
        val ada = Device("Ada", { now }, links)
        val bo = Device("Bo", { now }, Links())
        ada.know(bo)
        val message = ada.engine.queueText(bo.keys.directId, "late")
        now += 60_000
        ada.engine.flush()
        assertEquals(FAILED, ada.store.message(message.id)?.state)
        assertNull(ada.store.queued(message.id))
        assertTrue(ada.engine.retry(message.id))
        assertEquals(QUEUED, ada.store.message(message.id)?.state)
        assertEquals(now + 60_000, ada.store.queued(message.id)?.expiresAt)
    }

    @Test
    fun `blocked senders and forged envelopes are ignored`() = runTest {
        val now = 1_000L
        val adaLinks = Links().apply { reachable = true }
        val ada = Device("Ada", { now }, adaLinks)
        val bo = Device("Bo", { now }, Links())
        val eve = Device("Eve", { now }, Links())
        ada.know(bo)
        bo.know(ada)
        bo.know(eve)
        ada.engine.queueText(bo.keys.directId, "hi")
        ada.engine.flush()
        val bytes = adaLinks.sent.last()
        assertEquals(ReceiveOutcome.IGNORED, bo.engine.receive(eve.keys.directId, bytes), "claimed sender must match the channel")
        bo.store.putContact(bo.store.contact(ada.keys.directId)!!.copy(blocked = true))
        assertEquals(ReceiveOutcome.IGNORED, bo.engine.receive(ada.keys.directId, bytes))
        bo.store.putContact(bo.store.contact(ada.keys.directId)!!.copy(blocked = false))
        val forged = Encoding.text(bytes).replace("\"signature\":\"", "\"signature\":\"A")
        assertEquals(ReceiveOutcome.IGNORED, bo.engine.receive(ada.keys.directId, Encoding.utf8(forged)))
        assertEquals(ReceiveOutcome.STORED, bo.engine.receive(ada.keys.directId, bytes))
    }

    @Test
    fun `a group text is fanned out and accepted when every member acks`() = runTest {
        var now = 1_000L
        val adaLinks = Links().apply { reachable = true }
        val boLinks = Links().apply { reachable = true }
        val cyLinks = Links().apply { reachable = true }
        val ada = Device("Ada", { now }, adaLinks)
        val bo = Device("Bo", { now }, boLinks)
        val cy = Device("Cy", { now }, cyLinks)
        ada.know(bo)
        ada.know(cy)
        bo.know(ada)
        bo.know(cy)
        cy.know(ada)
        cy.know(bo)
        val members = listOf(ada.keys.directId, bo.keys.directId, cy.keys.directId)
        val group = GroupRecord("grp_" + "ab".repeat(16), "Weekend", members, ada.keys.directId, now)
        ada.store.putGroup(group)
        bo.store.putGroup(group)
        cy.store.putGroup(group)

        ada.engine.queueGroupInvite(group, ada.keys.directId)
        ada.engine.flush()
        fun deliver(to: Device, from: Device, payloads: List<ByteArray>) {
            for (payload in payloads) {
                val header = Envelopes.peek(payload) ?: continue
                if (header.to == to.keys.directId && header.from == from.keys.directId) {
                    to.engine.receive(from.keys.directId, payload)
                }
            }
        }
        deliver(bo, ada, adaLinks.sent)
        deliver(cy, ada, adaLinks.sent)
        assertEquals("Weekend", bo.store.group(group.id)?.name)

        adaLinks.sent.clear()
        val message = ada.engine.queueGroupText(group, ada.keys.directId, "hello all")
        assertEquals("hello all", GroupNotes.parsePrefixed(GroupNotes.encodeText(group.id, message.id, "hello all"))?.body)
        assertEquals(2, ada.store.queue().count { it.messageId == message.id })
        ada.engine.flush()
        assertEquals(SENT, ada.store.message(message.id)?.state)
        assertEquals(2, adaLinks.sent.size)
        val toBo = adaLinks.sent.first { Envelopes.peek(it)?.to == bo.keys.directId }
        val opened = Encoding.text(Envelopes.open(bo.keys, Envelopes.decode(toBo, ada.keys.signingPublic, now)))
        assertEquals("hello all", GroupNotes.parsePrefixed(opened)?.body, opened)
        assertEquals(ReceiveOutcome.STORED, bo.engine.receive(ada.keys.directId, toBo))
        assertEquals(ReceiveOutcome.STORED, cy.engine.receive(ada.keys.directId, adaLinks.sent.first { Envelopes.peek(it)?.to == cy.keys.directId }))
        val hello = bo.store.messagesWith(group.id).single { it.body == "hello all" }
        assertEquals(ada.keys.directId, hello.senderId)
        assertTrue(GroupNotes.parsePrefixed("DIRECT-GROUP/1\n{}") == null)
        bo.engine.flush()
        cy.engine.flush()
        assertEquals(ReceiveOutcome.RECEIPT, ada.engine.receive(bo.keys.directId, boLinks.sent.last()))
        assertEquals(SENT, ada.store.message(message.id)?.state)
        assertEquals(ReceiveOutcome.RECEIPT, ada.engine.receive(cy.keys.directId, cyLinks.sent.last()))
        assertEquals(ACCEPTED, ada.store.message(message.id)?.state)
        assertTrue(ada.store.queue().none { it.logicalId() == message.id })
    }

    @Test
    fun `edit and delete notes rewrite the original bubble`() = runTest {
        var now = 1_000L
        val adaLinks = Links().apply { reachable = true }
        val boLinks = Links().apply { reachable = true }
        val ada = Device("Ada", { now }, adaLinks)
        val bo = Device("Bo", { now }, boLinks)
        ada.know(bo)
        bo.know(ada)
        val encoded = ChatNotes.encode(ChatNotes.Note("edit", "msg_abcd", "hi"))
        assertEquals("edit", ChatNotes.parsePrefixed(encoded)?.op)
        assertEquals("hi", ChatNotes.parsePrefixed(encoded)?.body)
        assertNull(ChatNotes.parsePrefixed("DIRECT-CHAT/1\n{}"))

        val message = ada.engine.queueText(bo.keys.directId, "hello")
        ada.engine.flush()
        assertEquals(ReceiveOutcome.STORED, bo.engine.receive(ada.keys.directId, adaLinks.sent.last()))
        bo.engine.flush()
        assertEquals(ReceiveOutcome.RECEIPT, ada.engine.receive(bo.keys.directId, boLinks.sent.last()))
        assertEquals(ACCEPTED, ada.store.message(message.id)?.state)

        adaLinks.sent.clear()
        ada.engine.editText(message.id, "hello there")
        assertEquals("hello there", ada.store.message(message.id)?.body)
        assertEquals(true, ada.store.message(message.id)?.edited)
        ada.engine.flush()
        assertEquals(ReceiveOutcome.STORED, bo.engine.receive(ada.keys.directId, adaLinks.sent.last()))
        assertEquals("hello there", bo.store.message(message.id)?.body)
        assertEquals(true, bo.store.message(message.id)?.edited)

        adaLinks.sent.clear()
        ada.engine.deleteMessage(message.id, true)
        assertEquals(true, ada.store.message(message.id)?.deleted)
        ada.engine.flush()
        assertEquals(ReceiveOutcome.STORED, bo.engine.receive(ada.keys.directId, adaLinks.sent.last()))
        assertEquals(true, bo.store.message(message.id)?.deleted)
        assertEquals("", bo.store.message(message.id)?.body)
    }

    @Test
    fun `delete for me drops a bubble only on this phone`() = runTest {
        var now = 1_000L
        val adaLinks = Links().apply { reachable = true }
        val ada = Device("Ada", { now }, adaLinks)
        val bo = Device("Bo", { now }, Links())
        ada.know(bo)
        bo.know(ada)
        val message = ada.engine.queueText(bo.keys.directId, "hello")
        ada.engine.flush()
        assertEquals(ReceiveOutcome.STORED, bo.engine.receive(ada.keys.directId, adaLinks.sent.last()))
        ada.engine.deleteMessage(message.id, false)
        assertNull(ada.store.message(message.id))
        assertEquals("hello", bo.store.message(message.id)?.body)
    }

    @Test
    fun `an unsent edit reseals the original envelope`() = runTest {
        var now = 1_000L
        val adaLinks = Links()
        val ada = Device("Ada", { now }, adaLinks)
        val bo = Device("Bo", { now }, Links())
        ada.know(bo)
        val message = ada.engine.queueText(bo.keys.directId, "hello")
        ada.engine.editText(message.id, "changed")
        adaLinks.reachable = true
        ada.engine.flush()
        val opened = Encoding.text(Envelopes.open(bo.keys, Envelopes.decode(adaLinks.sent.last(), ada.keys.signingPublic, now)))
        assertEquals("changed", opened)
        assertNull(ChatNotes.parsePrefixed(opened))
    }

    @Test
    fun `forward copies a text bubble into another thread`() = runTest {
        var now = 1_000L
        val ada = Device("Ada", { now }, Links())
        val bo = Device("Bo", { now }, Links())
        val cy = Device("Cy", { now }, Links())
        ada.know(bo)
        ada.know(cy)
        val message = ada.engine.queueText(bo.keys.directId, "later")
        val forwarded = ada.engine.forward(message.id, cy.keys.directId, ada.keys.directId)
        assertEquals(true, forwarded.forwarded)
        assertEquals("later", forwarded.body)
        assertEquals(cy.keys.directId, forwarded.peerId)
        assertTrue(forwarded.id != message.id)
    }
}

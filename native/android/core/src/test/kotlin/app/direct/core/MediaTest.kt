package app.direct.core

import app.direct.core.crypto.Bundles
import app.direct.core.crypto.IdentityKeys
import app.direct.core.delivery.DeliveryEngine
import app.direct.core.delivery.MessageState.ACCEPTED
import app.direct.core.delivery.MessageState.QUEUED
import app.direct.core.delivery.MessageState.SENT
import app.direct.core.delivery.PeerLinks
import app.direct.core.delivery.ReceiveOutcome
import app.direct.core.protocol.MediaNotes
import app.direct.core.protocol.ProfileCards
import app.direct.core.store.ContactRecord
import app.direct.core.store.LocalStore
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest

class MediaTest {
    private class Links : PeerLinks {
        var reachable = true
        val sent = mutableListOf<ByteArray>()
        override fun isConnected(peerId: String) = reachable
        override suspend fun connect(peerId: String) = reachable
        override suspend fun send(peerId: String, payload: ByteArray): Boolean {
            if (!reachable) return false
            sent += payload
            return true
        }
    }

    private class Device(name: String, val clock: () -> Long, links: PeerLinks, chunk: Int) {
        val keys = IdentityKeys.generate()
        val deviceId = Encoding.newDeviceId()
        val bundle = Bundles.create(keys, name, deviceId)
        val store = LocalStore.inMemory()
        val media = Files.createTempDirectory("direct-media-$name").toFile()
        val engine = DeliveryEngine(
            store, { keys to deviceId }, links, clock, { 0.0 },
            ttlMs = 60_000, receiptTimeoutMs = 5_000, mediaDirectory = media, mediaChunkBytes = chunk,
        )

        fun know(other: Device) = store.putContact(
            ContactRecord(other.keys.directId, other.bundle.name, other.bundle.encode(), other.bundle.fingerprint, createdAt = 0),
        )
    }

    @Test
    fun `a media note roundtrips and a profile card keeps the bundle`() {
        val bytes = byteArrayOf(1, 2, 3, 9, 0xFF.toByte())
        val part = MediaNotes.Part("med_1", "image", "image/jpeg", "a.jpg", 0, 2, "see you")
        val encoded = MediaNotes.encodePart(part, bytes)
        val decoded = assertNotNull(MediaNotes.decodePart(encoded))
        assertEquals(part, decoded.first)
        assertTrue(bytes.contentEquals(decoded.second))
        assertEquals(null, MediaNotes.decodePart(Encoding.utf8("hello")))
        assertEquals(listOf(3, 3, 2), MediaNotes.split(ByteArray(8), 3).map { it.size })

        val bundle = """{"v":1,"name":"Ada","directId":"dir_X"}"""
        val card = ProfileCards.encode(bundle, "In the garden", byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 1))
        val parsed = ProfileCards.parse(card)
        assertEquals(bundle, parsed.bundle)
        assertEquals("In the garden", parsed.status)
        assertEquals(3, parsed.avatarJpeg?.size)
        assertEquals(bundle, ProfileCards.parse(bundle).bundle)
    }

    @Test
    fun `chunks are sealed to the peer and reassembled once`() = runTest {
        var now = 1_000L
        val adaLinks = Links()
        val boLinks = Links()
        val ada = Device("Ada", { now }, adaLinks, chunk = 4)
        val bo = Device("Bo", { now }, boLinks, chunk = 4)
        ada.know(bo)
        bo.know(ada)
        val payload = byteArrayOf(10, 11, 12, 13, 14, 15, 16)
        val message = ada.engine.queueMedia(bo.keys.directId, "image", "image/jpeg", "pic.jpg", payload, "sunset")
        assertEquals(QUEUED, ada.store.message(message.id)?.state)

        adaLinks.reachable = false
        ada.engine.flush()
        assertEquals(QUEUED, ada.store.message(message.id)?.state)
        assertEquals("Recipient unavailable", ada.store.message(message.id)?.lastError)
        assertTrue(adaLinks.sent.isEmpty())

        adaLinks.reachable = true
        now += 1_000
        ada.engine.flush()
        assertEquals(SENT, ada.store.message(message.id)?.state)
        assertEquals(2, adaLinks.sent.size, "7 bytes at 4 per chunk")
        assertTrue(adaLinks.sent.none { Encoding.text(it).contains("sunset") }, "the caption stays inside the seal")

        assertEquals(ReceiveOutcome.STORED, bo.engine.receive(ada.keys.directId, adaLinks.sent[0]))
        assertEquals(null, bo.store.message(message.id)?.mediaFile)
        assertEquals(ReceiveOutcome.STORED, bo.engine.receive(ada.keys.directId, adaLinks.sent[1]))
        assertTrue(payload.contentEquals(bo.media.resolve("${message.id}.bin").readBytes()))
        assertEquals("sunset", bo.store.message(message.id)?.body)
        bo.engine.flush()
        assertEquals(ReceiveOutcome.RECEIPT, ada.engine.receive(bo.keys.directId, boLinks.sent.last()))
        assertEquals(ACCEPTED, ada.store.message(message.id)?.state)
        assertFalse(bo.store.queue().any { it.id == message.id && MediaNotes.isJob(it.payload) })
    }
}

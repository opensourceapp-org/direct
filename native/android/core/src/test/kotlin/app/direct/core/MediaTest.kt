package app.direct.core

import app.direct.core.crypto.Bundles
import app.direct.core.crypto.IdentityKeys
import app.direct.core.delivery.DeliveryEngine
import app.direct.core.delivery.MessageState.ACCEPTED
import app.direct.core.delivery.MessageState.QUEUED
import app.direct.core.delivery.MessageState.SENT
import app.direct.core.delivery.PeerLinks
import app.direct.core.delivery.ReceiveOutcome
import app.direct.core.protocol.FeedNotes
import app.direct.core.protocol.MediaNotes
import app.direct.core.protocol.ProfileCards
import app.direct.core.store.ContactRecord
import app.direct.core.store.GroupRecord
import app.direct.core.store.LocalStore
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
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
        val card = ProfileCards.encode(bundle, "In the garden", byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 1), "ws://192.168.1.20:8787")
        val parsed = ProfileCards.parse(card)
        assertEquals(bundle, parsed.bundle)
        assertEquals("In the garden", parsed.status)
        assertEquals(3, parsed.avatarJpeg?.size)
        assertEquals("ws://192.168.1.20:8787", parsed.bootstrap)
        assertEquals("", ProfileCards.parse(ProfileCards.encode(bundle, "In the garden", null)).bootstrap)
        assertEquals(bundle, ProfileCards.parse(bundle).bundle)
        assertEquals("", ProfileCards.parse(bundle).bootstrap)

        val groupId = "grp_" + "ab".repeat(16)
        val grouped = MediaNotes.Part("med_1", "image", "image/jpeg", "a.jpg", 0, 2, "see you", groupId)
        val opened = assertNotNull(MediaNotes.decodePart(MediaNotes.encodePart(grouped, bytes)))
        assertEquals(grouped, opened.first)
        assertEquals(groupId, opened.first.groupId)
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

    @Test
    fun `a group photo is sealed to each member and stored on the group thread`() = runTest {
        var now = 1_000L
        val adaLinks = Links()
        val boLinks = Links()
        val ada = Device("Ada", { now }, adaLinks, chunk = 8)
        val bo = Device("Bo", { now }, boLinks, chunk = 8)
        ada.know(bo)
        bo.know(ada)
        val members = listOf(ada.keys.directId, bo.keys.directId)
        val group = GroupRecord("grp_" + "cd".repeat(16), "Weekend", members, ada.keys.directId, now)
        ada.store.putGroup(group)
        bo.store.putGroup(group)
        val payload = byteArrayOf(1, 2, 3, 4, 5)
        val message = ada.engine.queueGroupMedia(group, ada.keys.directId, "image", "image/jpeg", "pic.jpg", payload, "pool")
        assertEquals(1, ada.store.queue().count { it.messageId == message.id })
        ada.engine.flush()
        assertEquals(SENT, ada.store.message(message.id)?.state)
        assertTrue(adaLinks.sent.isNotEmpty())
        for (bytes in adaLinks.sent) {
            bo.engine.receive(ada.keys.directId, bytes)
        }
        val received = bo.store.messagesWith(group.id).single { it.id == message.id }
        assertEquals(ada.keys.directId, received.senderId)
        assertEquals("pool", received.body)
        assertEquals("image", received.mediaKind)
        assertTrue(payload.contentEquals(bo.media.resolve("${message.id}.bin").readBytes()))
        bo.engine.flush()
        assertEquals(ReceiveOutcome.RECEIPT, ada.engine.receive(bo.keys.directId, boLinks.sent.last()))
        assertEquals(ACCEPTED, ada.store.message(message.id)?.state)
        assertTrue(ada.store.queue().none { it.logicalId() == message.id })
    }

    @Test
    fun `a story is sealed to a contact and expires after a day`() = runTest {
        var now = 1_000L
        val adaLinks = Links()
        val boLinks = Links()
        val ada = Device("Ada", { now }, adaLinks, chunk = 4)
        val bo = Device("Bo", { now }, boLinks, chunk = 4)
        ada.know(bo)
        bo.know(ada)
        val payload = byteArrayOf(10, 11, 12, 13, 14)
        val story = ada.engine.queueFeed(FeedNotes.STORY, "image", "image/jpeg", "story.jpg", payload, "hi")
        assertEquals(FeedNotes.STORY, ada.store.feed(story.id)?.channel)
        assertEquals(now + FeedNotes.STORY_TTL_MS, ada.store.feed(story.id)?.expiresAt)
        ada.engine.flush()
        assertTrue(adaLinks.sent.isNotEmpty())
        for (bytes in adaLinks.sent) {
            bo.engine.receive(ada.keys.directId, bytes)
        }
        val received = assertNotNull(bo.store.feed(story.id))
        assertEquals(ada.keys.directId, received.ownerId)
        assertEquals("hi", received.caption)
        assertTrue(payload.contentEquals(bo.media.resolve("${story.id}.bin").readBytes()))
        assertFalse(received.seen)
        bo.engine.markFeedSeen(ada.keys.directId)
        assertTrue(bo.store.feed(story.id)?.seen == true)

        now += FeedNotes.STORY_TTL_MS + 1
        assertEquals(1, bo.store.pruneFeed(now).size)
        assertNull(bo.store.feed(story.id))
    }

    @Test
    fun `a profile post reaches the other phone and delete removes it`() = runTest {
        var now = 1_000L
        val adaLinks = Links()
        val boLinks = Links()
        val ada = Device("Ada", { now }, adaLinks, chunk = 8)
        val bo = Device("Bo", { now }, boLinks, chunk = 8)
        ada.know(bo)
        bo.know(ada)
        val payload = byteArrayOf(1, 2, 3, 4, 5)
        val post = ada.engine.queueFeed(FeedNotes.POST, "image", "image/jpeg", "pic.jpg", payload, "")
        ada.engine.flush()
        for (bytes in adaLinks.sent) bo.engine.receive(ada.keys.directId, bytes)
        assertEquals(FeedNotes.POST, bo.store.feed(post.id)?.channel)
        assertNull(bo.store.feed(post.id)?.expiresAt)

        adaLinks.sent.clear()
        ada.engine.deleteFeed(post.id)
        assertNull(ada.store.feed(post.id))
        ada.engine.flush()
        assertTrue(adaLinks.sent.isNotEmpty())
        for (bytes in adaLinks.sent) bo.engine.receive(ada.keys.directId, bytes)
        assertNull(bo.store.feed(post.id))
    }

    @Test
    fun `a like and a comment on a post reach the other phone`() = runTest {
        val like = FeedNotes.decodeSocial(FeedNotes.encodeLike("fed_abc"))
        assertEquals("like", like?.op)
        assertEquals("fed_abc", like?.id)
        val encoded = FeedNotes.encodeComment("fed_abc", "cmt_1", "nice shot", 42)
        val comment = assertNotNull(FeedNotes.decodeSocial(encoded))
        assertEquals("comment", comment.op)
        assertEquals("nice shot", comment.body)
        assertEquals("cmt_1", comment.commentId)
        assertEquals(42L, comment.createdAt)
        assertNull(FeedNotes.decodeSocial(FeedNotes.encodeDelete(FeedNotes.POST, "fed_abc")))
        assertNull(FeedNotes.decodeDelete(encoded))

        var now = 1_000L
        val adaLinks = Links()
        val boLinks = Links()
        val ada = Device("Ada", { now }, adaLinks, chunk = 8)
        val bo = Device("Bo", { now }, boLinks, chunk = 8)
        ada.know(bo)
        bo.know(ada)
        val post = ada.engine.queueFeed(FeedNotes.POST, "image", "image/jpeg", "pic.jpg", byteArrayOf(1, 2, 3, 4, 5), "lake")
        ada.engine.flush()
        for (bytes in adaLinks.sent) bo.engine.receive(ada.keys.directId, bytes)
        assertEquals("lake", bo.store.feed(post.id)?.caption)

        adaLinks.sent.clear()
        boLinks.sent.clear()
        bo.engine.likeFeed(post.id)
        assertEquals(listOf(bo.keys.directId), bo.store.feed(post.id)?.likes?.map { it.fromId })
        bo.engine.flush()
        assertTrue(boLinks.sent.isNotEmpty())
        for (bytes in boLinks.sent) ada.engine.receive(bo.keys.directId, bytes)
        assertEquals(listOf(bo.keys.directId), ada.store.feed(post.id)?.likes?.map { it.fromId })

        boLinks.sent.clear()
        bo.engine.likeFeed(post.id)
        assertTrue(bo.store.feed(post.id)?.likes.isNullOrEmpty())
        bo.engine.flush()
        for (bytes in boLinks.sent) ada.engine.receive(bo.keys.directId, bytes)
        assertTrue(ada.store.feed(post.id)?.likes.isNullOrEmpty())

        boLinks.sent.clear()
        bo.engine.commentFeed(post.id, "  looks great  ")
        val local = assertNotNull(bo.store.feed(post.id)?.comments?.single())
        assertEquals(bo.keys.directId, local.fromId)
        assertEquals("looks great", local.body)
        bo.engine.flush()
        for (bytes in boLinks.sent) ada.engine.receive(bo.keys.directId, bytes)
        val remote = assertNotNull(ada.store.feed(post.id)?.comments?.single())
        assertEquals(local.id, remote.id)
        assertEquals("looks great", remote.body)
        assertEquals(bo.keys.directId, remote.fromId)

        boLinks.sent.clear()
        bo.engine.reactFeed(post.id, "🔥")
        assertEquals("🔥", bo.store.feed(post.id)?.likes?.first()?.emoji)
        bo.engine.flush()
        for (bytes in boLinks.sent) ada.engine.receive(bo.keys.directId, bytes)
        assertEquals("🔥", ada.store.feed(post.id)?.likes?.first()?.emoji)

        val fire = assertNotNull(FeedNotes.decodeSocial(FeedNotes.encodeReact("fed_abc", "🔥")))
        assertEquals("react", fire.op)
        assertEquals("🔥", fire.body)
        assertNull(FeedNotes.decodeSocial(FeedNotes.encodeReact("fed_abc", "not-an-emoji")))

        adaLinks.sent.clear()
        boLinks.sent.clear()
        val forwarded = bo.engine.forwardFeed(post.id, ada.keys.directId)
        assertTrue(forwarded.forwarded)
        assertEquals("lake", forwarded.body)
        assertEquals("image", forwarded.mediaKind)
        assertEquals(ada.keys.directId, forwarded.peerId)
        bo.engine.flush()
        assertTrue(boLinks.sent.isNotEmpty())
        for (bytes in boLinks.sent) ada.engine.receive(bo.keys.directId, bytes)
        val copy = assertNotNull(ada.store.message(forwarded.id))
        assertEquals("lake", copy.body)
        assertEquals("image", copy.mediaKind)
    }
}

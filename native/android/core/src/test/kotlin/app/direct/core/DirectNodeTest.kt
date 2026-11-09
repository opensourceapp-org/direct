package app.direct.core

import app.direct.core.delivery.MessageState
import app.direct.core.node.CallPhase
import app.direct.core.node.DirectException
import app.direct.core.node.DirectNode
import app.direct.core.signaling.BootstrapUrl
import app.direct.core.protocol.ProfileCards
import app.direct.core.signaling.BootstrapStatus.Phase
import app.direct.core.store.Direction
import app.direct.core.store.MemorySecretStore
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

@OptIn(ExperimentalCoroutinesApi::class)
class DirectNodeTest {
    private val dir: File = Files.createTempDirectory("direct-node").toFile()
    private val hub = FakeHub()
    private val network = FakePeerNetwork()

    private fun TestScope.node(secrets: MemorySecretStore, name: String) = DirectNode(
        secrets = secrets,
        storeFile = dir.resolve("$name.store"),
        sockets = hub,
        transportFactory = network::transport,
        dispatcher = StandardTestDispatcher(testScheduler),
        clock = { 1_790_000_000_000 + testScheduler.currentTime },
        random = { 0.0 },
    )

    private fun TestScope.settle(ms: Long = 2_000) {
        runCurrent()
        advanceTimeBy(ms)
        runCurrent()
    }

    @Test
    fun `a message to an offline phone waits, survives restarts, arrives as a request, and is acknowledged`() = runTest {
        val adaSecrets = MemorySecretStore()
        val boSecrets = MemorySecretStore()
        var ada = node(adaSecrets, "ada")
        var bo = node(boSecrets, "bo")
        ada.start()
        bo.start()
        ada.createIdentity("Ada")
        bo.createIdentity("Bo")
        val adaId = ada.state.value.profile!!.directId
        val boId = bo.state.value.profile!!.directId

        assertEquals(BootstrapUrl.DEFAULT, ada.state.value.bootstrapUrl)
        assertEquals(BootstrapUrl.DEFAULT, bo.state.value.bootstrapUrl)

        assertEquals("ws://192.168.1.20:8787", ada.setBootstrap("192.168.1.20"))
        assertEquals("ws://192.168.1.20:8787", bo.setBootstrap("ws://192.168.1.20:8787/"))
        settle()
        assertEquals(Phase.OPEN, ada.state.value.bootstrap.phase)

        val missing = assertFailsWith<DirectException> { ada.addContact("dir_0123456789ABCDEH") }
        assertEquals(DirectException.Reason.NOT_FOUND, missing.reason)
        ada.addContact(boId.lowercase().replaceFirst("dir_", "DIR_"))
        assertTrue(ada.state.value.contacts.single().accepted)

        bo.close()
        settle()
        ada.send(boId, "Hello from Ada")
        settle()
        val queued = ada.state.value.messages.getValue(boId).single()
        assertEquals(MessageState.QUEUED, queued.state)
        assertEquals("Recipient unavailable", queued.lastError)

        ada.close()
        ada = node(adaSecrets, "ada")
        ada.start()
        settle()
        assertEquals(adaId, ada.state.value.profile!!.directId)
        assertEquals(MessageState.QUEUED, ada.state.value.messages.getValue(boId).single().state)
        assertEquals("Hello from Ada", ada.state.value.messages.getValue(boId).single().body)

        bo = node(boSecrets, "bo")
        bo.start()
        settle()
        assertEquals(MessageState.ACCEPTED, ada.state.value.messages.getValue(boId).single().state)
        val request = bo.state.value.conversations.single()
        assertEquals(adaId, request.peerId)
        assertTrue(request.request)
        assertEquals("Hello from Ada", bo.state.value.messages.getValue(adaId).single().body)
        val refused = assertFailsWith<DirectException> { bo.send(adaId, "too soon") }
        assertEquals(DirectException.Reason.NOT_ACCEPTED, refused.reason)

        bo.acceptRequest(adaId)
        settle()
        assertEquals(MessageState.ACKNOWLEDGED, ada.state.value.messages.getValue(boId).single().state)

        bo.send(adaId, "Hi Ada")
        settle()
        val reply = ada.state.value.messages.getValue(boId).last()
        assertEquals(Direction.INCOMING, reply.direction)
        assertEquals("Hi Ada", reply.body)
        assertEquals(MessageState.ACCEPTED, bo.state.value.messages.getValue(adaId).last().state)

        assertTrue(hub.received.none { "Hello from Ada" in it || "Hi Ada" in it }, "the bootstrap never sees message text")
        ada.close()
        bo.close()
    }

    @Test
    fun `declining a request blocks the sender`() = runTest {
        val ada = node(MemorySecretStore(), "ada2")
        val bo = node(MemorySecretStore(), "bo2")
        ada.start()
        bo.start()
        ada.createIdentity("Ada")
        bo.createIdentity("Bo")
        ada.setBootstrap("10.0.0.5")
        bo.setBootstrap("10.0.0.5")
        settle()
        val adaId = ada.state.value.profile!!.directId
        val boId = bo.state.value.profile!!.directId
        ada.addContact(boId)
        ada.send(boId, "first")
        settle()
        bo.declineRequest(adaId)
        settle()
        assertTrue(bo.state.value.conversations.isEmpty())
        ada.send(boId, "second")
        settle()
        assertEquals(listOf("first"), bo.state.value.messages.getValue(adaId).map { it.body })
        ada.close()
        bo.close()
    }

    @Test
    fun `a shared profile saves the server`() = runTest {
        val ada = node(MemorySecretStore(), "ada-share")
        val bo = node(MemorySecretStore(), "bo-share")
        ada.start()
        bo.start()
        ada.createIdentity("Ada")
        bo.createIdentity("Bo")
        val bundle = ada.state.value.bundle!!
        val card = ProfileCards.encode(bundle, "Here", null, "192.168.1.20")
        val added = bo.addFromShare(card)
        assertEquals(ada.state.value.profile!!.directId, added.directId)
        assertEquals("Here", added.about)
        assertEquals("ws://192.168.1.20:8787", bo.state.value.bootstrapUrl)
        settle()
        assertEquals(Phase.OPEN, bo.state.value.bootstrap.phase)
        ada.close()
        bo.close()
    }

    @Test
    fun `a profile photo reaches the other phone and can be cleared`() = runTest {
        val ada = node(MemorySecretStore(), "ada-photo")
        val bo = node(MemorySecretStore(), "bo-photo")
        ada.start()
        bo.start()
        ada.createIdentity("Ada")
        bo.createIdentity("Bo")
        ada.setBootstrap("192.168.1.20")
        bo.setBootstrap("192.168.1.20")
        settle()
        val adaId = ada.state.value.profile!!.directId
        val boId = bo.state.value.profile!!.directId
        ada.addContact(boId)
        val jpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xD9.toByte())
        ada.setAvatar(jpeg)
        ada.setStatus("At work")
        settle()
        val seen = bo.state.value.contacts.single { it.directId == adaId }
        assertEquals(Encoding.base64Url(jpeg), seen.avatarJpegBase64)
        assertEquals("At work", seen.about)
        assertTrue(hub.received.none { Encoding.base64Url(jpeg) in it }, "the bootstrap never sees the photo")
        ada.clearAvatar()
        settle()
        assertEquals(null, bo.state.value.contacts.single { it.directId == adaId }.avatarJpegBase64)
        ada.close()
        bo.close()
    }

    @Test
    fun `a disconnected bootstrap is reported as offline, not as a missing phone`() = runTest {
        val ada = node(MemorySecretStore(), "ada3")
        ada.start()
        ada.createIdentity("Ada")
        hub.reachable = false
        ada.setBootstrap("192.168.1.20")
        settle()
        val error = assertFailsWith<DirectException> { ada.addContact("dir_ABCDEFGHJKMNPQRS") }
        assertEquals(DirectException.Reason.BOOTSTRAP_OFFLINE, error.reason)
        assertTrue("ws://192.168.1.20:8787" in error.message!!)
        hub.reachable = true
        ada.onNetworkAvailable()
        settle()
        assertEquals(Phase.OPEN, ada.state.value.bootstrap.phase)
        ada.close()
    }

    @Test
    fun `an audio call is sealed on the data channel and the bootstrap never sees it`() = runTest {
        val ada = node(MemorySecretStore(), "ada-call")
        val bo = node(MemorySecretStore(), "bo-call")
        ada.start()
        bo.start()
        ada.createIdentity("Ada")
        bo.createIdentity("Bo")
        ada.setBootstrap("192.168.1.20")
        bo.setBootstrap("192.168.1.20")
        settle()
        val adaId = ada.state.value.profile!!.directId
        val boId = bo.state.value.profile!!.directId
        ada.addContact(boId)
        settle()
        bo.acceptRequest(adaId)
        settle()

        ada.placeCall(boId, false)
        settle()
        val incoming = bo.state.value.call
        assertEquals(CallPhase.INCOMING, incoming?.phase)
        assertEquals(false, incoming?.video)
        assertEquals(boId, ada.state.value.call?.peerId)

        bo.acceptCall()
        settle()
        assertEquals(CallPhase.CONNECTING, ada.state.value.call?.phase)
        ada.relayOffer("direct-call-offer")
        settle()
        bo.relayAnswer("direct-call-answer")
        ada.markCallLive()
        bo.markCallLive()
        settle()
        assertEquals(CallPhase.ACTIVE, ada.state.value.call?.phase)
        assertEquals(CallPhase.ACTIVE, bo.state.value.call?.phase)
        assertTrue(hub.received.none { "direct-call-offer" in it || "direct-call-answer" in it || "\"op\":\"invite\"" in it })

        ada.endCall()
        settle()
        assertEquals(CallPhase.ENDED, bo.state.value.call?.phase)
        assertTrue(ada.state.value.messages.getValue(boId).any { it.mediaKind == "call" && it.body.startsWith("Audio call") })
        assertTrue(bo.state.value.messages.getValue(adaId).any { it.mediaKind == "call" && it.body.startsWith("Audio call") })

        ada.dismissCall()
        bo.dismissCall()
        ada.placeCall(boId, true)
        settle()
        assertEquals(true, bo.state.value.call?.video)
        bo.endCall()
        settle()
        assertEquals("Call declined", ada.state.value.call?.reason)
        assertEquals("Declined", bo.state.value.call?.reason)

        ada.dismissCall()
        bo.dismissCall()
        network.goOffline(boId)
        val missed = assertFailsWith<DirectException> { ada.placeCall(boId, false) }
        assertEquals(DirectException.Reason.REJECTED, missed.reason)
        assertEquals("Unreachable", ada.state.value.call?.reason)
        ada.close()
        bo.close()
    }

    @Test
    fun `the hosted bootstrap is saved on first start and used to connect`() = runTest {
        val secrets = MemorySecretStore()
        val ada = node(secrets, "ada-hosted")
        ada.start()
        assertEquals(BootstrapUrl.DEFAULT, ada.state.value.bootstrapUrl)
        settle()
        assertEquals(Phase.OPEN, ada.state.value.bootstrap.phase)
        ada.close()
        val again = node(secrets, "ada-hosted")
        again.start()
        assertEquals(BootstrapUrl.DEFAULT, again.state.value.bootstrapUrl)
        again.close()
    }

    // Group fan-out and receipts are covered in DeliveryEngineTest. DirectNode group
    // flows use the same engine; three live run loops on one test dispatcher do not settle.

    @Test
    fun `creating a group lists it on this phone`() = runTest {
        val ada = node(MemorySecretStore(), "ada-g")
        val bo = node(MemorySecretStore(), "bo-g")
        ada.start()
        bo.start()
        ada.createIdentity("Ada")
        bo.createIdentity("Bo")
        ada.setBootstrap("192.168.1.20")
        bo.setBootstrap("192.168.1.20")
        settle()
        val boId = bo.state.value.profile!!.directId
        ada.addContact(boId)
        settle()
        val group = ada.createGroup("Weekend", listOf(boId))
        assertTrue(group.id.startsWith("grp_"))
        assertEquals("Weekend", ada.state.value.conversations.single { it.group }.name)
        assertEquals(2, ada.state.value.groups.single().members.size)
        ada.close()
        bo.close()
    }

    @Test
    fun `a group message is sealed to each member and the bootstrap never sees it`() = runTest {
        val ada = node(MemorySecretStore(), "ada-gm")
        val bo = node(MemorySecretStore(), "bo-gm")
        ada.start()
        bo.start()
        ada.createIdentity("Ada")
        bo.createIdentity("Bo")
        ada.setBootstrap("192.168.1.20")
        bo.setBootstrap("192.168.1.20")
        settle()
        val adaId = ada.state.value.profile!!.directId
        val boId = bo.state.value.profile!!.directId
        ada.addContact(boId)
        settle()
        bo.acceptRequest(adaId)
        settle()

        val group = ada.createGroup("Weekend", listOf(boId))
        settle()
        assertEquals("Weekend", bo.state.value.conversations.single { it.group }.name)

        ada.send(group.id, "hello all")
        settle()
        assertEquals("hello all", bo.state.value.messages.getValue(group.id).last().body)
        assertEquals(adaId, bo.state.value.messages.getValue(group.id).last().senderId)
        assertEquals(MessageState.ACCEPTED, ada.state.value.messages.getValue(group.id).single { it.body == "hello all" }.state)
        assertTrue(hub.received.none { "hello all" in it || "DIRECT-GROUP/1" in it })

        bo.send(group.id, "hi from bo")
        settle()
        assertEquals("hi from bo", ada.state.value.messages.getValue(group.id).last().body)
        ada.close()
        bo.close()
    }

    @Test
    fun `a group audio call is sealed to each member`() = runTest {
        val ada = node(MemorySecretStore(), "ada-gc")
        val bo = node(MemorySecretStore(), "bo-gc")
        ada.start()
        bo.start()
        ada.createIdentity("Ada")
        bo.createIdentity("Bo")
        ada.setBootstrap("192.168.1.20")
        bo.setBootstrap("192.168.1.20")
        settle()
        val adaId = ada.state.value.profile!!.directId
        val boId = bo.state.value.profile!!.directId
        ada.addContact(boId)
        settle()
        bo.acceptRequest(adaId)
        settle()
        val group = ada.createGroup("Weekend", listOf(boId))
        settle()

        ada.placeCall(group.id, false)
        settle()
        assertEquals(CallPhase.INCOMING, bo.state.value.call?.phase)
        assertEquals(true, bo.state.value.call?.group)
        assertEquals(group.id, bo.state.value.call?.peerId)

        bo.acceptCall()
        settle()
        assertEquals(CallPhase.CONNECTING, ada.state.value.call?.phase)
        ada.relayOffer("group-offer", boId)
        settle()
        bo.relayAnswer("group-answer", adaId)
        ada.markCallLive()
        bo.markCallLive()
        settle()
        assertEquals(CallPhase.ACTIVE, ada.state.value.call?.phase)
        assertTrue(hub.received.none { "group-offer" in it || "group-answer" in it || "\"op\":\"invite\"" in it })

        ada.endCall()
        settle()
        assertEquals(CallPhase.ENDED, bo.state.value.call?.phase)
        assertTrue(ada.state.value.messages.getValue(group.id).any { it.mediaKind == "call" && it.body.startsWith("Group audio") })
        ada.close()
        bo.close()
    }
}

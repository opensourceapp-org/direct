package app.direct.core

import app.direct.core.signaling.BootstrapClient
import app.direct.core.signaling.BootstrapStatus.Phase
import app.direct.core.signaling.SignalCodec
import app.direct.core.signaling.SignalFrame
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

@OptIn(ExperimentalCoroutinesApi::class)
class BootstrapClientTest {
    private val ada = "dir_0123456789ABCDEF"
    private val bo = "dir_ABCDEFGHJKMNPQRS"
    private fun bundle(id: String) = """{"v":1,"name":"Phone","directId":"$id","note":"public"}"""

    private fun TestScope.client(hub: FakeHub): Pair<BootstrapClient, CoroutineScope> {
        val scope = CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler))
        return BootstrapClient(scope, hub) to scope
    }

    @Test
    fun `no address means not configured, with no socket opened`() = runTest {
        val hub = FakeHub()
        val (client, scope) = client(hub)
        client.start()
        runCurrent()
        assertEquals(Phase.NOT_CONFIGURED, client.status.value.phase)
        assertNull(client.lookup(bo))
        scope.cancel()
    }

    @Test
    fun `hello on open, lookup, watch, and an unreachable offer`() = runTest {
        val hub = FakeHub()
        val (alice, scopeA) = client(hub)
        val (bob, scopeB) = client(hub)
        alice.announce(ada, bundle(ada))
        alice.watch(listOf(bo))
        alice.configure("ws://192.168.1.20:8787")
        alice.start()
        runCurrent()
        assertEquals(Phase.OPEN, alice.status.value.phase)
        assertEquals(SignalFrame.Hello(ada, bundle(ada)), SignalCodec.decode(hub.received.first()))

        val presence = mutableListOf<SignalFrame.Presence>()
        val collector = scopeA.launchCollect(alice) { presence += it }
        bob.announce(bo, bundle(bo))
        bob.configure("ws://192.168.1.20:8787")
        bob.start()
        runCurrent()
        assertTrue(SignalFrame.Presence(bo, true) in presence)

        assertEquals(bundle(bo), alice.lookup(bo))
        assertNull(alice.lookup("dir_0123456789ABCDEH"))
        assertFalse(alice.sendNegotiation(SignalFrame.Offer("dir_0123456789ABCDEH", ada, "v=0")))
        assertTrue(alice.sendNegotiation(SignalFrame.Offer(bo, ada, "v=0")))
        assertTrue(hub.received.none { "body" in it || "\"message\"" in it })
        collector.cancel()
        scopeA.cancel()
        scopeB.cancel()
    }

    @Test
    fun `a dropped bootstrap retries with backoff and reconnectNow skips the wait`() = runTest {
        val hub = FakeHub()
        val (client, scope) = client(hub)
        client.announce(ada, bundle(ada))
        client.configure("ws://192.168.1.20:8787")
        client.start()
        runCurrent()
        assertEquals(Phase.OPEN, client.status.value.phase)

        hub.reachable = false
        hub.dropAll()
        runCurrent()
        assertEquals(Phase.RETRYING, client.status.value.phase)
        advanceTimeBy(1_001)
        runCurrent()
        assertEquals(Phase.RETRYING, client.status.value.phase)

        hub.reachable = true
        advanceTimeBy(1_500)
        runCurrent()
        assertEquals(Phase.RETRYING, client.status.value.phase, "second retry waits 2s")
        advanceTimeBy(600)
        runCurrent()
        assertEquals(Phase.OPEN, client.status.value.phase)
        assertEquals(2, hub.received.count { "\"hello\"" in it }, "hello is sent again on every open")

        hub.dropAll()
        runCurrent()
        client.reconnectNow()
        runCurrent()
        assertEquals(Phase.OPEN, client.status.value.phase)
        scope.cancel()
    }

    @Test
    fun `suggest lists only discoverable live phones`() = runTest {
        val hub = FakeHub()
        val (alice, scopeA) = client(hub)
        val (bob, scopeB) = client(hub)
        alice.announce(ada, bundle(ada), discoverable = true)
        alice.configure("ws://192.168.1.20:8787")
        alice.start()
        bob.announce(bo, bundle(bo))
        bob.configure("ws://192.168.1.20:8787")
        bob.start()
        runCurrent()
        assertEquals(emptyList(), alice.suggest())
        val listed = bob.suggest()
        assertEquals(1, listed.size)
        assertEquals(ada, listed[0].directId)
        assertTrue(listed[0].online)
        scopeA.cancel()
        scopeB.cancel()
    }

    private fun CoroutineScope.launchCollect(client: BootstrapClient, block: (SignalFrame.Presence) -> Unit) =
        launch { client.presence.collect { block(it) } }
}

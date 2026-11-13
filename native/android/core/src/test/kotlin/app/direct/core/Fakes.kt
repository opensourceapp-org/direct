package app.direct.core

import app.direct.core.crypto.DIRECT_ID_PATTERN
import app.direct.core.signaling.BootstrapClient
import app.direct.core.signaling.SignalCodec
import app.direct.core.signaling.SignalFrame
import app.direct.core.signaling.WebSocketConnection
import app.direct.core.signaling.WebSocketEvents
import app.direct.core.signaling.WebSocketFactory
import app.direct.core.transport.PeerListener
import app.direct.core.transport.PeerTransport
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

object Contracts {
    private val root = File(System.getProperty("direct.contracts") ?: "../../contracts")
    fun json(name: String): JsonElement = Json.parseToJsonElement(File(root, name).readText())
}

/** In-memory bootstrap with the rules of infrastructure/signaling/hub.cjs. Records every frame it receives. */
class FakeHub : WebSocketFactory {
    var reachable = true
    val received = mutableListOf<String>()
    private val live = mutableMapOf<String, Socket>()
    private val bundles = mutableMapOf<String, String>()
    private val discoverable = mutableMapOf<String, Boolean>()
    private val intros = mutableMapOf<String, Boolean>()
    private val watching = mutableMapOf<Socket, Set<String>>()

    inner class Socket(val events: WebSocketEvents) : WebSocketConnection {
        var selfId: String? = null
        var open = true

        override fun send(text: String): Boolean {
            if (!open) return false
            received += text
            handle(this, text)
            return true
        }

        override fun close() {
            if (!open) return
            open = false
            dropped(this)
        }
    }

    override fun open(url: String, events: WebSocketEvents): WebSocketConnection {
        val socket = Socket(events)
        if (reachable) events.onOpen() else {
            socket.open = false
            events.onClosed("connection refused")
        }
        return socket
    }

    /** Server restarts or the network drops: every socket closes. */
    fun dropAll() {
        for (socket in (live.values + watching.keys).toSet()) {
            if (!socket.open) continue
            socket.open = false
            dropped(socket)
            socket.events.onClosed("network lost")
        }
    }

    fun isOnline(id: String) = live[id]?.open == true

    private fun dropped(socket: Socket) {
        watching.remove(socket)
        val id = socket.selfId ?: return
        if (live[id] === socket) {
            live.remove(id)
            notify(id, false)
        }
    }

    private fun canSeePresence(watcher: String?, id: String): Boolean {
        if (watcher == null) return false
        if (discoverable[id] == true) return true
        return intros["$id\n$watcher"] == true
    }

    private fun notify(id: String, online: Boolean) {
        val frame = SignalCodec.encode(SignalFrame.Presence(id, online))
        for ((socket, ids) in watching) {
            if (id in ids && socket.open && canSeePresence(socket.selfId, id)) socket.events.onMessage(frame)
        }
    }

    private fun handle(socket: Socket, text: String) {
        when (val frame = SignalCodec.decode(text)) {
            is SignalFrame.Hello -> {
                if (!DIRECT_ID_PATTERN.matches(frame.from) || !frame.bundle.contains("\"directId\":\"${frame.from}\"")) return
                val wasOnline = isOnline(frame.from)
                socket.selfId = frame.from
                live[frame.from] = socket
                bundles[frame.from] = frame.bundle
                discoverable[frame.from] = frame.discoverable
                if (!wasOnline) notify(frame.from, true)
            }
            is SignalFrame.Lookup -> {
                val bundle = bundles[frame.directId]
                val listed = discoverable[frame.directId] == true
                val introduced = socket.selfId?.let { intros["${frame.directId}\n$it"] == true } == true
                val shown = socket.selfId != null && bundle != null && (listed || introduced)
                socket.events.onMessage(SignalCodec.encode(SignalFrame.LookupResult(frame.requestId, frame.directId, shown, if (shown) bundle else null)))
            }
            is SignalFrame.Watch -> {
                watching[socket] = frame.ids.toSet()
                for (id in frame.ids) {
                    val online = canSeePresence(socket.selfId, id) && isOnline(id)
                    socket.events.onMessage(SignalCodec.encode(SignalFrame.Presence(id, online)))
                }
            }
            is SignalFrame.Negotiation -> {
                if (frame.from != socket.selfId) return
                intros["${frame.from}\n${frame.to}"] = true
                notify(frame.from, isOnline(frame.from))
                val target = live[frame.to]
                if (target != null && target.open) target.events.onMessage(text)
                else if (frame is SignalFrame.Offer) socket.events.onMessage(SignalCodec.encode(SignalFrame.Unreachable(frame.to)))
            }
            is SignalFrame.Suggest -> {
                val except = socket.selfId
                val people = live.entries.mapNotNull { (id, peer) ->
                    if (!peer.open || id == except || discoverable[id] != true) return@mapNotNull null
                    val bundle = bundles[id] ?: return@mapNotNull null
                    SignalFrame.SuggestedPerson(id, displayName(bundle), bundle, true)
                }.sortedBy { it.name.ifEmpty { it.directId } }
                socket.events.onMessage(SignalCodec.encode(SignalFrame.Suggestions(frame.requestId, people)))
            }
            else -> Unit
        }
    }

    private fun displayName(bundle: String): String {
        val json = try {
            Json.parseToJsonElement(bundle) as? JsonObject
        } catch (_: Exception) {
            null
        } ?: return ""
        return (json["name"] as? JsonPrimitive)?.contentOrNull?.trim().orEmpty().take(80)
    }
}

/**
 * Stands in for WebRTC. A link opens only when both devices are reachable,
 * and it is negotiated through each device's bootstrap so presence matters.
 */
class FakePeerNetwork {
    private val transports = mutableMapOf<String, Transport>()
    val offline = mutableSetOf<String>()

    fun transport(bootstrap: BootstrapClient, selfId: String, @Suppress("UNUSED_PARAMETER") scope: CoroutineScope): PeerTransport =
        Transport(selfId, bootstrap).also { transports[selfId] = it }

    fun goOffline(id: String) {
        offline += id
        transports[id]?.closeAll()
        transports.values.forEach { it.close(id) }
    }

    fun goOnline(id: String) {
        offline -= id
    }

    inner class Transport(private val selfId: String, private val bootstrap: BootstrapClient) : PeerTransport {
        private var listener: PeerListener? = null
        private val links = mutableSetOf<String>()

        override fun setListener(listener: PeerListener?) {
            this.listener = listener
        }

        override fun connectedPeers(): Set<String> = links.toSet()

        override fun isConnected(peerId: String) = peerId in links

        override suspend fun connect(peerId: String): Boolean {
            if (selfId in offline || peerId in offline) return false
            if (!bootstrap.status.value.isOpen) return false
            val reachable = bootstrap.sendNegotiation(SignalFrame.Offer(peerId, selfId, "v=0"))
            val remote = transports[peerId]
            // The offer wait can outlive the other phone. A forwarded offer is not a live link.
            if (!reachable || remote == null || !remote.bootstrap.status.value.isOpen) return false
            links += peerId
            remote.links += selfId
            listener?.onPeerConnected(peerId)
            remote.listener?.onPeerConnected(selfId)
            return true
        }

        override suspend fun send(peerId: String, payload: ByteArray): Boolean {
            if (peerId !in links || selfId in offline || peerId in offline) return false
            transports[peerId]?.listener?.onPeerData(selfId, payload.copyOf()) ?: return false
            return true
        }

        override fun close(peerId: String) {
            if (links.remove(peerId)) listener?.onPeerClosed(peerId)
        }

        override fun closeAll() {
            links.toList().forEach { peer ->
                close(peer)
                transports[peer]?.close(selfId)
            }
        }
    }
}

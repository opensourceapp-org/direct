package app.direct.core.signaling

import app.direct.core.Encoding
import kotlin.math.min
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** Platform WebSocket: OkHttp on Android, URLSessionWebSocketTask on iOS, fakes in tests. */
interface WebSocketFactory {
    fun open(url: String, events: WebSocketEvents): WebSocketConnection
}

interface WebSocketConnection {
    fun send(text: String): Boolean
    fun close()
}

/** May be called from any thread. The client hops onto its own scope. */
interface WebSocketEvents {
    fun onOpen()
    fun onMessage(text: String)
    fun onClosed(error: String?)
}

data class BootstrapStatus(val phase: Phase, val url: String?, val error: String? = null) {
    enum class Phase { NOT_CONFIGURED, CONNECTING, OPEN, RETRYING, STOPPED }

    val isOpen: Boolean get() = phase == Phase.OPEN
}

/**
 * One socket to the bootstrap. Announces this device's public bundle on every open,
 * keeps a watch list for presence, answers lookups, and carries WebRTC negotiation.
 * Reconnects with backoff (1s doubling to 30s). [reconnectNow] skips the wait, for
 * app foreground and network changes. All state is touched only on [scope].
 */
class BootstrapClient(
    private val scope: CoroutineScope,
    private val sockets: WebSocketFactory,
) {
    private val _status = MutableStateFlow(BootstrapStatus(BootstrapStatus.Phase.NOT_CONFIGURED, null))
    val status: StateFlow<BootstrapStatus> = _status

    private val _negotiation = MutableSharedFlow<SignalFrame.Negotiation>(extraBufferCapacity = 256)
    val negotiation: SharedFlow<SignalFrame.Negotiation> = _negotiation

    private val _presence = MutableSharedFlow<SignalFrame.Presence>(extraBufferCapacity = 256)
    val presence: SharedFlow<SignalFrame.Presence> = _presence

    var url: String? = null
        private set
    private var running = false
    private var selfId: String? = null
    private var bundle: String? = null
    private var nonce: String? = null
    private var signProof: ((String) -> String)? = null
    private var watchIds: List<String> = emptyList()
    private var connection: WebSocketConnection? = null
    private var generation = 0
    private var failures = 0
    private var retryJob: Job? = null
    private val lookups = HashMap<String, CompletableDeferred<String?>>()
    private val offers = HashMap<String, CompletableDeferred<Boolean>>()
    private val suggestions = HashMap<String, CompletableDeferred<List<SignalFrame.SuggestedPerson>>>()
    private var discoverable = false

    fun configure(newUrl: String?) {
        if (newUrl == url && connection != null) return
        url = newUrl
        reconnectNow()
    }

    fun start() {
        running = true
        if (connection == null && retryJob == null) connect()
    }

    fun stop() {
        running = false
        retryJob?.cancel()
        retryJob = null
        dropConnection()
        _status.value = BootstrapStatus(BootstrapStatus.Phase.STOPPED, url)
    }

    fun reconnectNow() {
        failures = 0
        retryJob?.cancel()
        retryJob = null
        dropConnection()
        if (running) connect()
    }

    fun announce(
        directId: String,
        publicBundle: String,
        signProof: ((String) -> String)? = null,
        discoverable: Boolean = false,
    ) {
        selfId = directId
        bundle = publicBundle
        this.signProof = signProof
        this.discoverable = discoverable
        sendHello()
    }

    fun watch(ids: Collection<String>) {
        val next = ids.distinct().take(SignalCodec.MAX_WATCH)
        if (next == watchIds) return
        watchIds = next
        if (_status.value.isOpen) send(SignalFrame.Watch(watchIds))
    }

    /** The published bundle for [directId], or null if absent, timed out, or the socket is not open. */
    suspend fun lookup(directId: String, timeoutMs: Long = LOOKUP_TIMEOUT_MS): String? {
        if (!_status.value.isOpen) return null
        val requestId = Encoding.newId("lk")
        val waiter = CompletableDeferred<String?>()
        lookups[requestId] = waiter
        if (!send(SignalFrame.Lookup(requestId, directId))) {
            lookups.remove(requestId)
            return null
        }
        return try {
            withTimeoutOrNull(timeoutMs) { waiter.await() }
        } finally {
            lookups.remove(requestId)
        }
    }

    /** People who opted in to be suggested on this bootstrap, or empty if the socket is not open. */
    suspend fun suggest(timeoutMs: Long = LOOKUP_TIMEOUT_MS): List<SignalFrame.SuggestedPerson> {
        if (!_status.value.isOpen) return emptyList()
        val requestId = Encoding.newId("sg")
        val waiter = CompletableDeferred<List<SignalFrame.SuggestedPerson>>()
        suggestions[requestId] = waiter
        if (!send(SignalFrame.Suggest(requestId))) {
            suggestions.remove(requestId)
            return emptyList()
        }
        return try {
            withTimeoutOrNull(timeoutMs) { waiter.await() } ?: emptyList()
        } finally {
            suggestions.remove(requestId)
        }
    }

    /**
     * Sends offer, answer, or ice. For an offer, waits briefly for `unreachable`
     * and returns false if the bootstrap reports that the peer has no live socket.
     */
    suspend fun sendNegotiation(frame: SignalFrame.Negotiation): Boolean {
        if (!_status.value.isOpen) return false
        if (frame !is SignalFrame.Offer) return send(frame)
        val waiter = CompletableDeferred<Boolean>()
        offers[frame.to] = waiter
        if (!send(frame)) {
            offers.remove(frame.to)
            return false
        }
        return try {
            withTimeoutOrNull(OFFER_UNREACHABLE_WAIT_MS) { waiter.await() } ?: true
        } finally {
            if (offers[frame.to] === waiter) offers.remove(frame.to)
        }
    }

    private fun connect() {
        val target = url
        if (!running) return
        if (target == null) {
            _status.value = BootstrapStatus(BootstrapStatus.Phase.NOT_CONFIGURED, null)
            return
        }
        val current = ++generation
        _status.value = BootstrapStatus(BootstrapStatus.Phase.CONNECTING, target)
        connection = try {
            sockets.open(target, object : WebSocketEvents {
                override fun onOpen() = post(current) { opened() }
                override fun onMessage(text: String) = post(current) { incoming(text) }
                override fun onClosed(error: String?) = post(current) { closed(error) }
            })
        } catch (error: Exception) {
            closed(error.message ?: "Could not open the socket.")
            null
        }
    }

    private fun post(expected: Int, block: () -> Unit) {
        scope.launch { if (expected == generation) block() }
    }

    private fun opened() {
        failures = 0
        _status.value = BootstrapStatus(BootstrapStatus.Phase.OPEN, url)
        sendHello()
        if (watchIds.isNotEmpty()) send(SignalFrame.Watch(watchIds))
    }

    private fun closed(error: String?) {
        connection = null
        generation++
        failPending()
        if (!running) return
        failures++
        val wait = min(MAX_RETRY_MS, 1_000L shl min(failures - 1, 5))
        _status.value = BootstrapStatus(BootstrapStatus.Phase.RETRYING, url, error ?: "The bootstrap closed the connection.")
        retryJob?.cancel()
        retryJob = scope.launch {
            delay(wait)
            retryJob = null
            connect()
        }
    }

    private fun dropConnection() {
        generation++
        connection?.close()
        connection = null
        nonce = null
        failPending()
    }

    private fun failPending() {
        lookups.values.forEach { it.complete(null) }
        lookups.clear()
        offers.values.forEach { it.complete(false) }
        offers.clear()
        suggestions.values.forEach { it.complete(emptyList()) }
        suggestions.clear()
    }

    private fun incoming(text: String) {
        when (val frame = SignalCodec.decode(text)) {
            is SignalFrame.Challenge -> {
                nonce = frame.nonce
                sendHello()
            }
            is SignalFrame.LookupResult -> lookups.remove(frame.requestId)?.complete(if (frame.present) frame.bundle else null)
            is SignalFrame.Unreachable -> offers.remove(frame.to)?.complete(false)
            is SignalFrame.Presence -> _presence.tryEmit(frame)
            is SignalFrame.Negotiation -> if (frame.to == selfId) _negotiation.tryEmit(frame)
            is SignalFrame.Suggestions -> suggestions.remove(frame.requestId)?.complete(frame.people)
            else -> Unit
        }
    }

    private fun sendHello() {
        val id = selfId ?: return
        val published = bundle ?: return
        if (!_status.value.isOpen) return
        val currentNonce = nonce
        val signer = signProof
        if (currentNonce != null && signer != null) {
            send(SignalFrame.Hello(id, published, currentNonce, signer(currentNonce), discoverable))
        } else {
            send(SignalFrame.Hello(id, published, discoverable = discoverable))
        }
    }

    private fun send(frame: SignalFrame): Boolean = connection?.send(SignalCodec.encode(frame)) ?: false

    companion object {
        const val LOOKUP_TIMEOUT_MS = 4_000L
        const val OFFER_UNREACHABLE_WAIT_MS = 500L
        const val MAX_RETRY_MS = 30_000L
    }
}

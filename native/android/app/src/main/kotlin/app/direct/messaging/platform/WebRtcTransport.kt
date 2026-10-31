package app.direct.messaging.platform

import android.content.Context
import app.direct.core.signaling.BootstrapClient
import app.direct.core.signaling.SignalFrame
import app.direct.core.transport.PeerListener
import app.direct.core.transport.PeerTransport
import java.nio.ByteBuffer
import kotlin.coroutines.resume
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import org.webrtc.DataChannel
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpReceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription

/**
 * Device-to-device data channel. Offers, answers, and ICE candidates go through the bootstrap;
 * envelope bytes only ever cross the DTLS-encrypted SCTP channel. STUN finds public addresses.
 * Two phones behind symmetric NAT (common on mobile data) also need a TURN server in [iceServers];
 * TURN relays encrypted channel bytes and cannot read them.
 * Session state is only touched on [scope] (DirectNode's single dispatcher).
 */
class WebRtcTransport(
    context: Context,
    private val bootstrap: BootstrapClient,
    private val selfId: String,
    private val scope: CoroutineScope,
    private val iceServers: List<PeerConnection.IceServer> = DEFAULT_ICE,
) : PeerTransport {
    private val factory: PeerConnectionFactory = sharedFactory(context.applicationContext)
    private val sessions = HashMap<String, Session>()
    private var listener: PeerListener? = null

    private inner class Session(val peerId: String, val opened: CompletableDeferred<Boolean>) {
        var connection: PeerConnection? = null
        var channel: DataChannel? = null
        var remoteReady = false
        val pendingIce = mutableListOf<IceCandidate>()
        val isOpen: Boolean get() = channel?.state() == DataChannel.State.OPEN
    }

    init {
        scope.launch { bootstrap.negotiation.collect { onSignal(it) } }
    }

    override fun setListener(listener: PeerListener?) {
        this.listener = listener
    }

    override fun connectedPeers(): Set<String> = sessions.values.filter { it.isOpen }.map { it.peerId }.toSet()

    override fun isConnected(peerId: String): Boolean = sessions[peerId]?.isOpen == true

    override suspend fun connect(peerId: String): Boolean {
        sessions[peerId]?.let { existing ->
            if (existing.isOpen) return true
            if (!existing.opened.isCompleted) return awaitOpen(existing)
            close(peerId)
        }
        val session = newSession(peerId, CompletableDeferred()) ?: return false
        val connection = session.connection ?: return false
        bind(session, connection.createDataChannel("direct", DataChannel.Init().apply { ordered = true }))
        val offer = connection.create(offer = true) ?: return fail(peerId)
        if (!connection.setLocal(offer)) return fail(peerId)
        if (!bootstrap.sendNegotiation(SignalFrame.Offer(peerId, selfId, offer.description))) return fail(peerId)
        return awaitOpen(session)
    }

    override suspend fun send(peerId: String, payload: ByteArray): Boolean {
        val channel = sessions[peerId]?.channel ?: return false
        if (channel.state() != DataChannel.State.OPEN) return false
        return channel.send(DataChannel.Buffer(ByteBuffer.wrap(payload.copyOf()), true))
    }

    override fun close(peerId: String) {
        val session = sessions.remove(peerId) ?: return
        session.opened.complete(false)
        session.channel?.unregisterObserver()
        session.channel?.close()
        session.connection?.close()
        session.channel?.dispose()
        session.connection?.dispose()
        listener?.onPeerClosed(peerId)
    }

    override fun closeAll() {
        sessions.keys.toList().forEach(::close)
    }

    private suspend fun awaitOpen(session: Session): Boolean {
        val ok = withTimeoutOrNull(OPEN_TIMEOUT_MS) { session.opened.await() } ?: false
        if (!ok && sessions[session.peerId] === session) close(session.peerId)
        return ok
    }

    private fun fail(peerId: String): Boolean {
        close(peerId)
        return false
    }

    private fun newSession(peerId: String, opened: CompletableDeferred<Boolean>): Session? {
        val session = Session(peerId, opened)
        val config = PeerConnection.RTCConfiguration(iceServers).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
        }
        val connection = factory.createPeerConnection(config, observer(session)) ?: return null
        session.connection = connection
        sessions[peerId] = session
        return session
    }

    private fun observer(session: Session) = object : PeerConnection.Observer {
        override fun onIceCandidate(candidate: IceCandidate) {
            scope.launch {
                if (sessions[session.peerId] !== session) return@launch
                bootstrap.sendNegotiation(SignalFrame.Ice(session.peerId, selfId, candidate.sdp, candidate.sdpMid, candidate.sdpMLineIndex))
            }
        }

        override fun onDataChannel(channel: DataChannel) {
            scope.launch { if (sessions[session.peerId] === session) bind(session, channel) }
        }

        override fun onIceConnectionChange(state: PeerConnection.IceConnectionState) {
            if (state == PeerConnection.IceConnectionState.FAILED || state == PeerConnection.IceConnectionState.CLOSED) {
                scope.launch { if (sessions[session.peerId] === session) close(session.peerId) }
            }
        }

        override fun onSignalingChange(state: PeerConnection.SignalingState) = Unit
        override fun onIceConnectionReceivingChange(receiving: Boolean) = Unit
        override fun onIceGatheringChange(state: PeerConnection.IceGatheringState) = Unit
        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>) = Unit
        override fun onAddStream(stream: MediaStream) = Unit
        override fun onRemoveStream(stream: MediaStream) = Unit
        override fun onRenegotiationNeeded() = Unit
        override fun onAddTrack(receiver: RtpReceiver, streams: Array<out MediaStream>) = Unit
    }

    private fun bind(session: Session, channel: DataChannel) {
        session.channel = channel
        channel.registerObserver(object : DataChannel.Observer {
            override fun onBufferedAmountChange(previousAmount: Long) = Unit

            override fun onStateChange() {
                val state = channel.state()
                scope.launch {
                    if (sessions[session.peerId] !== session) return@launch
                    when (state) {
                        DataChannel.State.OPEN -> {
                            session.opened.complete(true)
                            listener?.onPeerConnected(session.peerId)
                        }
                        DataChannel.State.CLOSED -> close(session.peerId)
                        else -> Unit
                    }
                }
            }

            override fun onMessage(buffer: DataChannel.Buffer) {
                val bytes = ByteArray(buffer.data.remaining()).also { buffer.data.get(it) }
                listener?.onPeerData(session.peerId, bytes)
            }
        })
    }

    private suspend fun onSignal(frame: SignalFrame.Negotiation) {
        when (frame) {
            is SignalFrame.Offer -> answer(frame)
            is SignalFrame.Answer -> {
                val session = sessions[frame.from] ?: return
                val connection = session.connection ?: return
                if (!connection.setRemote(SessionDescription(SessionDescription.Type.ANSWER, frame.sdp))) return close(frame.from)
                session.remoteReady = true
                drainIce(session)
            }
            is SignalFrame.Ice -> {
                val session = sessions[frame.from] ?: return
                val candidate = IceCandidate(frame.sdpMid ?: "0", frame.sdpMLineIndex ?: 0, frame.candidate)
                if (session.remoteReady) session.connection?.addIceCandidate(candidate) else session.pendingIce += candidate
            }
        }
    }

    private suspend fun answer(offer: SignalFrame.Offer) {
        val existing = sessions[offer.from]
        var opened = CompletableDeferred<Boolean>()
        if (existing != null) {
            // Both phones dialed at once. The lower DIRECT ID keeps its own offer; the higher one answers.
            if (!existing.isOpen && !existing.opened.isCompleted && selfId < offer.from) return
            if (!existing.opened.isCompleted) opened = existing.opened
            sessions.remove(offer.from)
            existing.channel?.unregisterObserver()
            existing.connection?.close()
            existing.connection?.dispose()
        }
        val session = newSession(offer.from, opened) ?: return
        val connection = session.connection ?: return
        if (!connection.setRemote(SessionDescription(SessionDescription.Type.OFFER, offer.sdp))) return close(offer.from)
        session.remoteReady = true
        drainIce(session)
        val answer = connection.create(offer = false) ?: return close(offer.from)
        if (!connection.setLocal(answer)) return close(offer.from)
        bootstrap.sendNegotiation(SignalFrame.Answer(offer.from, selfId, answer.description))
        scope.launch { awaitOpen(session) }
    }

    private fun drainIce(session: Session) {
        val connection = session.connection ?: return
        session.pendingIce.forEach { connection.addIceCandidate(it) }
        session.pendingIce.clear()
    }

    private suspend fun PeerConnection.create(offer: Boolean): SessionDescription? = suspendCancellableCoroutine { done ->
        val observer = object : SdpObserver {
            override fun onCreateSuccess(description: SessionDescription) = done.resume(description)
            override fun onCreateFailure(error: String?) = done.resume(null)
            override fun onSetSuccess() = Unit
            override fun onSetFailure(error: String?) = Unit
        }
        if (offer) createOffer(observer, MediaConstraints()) else createAnswer(observer, MediaConstraints())
    }

    private suspend fun PeerConnection.setLocal(description: SessionDescription): Boolean = setDescription(description, local = true)

    private suspend fun PeerConnection.setRemote(description: SessionDescription): Boolean = setDescription(description, local = false)

    private suspend fun PeerConnection.setDescription(description: SessionDescription, local: Boolean): Boolean =
        suspendCancellableCoroutine { done ->
            val observer = object : SdpObserver {
                override fun onCreateSuccess(description: SessionDescription) = Unit
                override fun onCreateFailure(error: String?) = Unit
                override fun onSetSuccess() = done.resume(true)
                override fun onSetFailure(error: String?) = done.resume(false)
            }
            if (local) setLocalDescription(observer, description) else setRemoteDescription(observer, description)
        }

    companion object {
        const val OPEN_TIMEOUT_MS = 12_000L

        val DEFAULT_ICE: List<PeerConnection.IceServer> = listOf(
            PeerConnection.IceServer.builder(listOf("stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302")).createIceServer(),
        )

        @Volatile
        private var factory: PeerConnectionFactory? = null

        @Synchronized
        private fun sharedFactory(context: Context): PeerConnectionFactory = factory ?: run {
            PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions.builder(context).createInitializationOptions())
            PeerConnectionFactory.builder().createPeerConnectionFactory().also { factory = it }
        }
    }
}

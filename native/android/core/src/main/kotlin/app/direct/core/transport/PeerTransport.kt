package app.direct.core.transport

import app.direct.core.delivery.PeerLinks

/** Callbacks may arrive on any thread. DirectNode hops onto its own dispatcher. */
interface PeerListener {
    fun onPeerConnected(peerId: String)
    fun onPeerData(peerId: String, payload: ByteArray)
    fun onPeerClosed(peerId: String)
}

/**
 * A direct device-to-device channel. On Android and iOS this is a WebRTC data channel
 * negotiated through [app.direct.core.signaling.BootstrapClient]; envelope bytes never
 * pass through the bootstrap.
 */
interface PeerTransport : PeerLinks {
    fun setListener(listener: PeerListener?)
    fun connectedPeers(): Set<String>
    fun close(peerId: String)
    fun closeAll()
}

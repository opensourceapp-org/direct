import Foundation

/// Callbacks run on `DirectActor`; platform transports hop there before calling.
@DirectActor
public protocol PeerListener: AnyObject {
    func onPeerConnected(_ peerId: String)
    func onPeerData(_ peerId: String, _ payload: Data)
    func onPeerClosed(_ peerId: String)
}

/// A direct device-to-device channel. On iOS and Android this is a WebRTC data channel
/// negotiated through `BootstrapClient`; envelope bytes never pass through the bootstrap.
@DirectActor
public protocol PeerTransport: PeerLinks {
    func setListener(_ listener: PeerListener?)
    func connectedPeers() -> Set<String>
    func close(_ peerId: String)
    func closeAll()
}

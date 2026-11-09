import DirectCore
import Foundation
import WebRTC

/// Device-to-device data channel. Offers, answers, and ICE candidates go through the bootstrap;
/// envelope bytes only ever cross the DTLS-encrypted SCTP channel. STUN finds public addresses.
/// Two phones behind symmetric NAT (common on mobile data) also need a TURN server in `iceServers`;
/// TURN relays encrypted channel bytes and cannot read them.
@DirectActor
final class WebRTCTransport: PeerTransport {
    /// STUN URLs only. Safe to read from call media, which is not on DirectActor.
    nonisolated static var defaultIceServers: [RTCIceServer] {
        [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"])]
    }
    nonisolated static let openTimeoutMs: Int64 = 12_000

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    private let bootstrap: BootstrapClient
    private let selfId: String
    private let iceServers: [RTCIceServer]
    private var sessions: [String: Session] = [:]
    private weak var listener: PeerListener?

    init(bootstrap: BootstrapClient, selfId: String, iceServers: [RTCIceServer]? = nil) {
        self.bootstrap = bootstrap
        self.selfId = selfId
        self.iceServers = iceServers ?? WebRTCTransport.defaultIceServers
        bootstrap.onNegotiation = { [weak self] frame in
            Task { @DirectActor in await self?.onSignal(frame) }
        }
    }

    func setListener(_ listener: PeerListener?) { self.listener = listener }

    func connectedPeers() -> Set<String> { Set(sessions.values.filter(\.isOpen).map(\.peerId)) }

    func isConnected(_ peerId: String) -> Bool { sessions[peerId]?.isOpen == true }

    func connect(_ peerId: String) async -> Bool {
        if let existing = sessions[peerId] {
            if existing.isOpen { return true }
            if !existing.opened.isCompleted { return await awaitOpen(existing) }
            close(peerId)
        }
        guard let session = newSession(peerId, opened: Waiter()), let connection = session.connection else { return false }
        let config = RTCDataChannelConfiguration()
        config.isOrdered = true
        guard let channel = connection.dataChannel(forLabel: "direct", configuration: config) else { return fail(peerId) }
        bind(session, channel)
        guard let offer = await connection.create(offer: true), await connection.setLocal(offer) else { return fail(peerId) }
        guard await bootstrap.sendNegotiation(.offer(to: peerId, from: selfId, sdp: offer.sdp)) else { return fail(peerId) }
        return await awaitOpen(session)
    }

    func send(_ peerId: String, _ payload: Data) async -> Bool {
        guard let channel = sessions[peerId]?.channel, channel.readyState == .open else { return false }
        return channel.sendData(RTCDataBuffer(data: payload, isBinary: true))
    }

    func close(_ peerId: String) {
        guard let session = sessions.removeValue(forKey: peerId) else { return }
        session.opened.complete(false)
        session.channel?.delegate = nil
        session.channel?.close()
        session.connection?.close()
        listener?.onPeerClosed(peerId)
    }

    func closeAll() {
        sessions.keys.forEach(close)
    }

    private func awaitOpen(_ session: Session) async -> Bool {
        let ok = await session.opened.wait(timeoutMs: Self.openTimeoutMs, fallback: false)
        if !ok, sessions[session.peerId] === session { close(session.peerId) }
        return ok
    }

    private func fail(_ peerId: String) -> Bool {
        close(peerId)
        return false
    }

    private func newSession(_ peerId: String, opened: Waiter<Bool>) -> Session? {
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        let session = Session(transport: self, peerId: peerId, opened: opened)
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = Self.factory.peerConnection(with: config, constraints: constraints, delegate: session) else { return nil }
        session.connection = connection
        sessions[peerId] = session
        return session
    }

    private func bind(_ session: Session, _ channel: RTCDataChannel) {
        session.channel = channel
        channel.delegate = session
    }

    private func onSignal(_ frame: SignalFrame) async {
        switch frame {
        case let .offer(_, from, sdp):
            await answer(from: from, sdp: sdp)
        case let .answer(_, from, sdp):
            guard let session = sessions[from], let connection = session.connection else { return }
            guard await connection.setRemote(RTCSessionDescription(type: .answer, sdp: sdp)) else { return close(from) }
            session.remoteReady = true
            drainIce(session)
        case let .ice(_, from, candidate, sdpMid, sdpMLineIndex):
            guard let session = sessions[from] else { return }
            let ice = RTCIceCandidate(sdp: candidate, sdpMLineIndex: Int32(sdpMLineIndex ?? 0), sdpMid: sdpMid ?? "0")
            if session.remoteReady { session.connection?.add(ice) { _ in } } else { session.pendingIce.append(ice) }
        default:
            break
        }
    }

    private func answer(from peerId: String, sdp: String) async {
        var opened = Waiter<Bool>()
        if let existing = sessions[peerId] {
            // Both phones dialed at once. The lower DIRECT ID keeps its own offer; the higher one answers.
            if !existing.isOpen, !existing.opened.isCompleted, selfId < peerId { return }
            if !existing.opened.isCompleted { opened = existing.opened }
            sessions[peerId] = nil
            existing.channel?.delegate = nil
            existing.connection?.close()
        }
        guard let session = newSession(peerId, opened: opened), let connection = session.connection else { return }
        guard await connection.setRemote(RTCSessionDescription(type: .offer, sdp: sdp)) else { return close(peerId) }
        session.remoteReady = true
        drainIce(session)
        guard let answer = await connection.create(offer: false), await connection.setLocal(answer) else { return close(peerId) }
        _ = await bootstrap.sendNegotiation(.answer(to: peerId, from: selfId, sdp: answer.sdp))
        Task { @DirectActor in _ = await self.awaitOpen(session) }
    }

    private func drainIce(_ session: Session) {
        session.pendingIce.forEach { session.connection?.add($0) { _ in } }
        session.pendingIce.removeAll()
    }

    fileprivate func iceGenerated(_ session: Session, _ candidate: RTCIceCandidate) async {
        guard sessions[session.peerId] === session else { return }
        _ = await bootstrap.sendNegotiation(.ice(
            to: session.peerId, from: selfId, candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: Int(candidate.sdpMLineIndex)
        ))
    }

    fileprivate func channelOpened(_ session: Session, _ channel: RTCDataChannel) {
        guard sessions[session.peerId] === session else { return }
        if session.channel !== channel { bind(session, channel) }
        if channel.readyState == .open {
            session.opened.complete(true)
            listener?.onPeerConnected(session.peerId)
        }
    }

    fileprivate func channelStateChanged(_ session: Session, _ state: RTCDataChannelState) {
        guard sessions[session.peerId] === session else { return }
        switch state {
        case .open:
            session.opened.complete(true)
            listener?.onPeerConnected(session.peerId)
        case .closed:
            close(session.peerId)
        default:
            break
        }
    }

    fileprivate func iceStateChanged(_ session: Session, _ state: RTCIceConnectionState) {
        guard sessions[session.peerId] === session, state == .failed || state == .closed else { return }
        close(session.peerId)
    }

    fileprivate func received(_ session: Session, _ data: Data) {
        guard sessions[session.peerId] === session else { return }
        listener?.onPeerData(session.peerId, data)
    }

    /// WebRTC calls these delegates on its own threads; every callback hops onto DirectActor.
    fileprivate final class Session: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
        weak var transport: WebRTCTransport?
        let peerId: String
        let opened: Waiter<Bool>
        var connection: RTCPeerConnection?
        var channel: RTCDataChannel?
        var remoteReady = false
        var pendingIce: [RTCIceCandidate] = []

        var isOpen: Bool { channel?.readyState == .open }

        init(transport: WebRTCTransport, peerId: String, opened: Waiter<Bool>) {
            self.transport = transport
            self.peerId = peerId
            self.opened = opened
        }

        private func hop(_ body: @escaping @DirectActor (WebRTCTransport, Session) async -> Void) {
            Task { @DirectActor [weak self] in
                guard let self, let transport = self.transport else { return }
                await body(transport, self)
            }
        }

        func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
            hop { await $0.iceGenerated($1, candidate) }
        }

        func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
            hop { $0.channelOpened($1, dataChannel) }
        }

        func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
            hop { $0.iceStateChanged($1, newState) }
        }

        func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
            let state = dataChannel.readyState
            hop { $0.channelStateChanged($1, state) }
        }

        func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
            let data = buffer.data
            hop { $0.received($1, data) }
        }

        func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
        func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    }
}

private extension RTCPeerConnection {
    func create(offer: Bool) async -> RTCSessionDescription? {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        do {
            if offer { return try await self.offer(for: constraints) }
            return try await self.answer(for: constraints)
        } catch {
            return nil
        }
    }

    func setLocal(_ description: RTCSessionDescription) async -> Bool {
        do {
            try await setLocalDescription(description)
            return true
        } catch {
            return false
        }
    }

    func setRemote(_ description: RTCSessionDescription) async -> Bool {
        do {
            try await setRemoteDescription(description)
            return true
        } catch {
            return false
        }
    }
}

import Foundation
@testable import DirectCore

enum Contracts {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("contracts")

    static func json(_ name: String) -> JSON {
        let text = try! String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
        return JSON.parse(text)!
    }
}

/// In-memory bootstrap with the rules of infrastructure/signaling/hub.cjs. Records every frame it receives.
/// Events are delivered asynchronously, like a real socket.
final class FakeHub: WebSocketFactory {
    var reachable = true
    private(set) var received: [String] = []
    private var live: [String: Socket] = [:]
    private var bundles: [String: String] = [:]
    private var discoverable: [String: Bool] = [:]
    private var intros: [String: Bool] = [:]
    private var watching: [ObjectIdentifier: (Socket, Set<String>)] = [:]
    private var sockets: [Socket] = []
    private let lock = NSRecursiveLock()

    final class Socket: WebSocketConnection {
        weak var hub: FakeHub?
        let events: WebSocketEvents
        var selfId: String?
        var open = true

        init(hub: FakeHub, events: WebSocketEvents) {
            self.hub = hub
            self.events = events
        }

        func send(_ text: String) -> Bool {
            guard let hub, open else { return false }
            hub.handle(self, text)
            return true
        }

        func close() {
            guard open else { return }
            open = false
            hub?.dropped(self)
        }
    }

    func open(url: String, events: WebSocketEvents) throws -> WebSocketConnection {
        let socket = Socket(hub: self, events: events)
        lock.lock()
        sockets.append(socket)
        lock.unlock()
        if reachable {
            events.onOpen()
        } else {
            socket.open = false
            events.onClosed("connection refused")
        }
        return socket
    }

    /// Server restarts or the network drops: every socket closes.
    func dropAll() {
        lock.lock()
        let all = sockets
        lock.unlock()
        for socket in all where socket.open {
            socket.open = false
            dropped(socket)
            socket.events.onClosed("network lost")
        }
    }

    func isOnline(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return live[id]?.open == true
    }

    func frames() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    private func dropped(_ socket: Socket) {
        lock.lock()
        watching[ObjectIdentifier(socket)] = nil
        var wentOffline: String?
        if let id = socket.selfId, live[id] === socket {
            live[id] = nil
            wentOffline = id
        }
        lock.unlock()
        if let wentOffline { notify(wentOffline, false) }
    }

    private func canSeePresence(_ watcher: String?, _ id: String) -> Bool {
        guard let watcher else { return false }
        if discoverable[id] == true { return true }
        return intros["\(id)\n\(watcher)"] == true
    }

    private func notify(_ id: String, _ online: Bool) {
        lock.lock()
        let targets = watching.values.filter { $0.1.contains(id) && $0.0.open && canSeePresence($0.0.selfId, id) }.map(\.0)
        lock.unlock()
        let frame = SignalCodec.encode(.presence(directId: id, online: online))
        targets.forEach { $0.events.onMessage(frame) }
    }

    private func handle(_ socket: Socket, _ text: String) {
        lock.lock()
        received.append(text)
        lock.unlock()
        guard let frame = SignalCodec.decode(text) else { return }
        switch frame {
        case let .hello(from, bundle, _, _, listed):
            guard DirectIds.isValid(from), bundle.contains("\"directId\":\"\(from)\"") else { return }
            let wasOnline = isOnline(from)
            lock.lock()
            socket.selfId = from
            live[from] = socket
            bundles[from] = bundle
            discoverable[from] = listed
            lock.unlock()
            if !wasOnline { notify(from, true) }
        case let .lookup(requestId, directId):
            lock.lock()
            let bundle = bundles[directId]
            let listed = discoverable[directId] == true
            let introduced = socket.selfId.map { intros["\(directId)\n\($0)"] == true } ?? false
            let shown = socket.selfId != nil && bundle != nil && (listed || introduced)
            lock.unlock()
            socket.events.onMessage(SignalCodec.encode(.lookupResult(requestId: requestId, directId: directId, present: shown, bundle: shown ? bundle : nil)))
        case let .watch(ids):
            lock.lock()
            watching[ObjectIdentifier(socket)] = (socket, Set(ids))
            let watcher = socket.selfId
            let presence = ids.map { id in (id, canSeePresence(watcher, id) && isOnline(id)) }
            lock.unlock()
            for (id, online) in presence {
                socket.events.onMessage(SignalCodec.encode(.presence(directId: id, online: online)))
            }
        case .offer, .answer, .ice:
            guard let route = frame.route, route.from == socket.selfId else { return }
            lock.lock()
            intros["\(route.from)\n\(route.to)"] = true
            let target = live[route.to]
            let fromOnline = isOnline(route.from)
            lock.unlock()
            notify(route.from, fromOnline)
            if let target, target.open {
                target.events.onMessage(text)
            } else if case .offer = frame {
                socket.events.onMessage(SignalCodec.encode(.unreachable(to: route.to)))
            }
        case let .suggest(requestId):
            lock.lock()
            let except = socket.selfId
            let people = live.compactMap { id, peer -> SuggestedPerson? in
                guard peer.open, id != except, discoverable[id] == true, let bundle = bundles[id] else { return nil }
                return SuggestedPerson(directId: id, name: Self.displayName(bundle), bundle: bundle, online: true)
            }
            .sorted { ($0.name.isEmpty ? $0.directId : $0.name) < ($1.name.isEmpty ? $1.directId : $1.name) }
            lock.unlock()
            socket.events.onMessage(SignalCodec.encode(.suggestions(requestId: requestId, people: people)))
        default:
            break
        }
    }

    private static func displayName(_ bundle: String) -> String {
        let name = JSON.parse(bundle)?["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return String(name.prefix(80))
    }
}

/// Stands in for WebRTC. A link opens only when both devices are reachable,
/// and it is negotiated through each device's bootstrap so presence matters.
@DirectActor
final class FakePeerNetwork {
    private var transports: [String: Transport] = [:]
    var offline = Set<String>()

    func transport(_ bootstrap: BootstrapClient, _ selfId: String) -> PeerTransport {
        let created = Transport(network: self, selfId: selfId, bootstrap: bootstrap)
        transports[selfId] = created
        return created
    }

    final class Transport: PeerTransport {
        weak var network: FakePeerNetwork?
        let selfId: String
        let bootstrap: BootstrapClient
        weak var listener: PeerListener?
        var links = Set<String>()

        init(network: FakePeerNetwork, selfId: String, bootstrap: BootstrapClient) {
            self.network = network
            self.selfId = selfId
            self.bootstrap = bootstrap
        }

        func setListener(_ listener: PeerListener?) { self.listener = listener }
        func connectedPeers() -> Set<String> { links }
        func isConnected(_ peerId: String) -> Bool { links.contains(peerId) }

        func connect(_ peerId: String) async -> Bool {
            guard let network, !network.offline.contains(selfId), !network.offline.contains(peerId), bootstrap.status.isOpen else { return false }
            let reachable = await bootstrap.sendNegotiation(.offer(to: peerId, from: selfId, sdp: "v=0"))
            // The offer wait can outlive the other phone. A forwarded offer is not a live link.
            guard reachable, let remote = network.transports[peerId], remote.bootstrap.status.isOpen else { return false }
            links.insert(peerId)
            remote.links.insert(selfId)
            listener?.onPeerConnected(peerId)
            remote.listener?.onPeerConnected(selfId)
            return true
        }

        func send(_ peerId: String, _ payload: Data) async -> Bool {
            guard let network, links.contains(peerId), !network.offline.contains(selfId), !network.offline.contains(peerId),
                  let remote = network.transports[peerId]?.listener
            else { return false }
            remote.onPeerData(selfId, payload)
            return true
        }

        func close(_ peerId: String) {
            if links.remove(peerId) != nil { listener?.onPeerClosed(peerId) }
        }

        func closeAll() {
            for peer in links {
                close(peer)
                network?.transports[peer]?.close(selfId)
            }
        }
    }
}

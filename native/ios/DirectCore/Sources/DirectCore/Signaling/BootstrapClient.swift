import Foundation

/// Platform WebSocket: URLSessionWebSocketTask on iOS, OkHttp on Android, fakes in tests.
public protocol WebSocketFactory: AnyObject {
    func open(url: String, events: WebSocketEvents) throws -> WebSocketConnection
}

public protocol WebSocketConnection: AnyObject {
    @discardableResult func send(_ text: String) -> Bool
    func close()
}

/// May be called from any thread. The client hops onto `DirectActor`.
public protocol WebSocketEvents: AnyObject {
    func onOpen()
    func onMessage(_ text: String)
    func onClosed(_ error: String?)
}

public struct BootstrapStatus: Equatable, Sendable {
    public enum Phase: String, Sendable { case notConfigured, connecting, open, retrying, stopped }

    public var phase: Phase
    public var url: String?
    public var error: String?

    public init(phase: Phase, url: String?, error: String? = nil) {
        self.phase = phase
        self.url = url
        self.error = error
    }

    public var isOpen: Bool { phase == .open }
}

/// One socket to the bootstrap. Announces this device's public bundle on every open,
/// keeps a watch list for presence, answers lookups, and carries WebRTC negotiation.
/// Reconnects with backoff (1s doubling to 30s). `reconnectNow()` skips the wait, for
/// app foreground and network changes.
@DirectActor
public final class BootstrapClient {
    public struct Timing {
        public var lookupTimeoutMs: Int64 = 4_000
        public var offerUnreachableWaitMs: Int64 = 500
        public var retryBaseMs: Int64 = 1_000
        public var maxRetryMs: Int64 = 30_000
        public init() {}
    }

    public private(set) var status = BootstrapStatus(phase: .notConfigured, url: nil) {
        didSet {
            guard status != oldValue else { return }
            statusHandlers.forEach { $0(status) }
            if status.isOpen {
                let waiting = openWaiters
                openWaiters = []
                waiting.forEach { $0.complete(true) }
            }
        }
    }

    /// Set by the peer transport. Only frames addressed to this device are delivered.
    public var onNegotiation: ((SignalFrame) -> Void)?
    public var onPresence: ((String, Bool) -> Void)?
    private var statusHandlers: [(BootstrapStatus) -> Void] = []

    public private(set) var url: String?
    private let sockets: WebSocketFactory
    private let timing: Timing
    private var running = false
    private var selfId: String?
    private var bundle: String?
    private var watchIds: [String] = []
    private var connection: WebSocketConnection?
    private var generation = 0
    private var failures = 0
    private var retryTask: Task<Void, Never>?
    private var lookups: [String: Waiter<String?>] = [:]
    private var offers: [String: Waiter<Bool>] = [:]
    private var openWaiters: [Waiter<Bool>] = []

    public init(sockets: WebSocketFactory, timing: Timing = Timing()) {
        self.sockets = sockets
        self.timing = timing
    }

    public func addStatusHandler(_ handler: @escaping (BootstrapStatus) -> Void) {
        statusHandlers.append(handler)
    }

    public func configure(_ newUrl: String?) {
        if newUrl == url, connection != nil { return }
        url = newUrl
        reconnectNow()
    }

    public func start() {
        running = true
        if connection == nil, retryTask == nil { connect() }
    }

    public func stop() {
        running = false
        retryTask?.cancel()
        retryTask = nil
        dropConnection()
        status = BootstrapStatus(phase: .stopped, url: url)
    }

    public func reconnectNow() {
        failures = 0
        retryTask?.cancel()
        retryTask = nil
        dropConnection()
        if running { connect() }
    }

    public func announce(directId: String, bundle publicBundle: String) {
        selfId = directId
        bundle = publicBundle
        sendHello()
    }

    public func watch(_ ids: [String]) {
        var seen = Set<String>()
        let next = Array(ids.filter { seen.insert($0).inserted }.prefix(SignalCodec.maxWatch))
        guard next != watchIds else { return }
        watchIds = next
        if status.isOpen { send(.watch(ids: watchIds)) }
    }

    /// True once the socket is open, false after `timeoutMs`.
    public func waitUntilOpen(timeoutMs: Int64) async -> Bool {
        if status.isOpen { return true }
        let waiter = Waiter<Bool>()
        openWaiters.append(waiter)
        let opened = await waiter.wait(timeoutMs: timeoutMs, fallback: false)
        openWaiters.removeAll { $0 === waiter }
        return opened && status.isOpen
    }

    /// The published bundle for `directId`, or nil if absent, timed out, or the socket is not open.
    public func lookup(_ directId: String, timeoutMs: Int64? = nil) async -> String? {
        guard status.isOpen else { return nil }
        let requestId = Encoding.newId("lk")
        let waiter = Waiter<String?>()
        lookups[requestId] = waiter
        guard send(.lookup(requestId: requestId, directId: directId)) else {
            lookups[requestId] = nil
            return nil
        }
        let result = await waiter.wait(timeoutMs: timeoutMs ?? timing.lookupTimeoutMs, fallback: nil)
        lookups[requestId] = nil
        return result
    }

    /// Sends offer, answer, or ice. For an offer, waits briefly for `unreachable`
    /// and returns false if the bootstrap reports that the peer has no live socket.
    public func sendNegotiation(_ frame: SignalFrame) async -> Bool {
        guard status.isOpen, let route = frame.route else { return false }
        guard case .offer = frame else { return send(frame) }
        let waiter = Waiter<Bool>()
        offers[route.to] = waiter
        guard send(frame) else {
            offers[route.to] = nil
            return false
        }
        let reachable = await waiter.wait(timeoutMs: timing.offerUnreachableWaitMs, fallback: true)
        if offers[route.to] === waiter { offers[route.to] = nil }
        return reachable
    }

    private func connect() {
        guard running else { return }
        guard let target = url else {
            status = BootstrapStatus(phase: .notConfigured, url: nil)
            return
        }
        generation += 1
        let current = generation
        status = BootstrapStatus(phase: .connecting, url: target)
        do {
            connection = try sockets.open(url: target, events: Events(client: self, generation: current))
        } catch {
            closed("Could not open the socket: \(error)")
        }
    }

    private final class Events: WebSocketEvents {
        weak var client: BootstrapClient?
        let generation: Int

        init(client: BootstrapClient, generation: Int) {
            self.client = client
            self.generation = generation
        }

        func onOpen() { post { $0.opened() } }
        func onMessage(_ text: String) { post { $0.incoming(text) } }
        func onClosed(_ error: String?) { post { $0.closed(error) } }

        private func post(_ block: @escaping @DirectActor (BootstrapClient) -> Void) {
            let expected = generation
            Task { @DirectActor [weak client] in
                guard let client, client.generation == expected else { return }
                block(client)
            }
        }
    }

    private func opened() {
        failures = 0
        status = BootstrapStatus(phase: .open, url: url)
        sendHello()
        if !watchIds.isEmpty { send(.watch(ids: watchIds)) }
    }

    private func closed(_ error: String?) {
        connection = nil
        generation += 1
        failPending()
        guard running else { return }
        failures += 1
        let wait = min(timing.maxRetryMs, timing.retryBaseMs << Int64(min(failures - 1, 5)))
        status = BootstrapStatus(phase: .retrying, url: url, error: error ?? "The bootstrap closed the connection.")
        retryTask?.cancel()
        retryTask = Task { @DirectActor [weak self] in
            await sleepMs(wait)
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.connect()
        }
    }

    private func dropConnection() {
        generation += 1
        connection?.close()
        connection = nil
        failPending()
    }

    private func failPending() {
        lookups.values.forEach { $0.complete(nil) }
        lookups = [:]
        offers.values.forEach { $0.complete(false) }
        offers = [:]
    }

    private func incoming(_ text: String) {
        guard let frame = SignalCodec.decode(text) else { return }
        switch frame {
        case let .lookupResult(requestId, _, present, bundle):
            lookups.removeValue(forKey: requestId)?.complete(present ? bundle : nil)
        case let .unreachable(to):
            offers.removeValue(forKey: to)?.complete(false)
        case let .presence(directId, online):
            onPresence?(directId, online)
        case .offer, .answer, .ice:
            if frame.route?.to == selfId { onNegotiation?(frame) }
        default:
            break
        }
    }

    private func sendHello() {
        guard let selfId, let bundle, status.isOpen else { return }
        send(.hello(from: selfId, bundle: bundle))
    }

    @discardableResult
    private func send(_ frame: SignalFrame) -> Bool {
        connection?.send(SignalCodec.encode(frame)) ?? false
    }
}

import DirectCore
import Foundation

/// The bootstrap socket. Only signaling frames travel here: hello, lookup, watch, offer, answer, ice.
/// Hosted wss:// hubs use HTTPS POST /signal; LAN ws:// hubs use a WebSocket.
final class URLSessionSocketFactory: WebSocketFactory {
    func open(url: String, events: WebSocketEvents) throws -> WebSocketConnection {
        if BootstrapUrl.usesHttpSignal(url) {
            guard let target = URL(string: BootstrapUrl.httpSignalUrl(url)) else { throw URLError(.badURL) }
            return HttpSignalConnection(url: target, events: events)
        }
        guard let target = URL(string: url) else { throw URLError(.badURL) }
        return URLSessionSocket(url: target, events: events)
    }
}

final class HttpSignalConnection: WebSocketConnection {
    private let endpoint: URL
    private let events: WebSocketEvents
    private let lock = NSLock()
    private var finished = false
    private var session: String?
    private var token: String?
    private var outgoing: [String] = []
    private var wake = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "app.direct.http-signal")

    init(url: URL, events: WebSocketEvents) {
        self.endpoint = url
        self.events = events
        queue.async { [weak self] in self?.run() }
    }

    func send(_ text: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        outgoing.append(text)
        wake.signal()
        return true
    }

    func close() {
        lock.lock()
        finished = true
        lock.unlock()
        wake.signal()
    }

    private func run() {
        events.onOpen()
        while true {
            lock.lock()
            let stopped = finished
            let frames = outgoing
            outgoing = []
            lock.unlock()
            if stopped { return }
            let waitMs = frames.isEmpty ? 2_000 : 0
            var body: [String: Any] = ["waitMs": waitMs, "frames": frames.compactMap { Self.object(from: $0) }]
            if let session { body["session"] = session }
            if let token { body["token"] = token }
            do {
                var request = URLRequest(url: endpoint, timeoutInterval: 25)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if let session { request.setValue(session, forHTTPHeaderField: "X-Direct-Session") }
                if let token { request.setValue(token, forHTTPHeaderField: "X-Direct-Token") }
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let group = DispatchGroup()
                group.enter()
                var payload: [String: Any]?
                var failure: String?
                URLSession.shared.dataTask(with: request) { data, response, error in
                    defer { group.leave() }
                    if let error {
                        failure = error.localizedDescription
                        return
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200...299).contains(status), let data,
                          let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        failure = "The bootstrap closed the connection."
                        return
                    }
                    payload = parsed
                }.resume()
                group.wait()
                if let failure {
                    finish(failure)
                    return
                }
                if let id = payload?["session"] as? String { session = id }
                if let issued = payload?["token"] as? String, !issued.isEmpty { token = issued }
                let inbound = payload?["frames"] as? [Any] ?? []
                for frame in inbound {
                    guard JSONSerialization.isValidJSONObject(frame),
                          let data = try? JSONSerialization.data(withJSONObject: frame),
                          let text = String(data: data, encoding: .utf8) else { continue }
                    events.onMessage(text)
                }
            } catch {
                finish(error.localizedDescription)
                return
            }
        }
    }

    private func finish(_ error: String) {
        lock.lock()
        let already = finished
        finished = true
        lock.unlock()
        guard !already else { return }
        events.onClosed(error)
    }

    private static func object(from text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

final class URLSessionSocket: NSObject, WebSocketConnection, URLSessionWebSocketDelegate {
    private let events: WebSocketEvents
    private let lock = NSLock()
    private var finished = false
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!
    private var pingTimer: DispatchSourceTimer?

    init(url: URL, events: WebSocketEvents) {
        self.events = events
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 80 * 1024
        task.resume()
        receive()
    }

    func send(_ text: String) -> Bool {
        lock.lock()
        let open = !finished
        lock.unlock()
        guard open else { return false }
        task.send(.string(text)) { [weak self] error in
            if let error { self?.finish(error.localizedDescription) }
        }
        return true
    }

    func close() {
        guard markFinished() else { return }
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        startPing()
        events.onOpen()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish("The bootstrap closed the connection.")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error?.localizedDescription ?? "The bootstrap closed the connection.")
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(.string(text)):
                self.events.onMessage(text)
                self.receive()
            case let .success(.data(data)):
                self.events.onMessage(String(decoding: data, as: UTF8.self))
                self.receive()
            case let .failure(error):
                self.finish(error.localizedDescription)
            @unknown default:
                self.receive()
            }
        }
    }

    /// Keeps NAT mappings alive and notices a dead socket within about 20 seconds.
    private func startPing() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in
            self?.task.sendPing { error in
                if let error { self?.finish(error.localizedDescription) }
            }
        }
        timer.resume()
        pingTimer = timer
    }

    private func markFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        pingTimer?.cancel()
        pingTimer = nil
        return true
    }

    private func finish(_ error: String) {
        guard markFinished() else { return }
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        events.onClosed(error)
    }
}

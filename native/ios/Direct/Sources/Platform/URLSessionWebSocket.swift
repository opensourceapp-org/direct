import DirectCore
import Foundation

/// The bootstrap socket. Only signaling frames travel here: hello, lookup, watch, offer, answer, ice.
final class URLSessionSocketFactory: WebSocketFactory {
    func open(url: String, events: WebSocketEvents) throws -> WebSocketConnection {
        guard let target = URL(string: url) else { throw URLError(.badURL) }
        return URLSessionSocket(url: target, events: events)
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

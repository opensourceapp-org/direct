import DirectCore
import SwiftUI
import UIKit

/// Main-actor mirror of `NodeState` for SwiftUI. Every action runs on `DirectActor`.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state = NodeState()
    @Published var toast: String?
    @Published var newPhrase: String?

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        Task { @DirectActor in
            let node = Runtime.shared.node
            node.onState = { state in
                Task { @MainActor in self.state = state }
            }
            await node.start()
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            Task { @DirectActor in Runtime.shared.node.onForeground() }
        case .background:
            let pending = state.pending
            Task { @DirectActor in Runtime.shared.node.onBackground() }
            if pending > 0 {
                BackgroundDelivery.flushBeforeSuspension()
                BackgroundDelivery.schedule()
            }
        default:
            break
        }
    }

    /// Runs `action` on the node and shows its error message, if any, as a toast.
    func run(_ action: @escaping @DirectActor (DirectNode) async throws -> Void) {
        Task { @DirectActor in
            do {
                try await action(Runtime.shared.node)
            } catch {
                let text = (error as? DirectError)?.message ?? String(describing: error)
                await MainActor.run { self.toast = text }
            }
        }
    }

    func createIdentity(name: String) {
        run { node in
            let phrase = try node.createIdentity(name)
            await MainActor.run { self.newPhrase = phrase }
        }
    }

    func restoreIdentity(phrase: String, name: String) {
        run { try $0.restoreIdentity(phrase, displayName: name) }
    }

    func setBootstrap(_ input: String) {
        run { node in
            let url = try node.setBootstrap(input)
            await MainActor.run { self.toast = "Bootstrap set to \(url). Use this exact address on the other phone." }
        }
    }

    func addContact(_ input: String, done: @escaping @MainActor () -> Void) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        run { node in
            if trimmed.hasPrefix("{") { try node.addContactBundle(trimmed) } else { try await node.addContact(trimmed) }
            await MainActor.run { done() }
        }
    }

    func send(_ peerId: String, _ body: String) { run { try $0.send(peerId, body) } }
    func open(_ peerId: String) { run { try $0.openConversation(peerId) } }
    func retry(_ messageId: String) { run { try $0.retry(messageId) } }
    func accept(_ peerId: String) { run { try $0.acceptRequest(peerId) } }
    func decline(_ peerId: String) { run { try $0.declineRequest(peerId) } }
    func remove(_ peerId: String) { run { try $0.removeContact(peerId) } }
    func setVerified(_ peerId: String, _ verified: Bool) { run { try $0.setVerified(peerId, verified) } }
    func reconnect() { run { $0.onNetworkAvailable() } }

    func showPhrase() {
        run { node in
            let phrase = try node.recoveryPhrase()
            await MainActor.run { self.newPhrase = phrase }
        }
    }

    func copy(_ text: String, label: String) {
        UIPasteboard.general.string = text
        toast = "\(label) copied."
    }
}

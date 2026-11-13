import AVFoundation
import DirectCore
import SwiftUI
import UIKit

/// Main-actor mirror of `NodeState` for SwiftUI. Every action runs on `DirectActor`.
enum HomeTab: Hashable {
    case chats, contacts, feed, profile
}

@MainActor
final class AppModel: ObservableObject {
    static weak var shared: AppModel?

    @Published private(set) var state = NodeState()
    @Published var toast: String?
    @Published var newPhrase: String?
    @Published var showIntro = false
    @Published var tab: HomeTab = .chats
    @Published var chatPath: [String] = []

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        AppModel.shared = self
        _ = CallSession.shared
        Task { @DirectActor in
            let node = Runtime.shared.node
            node.onCallEvent = { event in
                DispatchQueue.main.async { CallSession.shared.handle(event) }
            }
            node.onInboundAlert = { alert in
                DispatchQueue.main.async { MessageAlerts.show(alert) }
            }
            node.onState = { state in
                Task { @MainActor in
                    self.state = state
                    let unread = state.conversations.reduce(0) { $0 + $1.unread }
                    MessageAlerts.setBadge(MessageAlerts.uiVisible ? 0 : unread)
                }
            }
            await node.start()
        }
    }

    func openChat(_ peerId: String) {
        tab = .chats
        chatPath = [peerId]
        MessageAlerts.cancel(threadId: peerId)
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            MessageAlerts.uiVisible = true
            MessageAlerts.setBadge(0)
            BackgroundDelivery.endKeepAlive()
            Task { @DirectActor in Runtime.shared.node.onForeground() }
        case .inactive, .background:
            MessageAlerts.uiVisible = false
            Task { @DirectActor in Runtime.shared.node.onBackground() }
            if phase == .background {
                BackgroundDelivery.keepAlive()
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

    func setDiscoverable(_ on: Bool) {
        run { try $0.setDiscoverable(on) }
    }

    func refreshSuggestions() {
        run { await $0.refreshSuggestions() }
    }

    func addContact(_ input: String, done: @escaping @MainActor () -> Void) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        run { node in
            if trimmed.hasPrefix("{") { try node.addContactBundle(trimmed) } else { try await node.addContact(trimmed) }
            await MainActor.run { done() }
        }
    }

    func send(_ peerId: String, _ body: String) { run { try $0.send(peerId, body) } }
    func editMessage(_ messageId: String, _ body: String) { run { try $0.editMessage(messageId, body) } }
    func deleteMessage(_ messageId: String, forEveryone: Bool) { run { try $0.deleteMessage(messageId, forEveryone: forEveryone) } }
    func forwardMessage(_ messageId: String, to peerId: String) { run { try $0.forwardMessage(messageId, to: peerId) } }
    func react(_ messageId: String, _ emoji: String) { run { try $0.react(messageId, emoji) } }

    func createGroup(name: String, memberIds: [String], done: @escaping @MainActor (String) -> Void) {
        run { node in
            let group = try node.createGroup(name: name, memberIds: memberIds)
            await MainActor.run { done(group.id) }
        }
    }

    func placeCall(_ peerId: String, video: Bool) {
        AVCaptureDevice.requestAccess(for: .audio) { mic in
            guard mic else {
                Task { @MainActor in self.toast = "Microphone access is needed for a call." }
                return
            }
            if !video {
                Task { @MainActor in self.beginCall(peerId, video: false) }
                return
            }
            AVCaptureDevice.requestAccess(for: .video) { camera in
                guard camera else {
                    Task { @MainActor in self.toast = "Camera access is needed for a video call." }
                    return
                }
                Task { @MainActor in self.beginCall(peerId, video: true) }
            }
        }
    }

    func acceptCall(_ video: Bool) {
        AVCaptureDevice.requestAccess(for: .audio) { mic in
            guard mic else {
                Task { @MainActor in
                    self.toast = "Microphone access is needed for a call."
                    self.endCall()
                }
                return
            }
            if !video {
                Task { @DirectActor in await Runtime.shared.node.acceptCall() }
                return
            }
            AVCaptureDevice.requestAccess(for: .video) { camera in
                if camera {
                    Task { @DirectActor in await Runtime.shared.node.acceptCall() }
                } else {
                    Task { @MainActor in
                        self.toast = "Camera access is needed for a video call."
                        self.endCall()
                    }
                }
            }
        }
    }

    func endCall() { run { await $0.endCall() } }
    func dismissCall() { run { $0.dismissCall() } }
    func setCallMuted(_ muted: Bool) { run { $0.setCallMuted(muted) } }
    func setCallSpeaker(_ speaker: Bool) { run { $0.setCallSpeaker(speaker) } }
    func setCallCamera(_ enabled: Bool) { run { $0.setCallCamera(enabled) } }

    private func beginCall(_ peerId: String, video: Bool) {
        Task { @DirectActor in
            do {
                try await Runtime.shared.node.placeCall(peerId, video: video)
            } catch {
                let text = (error as? DirectError)?.message ?? "The call could not start."
                await MainActor.run { self.toast = text }
            }
        }
    }

    func sendMedia(peerId: String, kind: String, mime: String, name: String, bytes: Data, caption: String) {
        run { try $0.sendMedia(peerId, kind: kind, mime: mime, name: name, bytes: bytes, caption: caption) }
    }

    func publishFeed(channel: String, kind: String, mime: String, name: String, bytes: Data, caption: String = "", tags: [String] = []) {
        run { try $0.publishFeed(channel: channel, kind: kind, mime: mime, name: name, bytes: bytes, caption: caption, tags: tags) }
    }

    func deleteFeed(_ id: String) { run { try $0.deleteFeed(id) } }
    func saveFeed(_ id: String) { run { try $0.saveFeed(id) } }
    func likeFeed(_ id: String) { reactFeed(id, "❤️") }
    func reactFeed(_ id: String, _ emoji: String) { run { try $0.reactFeed(id, emoji) } }
    func forwardFeed(_ id: String, to peerId: String) { run { try $0.forwardFeed(id, to: peerId) } }
    func commentFeed(_ id: String, _ body: String) { run { try $0.commentFeed(id, body) } }
    func markStoriesSeen(_ ownerId: String) { run { try $0.markStoriesSeen(ownerId) } }

    func loadFeed(_ id: String, done: @escaping @MainActor (Data?) -> Void) {
        Task { @DirectActor in
            let data = Runtime.shared.node.readFeed(id)
            await MainActor.run { done(data) }
        }
    }

    func setStatus(_ text: String) { run { try $0.setStatus(text) } }
    func setAvatar(_ jpeg: Data) { run { try $0.setAvatar(jpeg) } }
    func clearAvatar() { run { try $0.clearAvatar() } }

    func addFromShare(_ text: String, done: @escaping @MainActor () -> Void = {}) {
        run { _ = try $0.addFromShare(text); await MainActor.run { done() } }
    }

    func loadMedia(_ id: String, done: @escaping @MainActor (Data?) -> Void) {
        Task { @DirectActor in
            let data = Runtime.shared.node.readMedia(id)
            await MainActor.run { done(data) }
        }
    }
    func open(_ peerId: String) { run { try $0.openConversation(peerId) } }
    func retry(_ messageId: String) { run { try $0.retry(messageId) } }
    func accept(_ peerId: String) { run { try $0.acceptRequest(peerId) } }
    func decline(_ peerId: String) { run { try $0.declineRequest(peerId) } }
    func block(_ peerId: String) { run { try $0.block(peerId) } }
    func unblock(_ peerId: String) { run { try $0.unblock(peerId) } }
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

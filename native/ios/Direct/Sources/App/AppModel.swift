import AVFoundation
import DirectCore
import SwiftUI
import UIKit

/// Main-actor mirror of `NodeState` for SwiftUI. Every action runs on `DirectActor`.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state = NodeState()
    @Published var toast: String?
    @Published var newPhrase: String?
    @Published var showIntro = false

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        _ = CallSession.shared
        Task { @DirectActor in
            let node = Runtime.shared.node
            node.onCallEvent = { event in
                DispatchQueue.main.async { CallSession.shared.handle(event) }
            }
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

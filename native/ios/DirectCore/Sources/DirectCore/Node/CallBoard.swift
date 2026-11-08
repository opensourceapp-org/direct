import Foundation

public enum CallPhase: String, Equatable, Sendable {
    case outgoing, incoming, connecting, active, ended
}

public struct CallSnapshot: Equatable, Sendable {
    public var id: String
    public var peerId: String
    public var video: Bool
    public var phase: CallPhase
    public var outgoing: Bool
    public var muted: Bool
    public var speaker: Bool
    public var cameraOn: Bool
    public var startedAt: Int64?
    public var reason: String?
}

public enum CallEvent: Sendable {
    case begin(video: Bool, outgoing: Bool)
    case offer(String)
    case answer(String)
    case ice(candidate: String, mid: String, line: Int)
    case end
}

public struct CallRejected: Error {
    public let message: String
}

/// One live call on this phone. Signaling is sealed and written on the data channel.
/// Media stays in the app. Every method runs on `DirectActor`.
final class CallBoard {
    static let ringMs: Int64 = 45_000

    var snapshot: CallSnapshot?
    var ringUntil: Int64?
    var clock: () -> Int64 = { 0 }
    var selfId: () -> String? = { nil }
    var send: (String, CallNotes.Note) async -> Bool = { _, _ in false }
    var record: (String, String, Bool, String, Bool) -> Void = { _, _, _, _, _ in }
    var changed: () -> Void = {}
    var signal: (CallEvent) -> Void = { _ in }

    private var pendingOffer: String?
    private var pendingIce: [CallEvent] = []
    private var mediaReady = false

    func place(peerId: String, video: Bool, id: String) async throws {
        if let current = snapshot, current.phase != .ended {
            throw CallRejected(message: "A call is already on this phone.")
        }
        snapshot = CallSnapshot(
            id: id, peerId: peerId, video: video, phase: .outgoing, outgoing: true,
            muted: false, speaker: video, cameraOn: video, startedAt: nil, reason: nil
        )
        ringUntil = clock() + Self.ringMs
        pendingOffer = nil
        pendingIce.removeAll()
        mediaReady = true
        changed()
        let sent = await send(peerId, CallNotes.Note(op: "invite", id: id, kind: video ? "video" : "audio"))
        if !sent {
            finish("Unreachable")
            throw CallRejected(message: "That phone is not reachable for a call. Messages still wait on this phone.")
        }
        signal(.begin(video: video, outgoing: true))
    }

    func accept() async {
        guard let live = snapshot, live.phase == .incoming else { return }
        var next = live
        next.phase = .connecting
        next.speaker = live.video
        next.cameraOn = live.video
        snapshot = next
        ringUntil = nil
        mediaReady = true
        changed()
        _ = await send(live.peerId, CallNotes.Note(op: "accept", id: live.id))
        signal(.begin(video: live.video, outgoing: false))
        flushPending()
    }

    func end() async {
        guard let live = snapshot else { return }
        if live.phase == .ended {
            snapshot = nil
            changed()
            return
        }
        if live.phase == .incoming {
            await decline()
            return
        }
        _ = await send(live.peerId, CallNotes.Note(op: "hangup", id: live.id))
        finish(live.startedAt == nil ? "Cancelled" : nil)
    }

    func dismiss() {
        guard snapshot?.phase == .ended else { return }
        snapshot = nil
        changed()
    }

    func relayOffer(_ sdp: String) async {
        guard let live = snapshot, live.outgoing, live.phase != .ended, live.phase != .incoming else { return }
        _ = await send(live.peerId, CallNotes.Note(op: "offer", id: live.id, sdp: sdp))
    }

    func relayAnswer(_ sdp: String) async {
        guard let live = snapshot, !live.outgoing, live.phase != .ended, live.phase != .incoming else { return }
        _ = await send(live.peerId, CallNotes.Note(op: "answer", id: live.id, sdp: sdp))
    }

    func relayIce(_ candidate: String, _ mid: String, _ line: Int) async {
        guard let live = snapshot, live.phase != .ended, live.phase != .incoming else { return }
        _ = await send(live.peerId, CallNotes.Note(op: "ice", id: live.id, candidate: candidate, mid: mid, line: line))
    }

    func markLive() {
        guard var live = snapshot else { return }
        guard live.phase == .connecting || live.phase == .outgoing else { return }
        live.phase = .active
        live.startedAt = live.startedAt ?? clock()
        snapshot = live
        ringUntil = nil
        changed()
    }

    func update(muted: Bool? = nil, speaker: Bool? = nil, camera: Bool? = nil) {
        guard var live = snapshot, live.phase != .ended else { return }
        if let muted { live.muted = muted }
        if let speaker { live.speaker = speaker }
        if let camera { live.cameraOn = camera }
        snapshot = live
        changed()
    }

    func tick() async {
        guard let until = ringUntil, clock() >= until, let live = snapshot else { return }
        ringUntil = nil
        switch live.phase {
        case .outgoing:
            _ = await send(live.peerId, CallNotes.Note(op: "hangup", id: live.id))
            finish("No answer")
        case .incoming:
            finish(live.video ? "Missed video call" : "Missed audio call")
        default:
            break
        }
    }

    func onRemote(_ peerId: String, _ plain: String) async {
        guard let note = CallNotes.parse(plain) else { return }
        switch note.op {
        case "invite":
            await incoming(peerId, note)
        case "accept":
            guard var live = snapshot, live.id == note.id, live.phase == .outgoing else { return }
            live.phase = .connecting
            snapshot = live
            ringUntil = nil
            changed()
        case "reject":
            guard let live = snapshot, live.id == note.id else { return }
            finish("Call declined")
        case "busy":
            guard let live = snapshot, live.id == note.id, live.phase == .outgoing else { return }
            finish("Busy")
        case "hangup":
            guard let live = snapshot, live.id == note.id, live.phase != .ended else { return }
            finish(nil)
        case "offer":
            guard let live = snapshot, live.id == note.id, let sdp = note.sdp else { return }
            if mediaReady && (live.phase == .connecting || live.phase == .active) {
                signal(.offer(sdp))
            } else {
                pendingOffer = sdp
            }
        case "answer":
            guard var live = snapshot, live.id == note.id, live.outgoing, let sdp = note.sdp else { return }
            if live.phase == .outgoing {
                live.phase = .connecting
                snapshot = live
                ringUntil = nil
                changed()
            }
            signal(.answer(sdp))
        case "ice":
            guard let live = snapshot, live.id == note.id, live.phase != .ended, let candidate = note.candidate else { return }
            let event = CallEvent.ice(candidate: candidate, mid: note.mid ?? "0", line: note.line ?? 0)
            if mediaReady, live.phase != .incoming { signal(event) } else { pendingIce.append(event) }
        default:
            break
        }
    }

    private func incoming(_ peerId: String, _ note: CallNotes.Note) async {
        if let current = snapshot, current.phase != .ended {
            if current.phase == .outgoing, current.peerId == peerId {
                guard let selfId = selfId(), selfId > peerId else { return }
                signal(.end)
                snapshot = nil
                pendingOffer = nil
                pendingIce.removeAll()
                mediaReady = false
                ringUntil = nil
            } else {
                _ = await send(peerId, CallNotes.Note(op: "busy", id: note.id))
                return
            }
        }
        let video = note.kind == "video"
        snapshot = CallSnapshot(
            id: note.id, peerId: peerId, video: video, phase: .incoming, outgoing: false,
            muted: false, speaker: false, cameraOn: false, startedAt: nil, reason: nil
        )
        ringUntil = clock() + Self.ringMs
        mediaReady = false
        changed()
    }

    private func flushPending() {
        if let offer = pendingOffer {
            pendingOffer = nil
            signal(.offer(offer))
        }
        let ice = pendingIce
        pendingIce.removeAll()
        ice.forEach(signal)
    }

    private func finish(_ reason: String?) {
        guard let live = snapshot, live.phase != .ended else { return }
        signal(.end)
        let missed = live.phase == .incoming && reason != "Declined"
        let label = reason ?? durationLabel(live)
        record(live.peerId, live.id, live.outgoing, label, missed)
        var ended = live
        ended.phase = .ended
        ended.reason = label
        snapshot = ended
        ringUntil = nil
        pendingOffer = nil
        pendingIce.removeAll()
        mediaReady = false
        changed()
    }

    private func durationLabel(_ live: CallSnapshot) -> String {
        let kind = live.video ? "Video" : "Audio"
        guard let started = live.startedAt else { return live.outgoing ? "No answer" : "Missed \(kind) call" }
        let seconds = max(0, (clock() - started) / 1000)
        return "\(kind) call · \(seconds / 60):" + String(format: "%02d", seconds % 60)
    }

    private func decline() async {
        guard let live = snapshot, live.phase == .incoming else { return }
        _ = await send(live.peerId, CallNotes.Note(op: "reject", id: live.id))
        finish("Declined")
    }
}

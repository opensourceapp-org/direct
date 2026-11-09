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
    public var group: Bool
    public var members: [String]

    public init(
        id: String, peerId: String, video: Bool, phase: CallPhase, outgoing: Bool,
        muted: Bool, speaker: Bool, cameraOn: Bool, startedAt: Int64?, reason: String?,
        group: Bool = false, members: [String] = []
    ) {
        self.id = id
        self.peerId = peerId
        self.video = video
        self.phase = phase
        self.outgoing = outgoing
        self.muted = muted
        self.speaker = speaker
        self.cameraOn = cameraOn
        self.startedAt = startedAt
        self.reason = reason
        self.group = group
        self.members = members
    }
}

public enum CallEvent: Sendable {
    case begin(video: Bool, outgoing: Bool, peerId: String)
    case offer(String, peerId: String)
    case answer(String, peerId: String)
    case ice(candidate: String, mid: String, line: Int, peerId: String)
    case end
}

public struct CallRejected: Error {
    public let message: String
}

/// One live call on this phone. Signaling is sealed and written on the data channel.
/// Group calls are a mesh: each pair of members opens their own connection, and the
/// lower DIRECT ID offers. Every method runs on `DirectActor`.
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

    private var pendingOffer: [String: String] = [:]
    private var pendingIce: [String: [CallEvent]] = [:]
    private var mediaReady: Set<String> = []
    private var joined: Set<String> = []
    private var inviter: String?
    private var sessionReady = false

    func place(peerId: String, video: Bool, id: String, members: [String] = []) async throws {
        if let current = snapshot, current.phase != .ended {
            throw CallRejected(message: "A call is already on this phone.")
        }
        let group = !members.isEmpty
        snapshot = CallSnapshot(
            id: id, peerId: peerId, video: video, phase: .outgoing, outgoing: true,
            muted: false, speaker: video, cameraOn: video, startedAt: nil, reason: nil,
            group: group, members: members
        )
        ringUntil = clock() + Self.ringMs
        pendingOffer.removeAll()
        pendingIce.removeAll()
        mediaReady.removeAll()
        joined.removeAll()
        sessionReady = false
        inviter = selfId()
        changed()
        if !group {
            let sent = await send(peerId, CallNotes.Note(op: "invite", id: id, kind: video ? "video" : "audio"))
            if !sent {
                finish("Unreachable")
                throw CallRejected(message: "That phone is not reachable for a call. Messages still wait on this phone.")
            }
            sessionReady = true
            mediaReady.insert(peerId)
            signal(.begin(video: video, outgoing: true, peerId: peerId))
            return
        }
        var any = false
        let invite = CallNotes.Note(op: "invite", id: id, kind: video ? "video" : "audio", groupId: peerId, members: members)
        for member in members {
            if await send(member, invite) { any = true }
        }
        if !any {
            finish("Unreachable")
            throw CallRejected(message: "That phone is not reachable for a call. Messages still wait on this phone.")
        }
        sessionReady = true
    }

    func accept() async {
        guard let live = snapshot, live.phase == .incoming else { return }
        var next = live
        next.phase = .connecting
        next.speaker = live.video
        next.cameraOn = live.video
        snapshot = next
        ringUntil = nil
        sessionReady = true
        changed()
        if live.group {
            guard let target = inviter else { return }
            _ = await send(target, CallNotes.Note(op: "accept", id: live.id, groupId: live.peerId))
            await joinAndMesh(target, offer: false)
        } else {
            _ = await send(live.peerId, CallNotes.Note(op: "accept", id: live.id))
            mediaReady.insert(live.peerId)
            signal(.begin(video: live.video, outgoing: false, peerId: live.peerId))
            flushPending(live.peerId)
        }
    }

    func end() async {
        guard let live = snapshot else { return }
        if live.phase == .ended {
            snapshot = nil
            changed()
            return
        }
        if live.phase == .incoming {
            let target = live.group ? inviter : live.peerId
            if let target {
                _ = await send(target, CallNotes.Note(op: "reject", id: live.id, groupId: live.group ? live.peerId : nil))
            }
            finish("Declined")
            return
        }
        await hangupAll(live)
        finish(live.startedAt == nil ? "Cancelled" : nil)
    }

    func dismiss() {
        guard snapshot?.phase == .ended else { return }
        snapshot = nil
        changed()
    }

    func relayOffer(_ sdp: String, toPeer: String? = nil) async {
        guard let live = snapshot, live.phase != .ended, live.phase != .incoming else { return }
        guard let target = toPeer ?? signalingPeer(live) else { return }
        _ = await send(target, CallNotes.Note(op: "offer", id: live.id, sdp: sdp, groupId: live.group ? live.peerId : nil))
    }

    func relayAnswer(_ sdp: String, toPeer: String? = nil) async {
        guard let live = snapshot, live.phase != .ended, live.phase != .incoming else { return }
        guard let target = toPeer ?? signalingPeer(live) else { return }
        _ = await send(target, CallNotes.Note(op: "answer", id: live.id, sdp: sdp, groupId: live.group ? live.peerId : nil))
    }

    func relayIce(_ candidate: String, _ mid: String, _ line: Int, toPeer: String? = nil) async {
        guard let live = snapshot, live.phase != .ended, live.phase != .incoming else { return }
        guard let target = toPeer ?? signalingPeer(live) else { return }
        _ = await send(target, CallNotes.Note(op: "ice", id: live.id, candidate: candidate, mid: mid, line: line, groupId: live.group ? live.peerId : nil))
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
            await hangupAll(live)
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
            guard var live = snapshot, live.id == note.id else { return }
            let connectingGroup = live.group && live.phase == .connecting
            guard live.phase == .outgoing || connectingGroup else { return }
            if live.phase == .outgoing {
                live.phase = .connecting
                snapshot = live
                ringUntil = nil
                changed()
            }
            if live.group { await joinAndMesh(peerId, offer: true) }
        case "reject":
            guard let live = snapshot, live.id == note.id else { return }
            if live.group { await dropMember(peerId, "Call declined") } else { finish("Call declined") }
        case "busy":
            guard let live = snapshot, live.id == note.id else { return }
            if live.group {
                await dropMember(peerId, "Busy")
            } else if live.phase == .outgoing {
                finish("Busy")
            }
        case "hangup":
            guard let live = snapshot, live.id == note.id, live.phase != .ended else { return }
            if live.group { await dropMember(peerId, nil) } else { finish(nil) }
        case "member":
            guard let live = snapshot, live.id == note.id, live.phase != .ended, live.group, let other = note.peer, other != selfId() else { return }
            await joinAndMesh(other, offer: true)
        case "offer":
            guard let live = snapshot, live.id == note.id, let sdp = note.sdp else { return }
            if sessionReady && (live.phase == .connecting || live.phase == .active || (live.group && live.phase == .outgoing)) {
                if !mediaReady.contains(peerId) {
                    mediaReady.insert(peerId)
                    signal(.begin(video: live.video, outgoing: false, peerId: peerId))
                }
                signal(.offer(sdp, peerId: peerId))
            } else {
                pendingOffer[peerId] = sdp
            }
        case "answer":
            guard var live = snapshot, live.id == note.id, let sdp = note.sdp else { return }
            if live.phase == .outgoing {
                live.phase = .connecting
                snapshot = live
                ringUntil = nil
                changed()
            }
            signal(.answer(sdp, peerId: peerId))
        case "ice":
            guard let live = snapshot, live.id == note.id, live.phase != .ended, let candidate = note.candidate else { return }
            let event = CallEvent.ice(candidate: candidate, mid: note.mid ?? "0", line: note.line ?? 0, peerId: peerId)
            if sessionReady, live.phase != .incoming, mediaReady.contains(peerId) {
                signal(event)
            } else {
                pendingIce[peerId, default: []].append(event)
            }
        default:
            break
        }
    }

    private func incoming(_ peerId: String, _ note: CallNotes.Note) async {
        if let current = snapshot, current.phase != .ended {
            if current.phase == .outgoing, current.peerId == peerId {
                guard let selfId = selfId(), selfId > peerId else { return }
                signal(.end)
                reset()
                snapshot = nil
            } else {
                _ = await send(peerId, CallNotes.Note(op: "busy", id: note.id, groupId: note.groupId))
                return
            }
        }
        let video = note.kind == "video"
        let group = note.groupId != nil
        let members = group ? (note.members.filter { $0 != selfId() }.isEmpty ? [peerId] : note.members.filter { $0 != selfId() }) : []
        snapshot = CallSnapshot(
            id: note.id, peerId: note.groupId ?? peerId, video: video, phase: .incoming, outgoing: false,
            muted: false, speaker: false, cameraOn: false, startedAt: nil, reason: nil,
            group: group, members: members
        )
        ringUntil = clock() + Self.ringMs
        pendingOffer.removeAll()
        pendingIce.removeAll()
        mediaReady.removeAll()
        joined.removeAll()
        sessionReady = false
        inviter = peerId
        changed()
    }

    private func joinAndMesh(_ other: String, offer: Bool) async {
        guard var live = snapshot, let selfId = selfId(), other != selfId else { return }
        if !joined.insert(other).inserted {
            if !mediaReady.contains(other) { meshPair(other, weMayOffer: offer) }
            return
        }
        live.members = Array(Set(live.members + [other]))
        snapshot = live
        changed()
        meshPair(other, weMayOffer: offer)
        if offer { await announceMember(other) }
    }

    private func meshPair(_ other: String, weMayOffer: Bool) {
        guard let live = snapshot, let selfId = selfId() else { return }
        if mediaReady.contains(other) {
            flushPending(other)
            return
        }
        mediaReady.insert(other)
        let weOffer = weMayOffer && selfId < other
        signal(.begin(video: live.video, outgoing: weOffer, peerId: other))
        flushPending(other)
    }

    private func announceMember(_ joinedPeer: String) async {
        guard let live = snapshot, live.group else { return }
        let others = joined.filter { $0 != joinedPeer }
        for member in others {
            _ = await send(member, CallNotes.Note(op: "member", id: live.id, groupId: live.peerId, peer: joinedPeer))
            _ = await send(joinedPeer, CallNotes.Note(op: "member", id: live.id, groupId: live.peerId, peer: member))
        }
    }

    private func dropMember(_ peerId: String, _ reason: String?) async {
        guard let live = snapshot else { return }
        joined.remove(peerId)
        mediaReady.remove(peerId)
        pendingOffer[peerId] = nil
        pendingIce[peerId] = nil
        if joined.isEmpty && live.outgoing && live.phase == .outgoing {
            if reason != nil && live.members.count <= 1 { finish(reason) }
            return
        }
        if joined.isEmpty && live.phase != .outgoing { finish(reason) }
    }

    private func hangupAll(_ live: CallSnapshot) async {
        let targets = live.group ? Array(Set(live.members + Array(joined))) : [live.peerId]
        for member in targets {
            _ = await send(member, CallNotes.Note(op: "hangup", id: live.id, groupId: live.group ? live.peerId : nil))
        }
    }

    private func signalingPeer(_ live: CallSnapshot) -> String? {
        if live.group {
            if let inviter, inviter != selfId() { return inviter }
            return live.members.first
        }
        return live.peerId
    }

    private func flushPending(_ peerId: String) {
        if let offer = pendingOffer.removeValue(forKey: peerId) {
            signal(.offer(offer, peerId: peerId))
        }
        let ice = pendingIce.removeValue(forKey: peerId) ?? []
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
        reset()
        changed()
    }

    private func reset() {
        ringUntil = nil
        pendingOffer.removeAll()
        pendingIce.removeAll()
        mediaReady.removeAll()
        joined.removeAll()
        sessionReady = false
        inviter = nil
    }

    private func durationLabel(_ live: CallSnapshot) -> String {
        let kind: String
        if live.group {
            kind = live.video ? "Group video" : "Group audio"
        } else {
            kind = live.video ? "Video" : "Audio"
        }
        guard let started = live.startedAt else { return live.outgoing ? "No answer" : "Missed \(kind) call" }
        let seconds = max(0, (clock() - started) / 1000)
        return "\(kind) call · \(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

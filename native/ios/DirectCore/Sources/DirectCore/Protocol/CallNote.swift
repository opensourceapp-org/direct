import Foundation

/// A live call signal sealed to one contact. It is not a chat message and it is not queued.
/// The bootstrap never sees this JSON.
public enum CallNotes {
    public static let ops: Set<String> = ["invite", "accept", "reject", "busy", "hangup", "offer", "answer", "ice"]

    public struct Note: Equatable, Sendable {
        public var op: String
        public var id: String
        public var kind: String?
        public var sdp: String?
        public var candidate: String?
        public var mid: String?
        public var line: Int?

        public init(op: String, id: String, kind: String? = nil, sdp: String? = nil, candidate: String? = nil, mid: String? = nil, line: Int? = nil) {
            self.op = op
            self.id = id
            self.kind = kind
            self.sdp = sdp
            self.candidate = candidate
            self.mid = mid
            self.line = line
        }
    }

    public static func encode(_ note: Note) -> String {
        var pairs: [(String, JSON)] = [
            ("v", .int(1)),
            ("op", .string(note.op)),
            ("id", .string(note.id)),
        ]
        if let kind = note.kind { pairs.append(("kind", .string(kind))) }
        if let sdp = note.sdp { pairs.append(("sdp", .string(sdp))) }
        if let candidate = note.candidate { pairs.append(("candidate", .string(candidate))) }
        if let mid = note.mid { pairs.append(("mid", .string(mid))) }
        if let line = note.line { pairs.append(("line", .int(Int64(line)))) }
        return JSON.object(pairs).serialized()
    }

    public static func parse(_ text: String) -> Note? {
        guard let json = JSON.parse(text), json["v"]?.int64 == 1,
              let op = json["op"]?.string, ops.contains(op),
              let id = json["id"]?.string, !id.isEmpty, id.utf8.count <= 80 else { return nil }
        let kind = json["kind"]?.string.flatMap { $0 == "audio" || $0 == "video" ? $0 : nil }
        let sdp = json["sdp"]?.string.flatMap { $0.count > 0 && $0.count <= 100_000 ? $0 : nil }
        let candidate = json["candidate"]?.string.flatMap { $0.count > 0 && $0.count <= 8_000 ? $0 : nil }
        let mid = json["mid"]?.string.flatMap { $0.count > 0 && $0.count <= 32 ? $0 : nil }
        let line = json["line"]?.int64.flatMap { $0 >= 0 && $0 <= 64 ? Int($0) : nil }
        switch op {
        case "invite":
            return Note(op: op, id: id, kind: kind ?? "audio")
        case "offer", "answer":
            guard let sdp else { return nil }
            return Note(op: op, id: id, sdp: sdp)
        case "ice":
            guard let candidate else { return nil }
            return Note(op: op, id: id, candidate: candidate, mid: mid ?? "0", line: line ?? 0)
        default:
            return Note(op: op, id: id)
        }
    }
}

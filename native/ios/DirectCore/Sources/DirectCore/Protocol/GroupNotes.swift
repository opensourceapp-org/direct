import Foundation

/// Group membership and group chat plaintext. Invites use envelope type `group`.
/// Chat text is a normal `message` whose plaintext starts with `prefix`, so a 1:1
/// body is never mistaken for a group payload. Each member still receives their
/// own sealed copy; the bootstrap never sees this JSON.
public enum GroupNotes {
    public static let prefix = "DIRECT-GROUP/1\n"
    public static let maxMembers = 16
    public static let ops: Set<String> = ["invite", "text", "leave"]

    public struct Note: Equatable, Sendable {
        public var op: String
        public var groupId: String
        public var name: String?
        public var members: [String]
        public var mid: String?
        public var body: String?

        public init(op: String, groupId: String, name: String? = nil, members: [String] = [], mid: String? = nil, body: String? = nil) {
            self.op = op
            self.groupId = groupId
            self.name = name
            self.members = members
            self.mid = mid
            self.body = body
        }
    }

    public static func isGroupId(_ value: String) -> Bool {
        let bytes = value.utf8
        guard bytes.count == 36, value.hasPrefix("grp_") else { return false }
        return bytes.dropFirst(4).allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    public static func parsePrefixed(_ text: String) -> Note? {
        guard text.hasPrefix(prefix) else { return nil }
        return parse(String(text.dropFirst(prefix.count)))
    }

    public static func encodeText(groupId: String, mid: String, body: String) -> String {
        prefix + encode(Note(op: "text", groupId: groupId, mid: mid, body: body))
    }

    public static func encode(_ note: Note) -> String {
        var pairs: [(String, JSON)] = [
            ("v", .int(1)),
            ("op", .string(note.op)),
            ("groupId", .string(note.groupId)),
        ]
        if let name = note.name { pairs.append(("name", .string(name))) }
        if !note.members.isEmpty { pairs.append(("members", .array(note.members.map(JSON.string)))) }
        if let mid = note.mid { pairs.append(("mid", .string(mid))) }
        if let body = note.body { pairs.append(("body", .string(body))) }
        return JSON.object(pairs).serialized()
    }

    public static func parse(_ text: String) -> Note? {
        guard let json = JSON.parse(text), json["v"]?.int64 == 1,
              let op = json["op"]?.string, ops.contains(op),
              let groupId = json["groupId"]?.string, isGroupId(groupId) else { return nil }
        let name = json["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.flatMap { $0.utf16.count >= 1 && $0.utf16.count <= 32 ? $0 : nil }
        var seen = Set<String>()
        let unique = (json["members"]?.array ?? []).compactMap { DirectIds.normalize($0.string ?? "") }.filter { seen.insert($0).inserted }
        if unique.count > maxMembers { return nil }
        let mid = json["mid"]?.string.flatMap { $0.count >= 4 && $0.count <= 80 ? $0 : nil }
        let body = json["body"]?.string.flatMap { $0.count >= 1 && $0.count <= 8_000 ? $0 : nil }
        switch op {
        case "invite":
            guard let trimmedName, unique.count >= 2 else { return nil }
            return Note(op: op, groupId: groupId, name: trimmedName, members: unique)
        case "text":
            guard let mid, let body else { return nil }
            return Note(op: op, groupId: groupId, mid: mid, body: body)
        default:
            return Note(op: op, groupId: groupId, name: trimmedName, members: unique)
        }
    }
}

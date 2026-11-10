import Foundation

/// Edit and delete travel as ordinary `message` envelopes whose plaintext starts with `prefix`.
/// The original chat id is inside the JSON, so a new envelope cannot be mistaken for a new bubble.
public enum ChatNotes {
    public static let prefix = "DIRECT-CHAT/1\n"
    public static let ops: Set<String> = ["edit", "delete"]

    public struct Note: Equatable, Sendable {
        public var op: String
        public var messageId: String
        public var body: String?
        public var groupId: String?

        public init(op: String, messageId: String, body: String? = nil, groupId: String? = nil) {
            self.op = op
            self.messageId = messageId
            self.body = body
            self.groupId = groupId
        }
    }

    public static func parsePrefixed(_ text: String) -> Note? {
        guard text.hasPrefix(prefix) else { return nil }
        return parse(String(text.dropFirst(prefix.count)))
    }

    public static func encode(_ note: Note) -> String {
        var pairs: [(String, JSON)] = [
            ("v", .int(1)),
            ("op", .string(note.op)),
            ("id", .string(note.messageId)),
        ]
        if let body = note.body { pairs.append(("body", .string(body))) }
        if let groupId = note.groupId { pairs.append(("groupId", .string(groupId))) }
        return prefix + JSON.object(pairs).serialized()
    }

    public static func parse(_ text: String) -> Note? {
        guard let json = JSON.parse(text), json["v"]?.int64 == 1,
              let op = json["op"]?.string, ops.contains(op),
              let messageId = json["id"]?.string, messageId.count >= 4 && messageId.count <= 80
        else { return nil }
        let body = json["body"]?.string.flatMap { $0.count >= 1 && $0.count <= 8_000 ? $0 : nil }
        let groupId = json["groupId"]?.string.flatMap { GroupNotes.isGroupId($0) ? $0 : nil }
        switch op {
        case "edit":
            guard let body else { return nil }
            return Note(op: op, messageId: messageId, body: body, groupId: groupId)
        case "delete":
            return Note(op: op, messageId: messageId, groupId: groupId)
        default:
            return nil
        }
    }
}

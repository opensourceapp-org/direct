import Foundation

/// A story or profile post sealed to accepted contacts. The bootstrap never sees the bytes.
/// Puts are chunked like chat media. Deletes are a short JSON note.
public enum FeedNotes {
    public static let partPrefix = "DIRECT-FEED/1\n"
    public static let jobPrefix = "DIRECT-FEED-JOB/1\n"
    public static let story = "story"
    public static let post = "post"
    public static let storyTtlMs: Int64 = 24 * 60 * 60 * 1000
    public static let maxStories = 20
    public static let maxPosts = 60
    public static let maxCaption = 200
    public static let channels: Set<String> = [story, post]
    public static let kinds: Set<String> = ["image", "video", "gif"]

    public struct Part: Equatable, Sendable {
        public var id: String
        public var channel: String
        public var kind: String
        public var mime: String
        public var name: String
        public var caption: String
        public var createdAt: Int64
        public var expiresAt: Int64?
        public var part: Int
        public var parts: Int

        public init(id: String, channel: String, kind: String, mime: String, name: String, caption: String, createdAt: Int64, expiresAt: Int64?, part: Int, parts: Int) {
            self.id = id
            self.channel = channel
            self.kind = kind
            self.mime = mime
            self.name = name
            self.caption = caption
            self.createdAt = createdAt
            self.expiresAt = expiresAt
            self.part = part
            self.parts = parts
        }
    }

    public struct Delete: Equatable, Sendable {
        public var channel: String
        public var id: String
    }

    public struct Job: Equatable, Sendable {
        public var id: String
        public var channel: String
        public var kind: String
        public var mime: String
        public var name: String
        public var caption: String
        public var createdAt: Int64
        public var expiresAt: Int64?
        public var parts: Int
        public var nextPart: Int
        public var fileName: String
    }

    public static func encodePart(_ part: Part, _ chunk: Data) -> Data {
        var pairs: [(String, JSON)] = [
            ("v", .int(1)),
            ("op", .string("put")),
            ("id", .string(part.id)),
            ("channel", .string(part.channel)),
            ("kind", .string(part.kind)),
            ("mime", .string(part.mime)),
            ("name", .string(part.name)),
            ("caption", .string(part.caption)),
            ("createdAt", .int(part.createdAt)),
            ("part", .int(Int64(part.part))),
            ("parts", .int(Int64(part.parts))),
        ]
        if let expiresAt = part.expiresAt { pairs.append(("expiresAt", .int(expiresAt))) }
        return Encoding.utf8(partPrefix + JSON.object(pairs).serialized() + "\n") + chunk
    }

    public static func decodePart(_ plaintext: Data) -> (Part, Data)? {
        let prefix = Encoding.utf8(partPrefix)
        guard plaintext.starts(with: prefix) else { return nil }
        let rest = plaintext.dropFirst(prefix.count)
        guard let newline = rest.firstIndex(of: 0x0A),
              let json = JSON.parse(String(decoding: rest[..<newline], as: UTF8.self)),
              json["op"]?.string == "put",
              let id = json["id"]?.string,
              let channel = json["channel"]?.string,
              let kind = json["kind"]?.string,
              let mime = json["mime"]?.string,
              let createdAt = json["createdAt"]?.int64,
              let part = json["part"]?.int64,
              let parts = json["parts"]?.int64
        else { return nil }
        let decoded = Part(
            id: id,
            channel: channel,
            kind: kind,
            mime: mime,
            name: json["name"]?.string ?? "",
            caption: json["caption"]?.string ?? "",
            createdAt: createdAt,
            expiresAt: json["expiresAt"]?.int64,
            part: Int(part),
            parts: Int(parts)
        )
        guard channels.contains(decoded.channel), kinds.contains(decoded.kind),
              decoded.part >= 0, decoded.parts > 0, decoded.part < decoded.parts,
              (4...80).contains(decoded.id.count)
        else { return nil }
        return (decoded, Data(rest[(rest.index(after: newline))...]))
    }

    public static func encodeDelete(channel: String, id: String) -> String {
        partPrefix + JSON.object([
            ("v", .int(1)),
            ("op", .string("delete")),
            ("channel", .string(channel)),
            ("id", .string(id)),
        ]).serialized()
    }

    public static func decodeDelete(_ plaintext: String) -> Delete? {
        guard plaintext.hasPrefix(partPrefix),
              let json = JSON.parse(String(plaintext.dropFirst(partPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)),
              json["op"]?.string == "delete",
              let channel = json["channel"]?.string,
              let id = json["id"]?.string,
              channels.contains(channel),
              (4...80).contains(id.count)
        else { return nil }
        return Delete(channel: channel, id: id)
    }

    public static func encodeJob(_ job: Job) -> String {
        var pairs: [(String, JSON)] = [
            ("id", .string(job.id)),
            ("channel", .string(job.channel)),
            ("kind", .string(job.kind)),
            ("mime", .string(job.mime)),
            ("name", .string(job.name)),
            ("caption", .string(job.caption)),
            ("createdAt", .int(job.createdAt)),
            ("parts", .int(Int64(job.parts))),
            ("nextPart", .int(Int64(job.nextPart))),
            ("fileName", .string(job.fileName)),
        ]
        if let expiresAt = job.expiresAt { pairs.append(("expiresAt", .int(expiresAt))) }
        return jobPrefix + JSON.object(pairs).serialized()
    }

    public static func parseJob(_ payload: String) -> Job? {
        guard payload.hasPrefix(jobPrefix), let json = JSON.parse(String(payload.dropFirst(jobPrefix.count))),
              let id = json["id"]?.string,
              let channel = json["channel"]?.string,
              let kind = json["kind"]?.string,
              let mime = json["mime"]?.string,
              let createdAt = json["createdAt"]?.int64,
              let parts = json["parts"]?.int64,
              let nextPart = json["nextPart"]?.int64,
              let fileName = json["fileName"]?.string
        else { return nil }
        return Job(
            id: id,
            channel: channel,
            kind: kind,
            mime: mime,
            name: json["name"]?.string ?? "",
            caption: json["caption"]?.string ?? "",
            createdAt: createdAt,
            expiresAt: json["expiresAt"]?.int64,
            parts: Int(parts),
            nextPart: Int(nextPart),
            fileName: fileName
        )
    }

    public static func isJob(_ payload: String) -> Bool { payload.hasPrefix(jobPrefix) }

    public static func rewind(_ payload: String) -> String {
        guard var job = parseJob(payload) else { return payload }
        job.nextPart = 0
        return encodeJob(job)
    }
}

import Foundation

/// A photo, video, GIF, sticker, or voice note sealed inside a normal envelope.
/// The plaintext is `DIRECT-MEDIA/1`, one JSON header line, then the raw chunk.
/// Chunks travel on the data channel. The bootstrap never sees them.
public enum MediaNotes {
    public static let partPrefix = "DIRECT-MEDIA/1\n"
    public static let jobPrefix = "DIRECT-MEDIA-JOB/1\n"
    public static let defaultChunk = 96 * 1024
    public static let maxBytes = 6 * 1024 * 1024
    public static let maxAvatarBytes = 48_000
    public static let kinds: Set<String> = ["image", "video", "gif", "sticker", "audio"]

    public struct Part: Equatable, Sendable {
        public var mediaId: String
        public var kind: String
        public var mime: String
        public var name: String
        public var part: Int
        public var parts: Int
        public var caption: String

        public init(mediaId: String, kind: String, mime: String, name: String, part: Int, parts: Int, caption: String) {
            self.mediaId = mediaId
            self.kind = kind
            self.mime = mime
            self.name = name
            self.part = part
            self.parts = parts
            self.caption = caption
        }
    }

    public struct Job: Equatable, Sendable {
        public var kind: String
        public var mime: String
        public var name: String
        public var caption: String
        public var parts: Int
        public var nextPart: Int
        public var fileName: String

        public init(kind: String, mime: String, name: String, caption: String, parts: Int, nextPart: Int, fileName: String) {
            self.kind = kind
            self.mime = mime
            self.name = name
            self.caption = caption
            self.parts = parts
            self.nextPart = nextPart
            self.fileName = fileName
        }
    }

    public static func label(_ kind: String?) -> String? {
        switch kind {
        case "image": return "Photo"
        case "video": return "Video"
        case "gif": return "GIF"
        case "sticker": return "Sticker"
        case "audio": return "Voice message"
        default: return nil
        }
    }

    public static func split(_ bytes: Data, chunkBytes: Int) -> [Data] {
        let size = max(1, chunkBytes)
        if bytes.isEmpty { return [Data()] }
        var out: [Data] = []
        var index = 0
        while index < bytes.count {
            let end = min(index + size, bytes.count)
            out.append(bytes.subdata(in: index..<end))
            index = end
        }
        return out
    }

    public static func encodePart(_ part: Part, _ chunk: Data) -> Data {
        let header = JSON.object([
            ("mediaId", .string(part.mediaId)),
            ("kind", .string(part.kind)),
            ("mime", .string(part.mime)),
            ("name", .string(part.name)),
            ("part", .int(Int64(part.part))),
            ("parts", .int(Int64(part.parts))),
            ("caption", .string(part.caption)),
        ]).serialized()
        return Encoding.utf8(partPrefix + header + "\n") + chunk
    }

    public static func decodePart(_ plaintext: Data) -> (Part, Data)? {
        let prefix = Encoding.utf8(partPrefix)
        guard plaintext.starts(with: prefix) else { return nil }
        let rest = plaintext.dropFirst(prefix.count)
        guard let newline = rest.firstIndex(of: 0x0A) else { return nil }
        guard let json = JSON.parse(String(decoding: rest[..<newline], as: UTF8.self)) else { return nil }
        guard let mediaId = json["mediaId"]?.string,
              let kind = json["kind"]?.string,
              let mime = json["mime"]?.string,
              let part = json["part"]?.int64,
              let parts = json["parts"]?.int64
        else { return nil }
        let decoded = Part(
            mediaId: mediaId,
            kind: kind,
            mime: mime,
            name: json["name"]?.string ?? "",
            part: Int(part),
            parts: Int(parts),
            caption: json["caption"]?.string ?? ""
        )
        guard decoded.part >= 0, decoded.parts > 0, decoded.part < decoded.parts, kinds.contains(decoded.kind) else { return nil }
        return (decoded, Data(rest[(rest.index(after: newline))...]))
    }

    public static func encodeJob(_ job: Job) -> String {
        jobPrefix + JSON.object([
            ("kind", .string(job.kind)),
            ("mime", .string(job.mime)),
            ("name", .string(job.name)),
            ("caption", .string(job.caption)),
            ("parts", .int(Int64(job.parts))),
            ("nextPart", .int(Int64(job.nextPart))),
            ("fileName", .string(job.fileName)),
        ]).serialized()
    }

    public static func parseJob(_ payload: String) -> Job? {
        guard payload.hasPrefix(jobPrefix), let json = JSON.parse(String(payload.dropFirst(jobPrefix.count))) else { return nil }
        guard let kind = json["kind"]?.string,
              let mime = json["mime"]?.string,
              let parts = json["parts"]?.int64,
              let nextPart = json["nextPart"]?.int64,
              let fileName = json["fileName"]?.string
        else { return nil }
        return Job(
            kind: kind,
            mime: mime,
            name: json["name"]?.string ?? "",
            caption: json["caption"]?.string ?? "",
            parts: Int(parts),
            nextPart: Int(nextPart),
            fileName: fileName
        )
    }

    public static func isJob(_ payload: String) -> Bool { payload.hasPrefix(jobPrefix) }

    public static func rewind(_ payload: String) -> String {
        guard let job = parseJob(payload) else { return payload }
        var copy = job
        copy.nextPart = 0
        return encodeJob(copy)
    }
}

/// What a QR code carries: the signed bundle, the server address, plus an optional status and photo.
/// The share sheet sends a picture of that code, not this JSON as the message.
public enum ProfileCards {
    public struct Card: Equatable, Sendable {
        public var bundle: String
        public var status: String
        public var avatarJpeg: Data?
        /// Bootstrap address the sender is using. Empty on cards made before this field existed.
        public var bootstrap: String

        public init(bundle: String, status: String, avatarJpeg: Data?, bootstrap: String = "") {
            self.bundle = bundle
            self.status = status
            self.avatarJpeg = avatarJpeg
            self.bootstrap = bootstrap
        }
    }

    public static func encode(bundle: String, status: String, avatarJpeg: Data?, bootstrap: String = "") -> String {
        let avatar = avatarJpeg.flatMap { jpeg -> String? in
            guard (1...MediaNotes.maxAvatarBytes).contains(jpeg.count) else { return nil }
            return Encoding.base64Url(jpeg)
        }
        var pairs: [(String, JSON)] = [
            ("v", .int(1)),
            ("bundle", .string(bundle)),
            ("status", .string(status.trimmingCharacters(in: .whitespacesAndNewlines))),
        ]
        if let avatar { pairs.append(("avatar", .string(avatar))) }
        let server = bootstrap.trimmingCharacters(in: .whitespacesAndNewlines)
        if !server.isEmpty { pairs.append(("bootstrap", .string(server))) }
        return JSON.object(pairs).serialized()
    }

    /// A card, or a bare identity bundle.
    public static func parse(_ text: String) -> Card {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let json = JSON.parse(trimmed), let bundle = json["bundle"]?.string else {
            return Card(bundle: trimmed, status: "", avatarJpeg: nil)
        }
        let status = json["status"]?.string ?? ""
        let avatar = json["avatar"]?.string.flatMap(Encoding.fromBase64Url)
        let bootstrap = json["bootstrap"]?.string ?? ""
        return Card(bundle: bundle, status: status, avatarJpeg: avatar, bootstrap: bootstrap)
    }
}

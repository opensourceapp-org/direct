import Foundation

public struct SuggestedPerson: Equatable, Sendable {
    public var directId: String
    public var name: String
    public var bundle: String
    public var online: Bool

    public init(directId: String, name: String, bundle: String, online: Bool) {
        self.directId = directId
        self.name = name
        self.bundle = bundle
        self.online = online
    }
}

/// Frames from contracts/signaling.json. Nothing here can carry message text.
public enum SignalFrame: Equatable {
    case hello(from: String, bundle: String, nonce: String?, proof: String?, discoverable: Bool)
    case challenge(nonce: String)
    case lookup(requestId: String, directId: String)
    case watch(ids: [String])
    case offer(to: String, from: String, sdp: String)
    case answer(to: String, from: String, sdp: String)
    case ice(to: String, from: String, candidate: String, sdpMid: String?, sdpMLineIndex: Int?)
    case lookupResult(requestId: String, directId: String, present: Bool, bundle: String?)
    case unreachable(to: String)
    case presence(directId: String, online: Bool)
    case suggest(requestId: String)
    case suggestions(requestId: String, people: [SuggestedPerson])

    public var isNegotiation: Bool {
        switch self {
        case .offer, .answer, .ice: return true
        default: return false
        }
    }

    /// `to` and `from` of offer, answer, and ice frames.
    public var route: (to: String, from: String)? {
        switch self {
        case let .offer(to, from, _), let .answer(to, from, _), let .ice(to, from, _, _, _): return (to, from)
        default: return nil
        }
    }
}

public enum SignalCodec {
    public static let maxSignalChars = 64 * 1024
    public static let maxWatch = 256

    public static func encode(_ frame: SignalFrame) -> String {
        let json: JSON
        switch frame {
        case let .hello(from, bundle, nonce, proof, discoverable):
            var fields: [(String, JSON)] = [("kind", .string("hello")), ("from", .string(from)), ("bundle", .string(bundle))]
            if let nonce, let proof {
                fields.append(("nonce", .string(nonce)))
                fields.append(("proof", .string(proof)))
            }
            if discoverable { fields.append(("discoverable", .bool(true))) }
            json = .object(fields)
        case let .challenge(nonce):
            json = .object([("kind", .string("challenge")), ("nonce", .string(nonce))])
        case let .lookup(requestId, directId):
            json = .object([("kind", .string("lookup")), ("requestId", .string(requestId)), ("directId", .string(directId))])
        case let .watch(ids):
            json = .object([("kind", .string("watch")), ("ids", .array(ids.prefix(maxWatch).map(JSON.string)))])
        case let .offer(to, from, sdp):
            json = .object([
                ("kind", .string("offer")), ("to", .string(to)), ("from", .string(from)),
                ("description", .object([("type", .string("offer")), ("sdp", .string(sdp))])),
            ])
        case let .answer(to, from, sdp):
            json = .object([
                ("kind", .string("answer")), ("to", .string(to)), ("from", .string(from)),
                ("description", .object([("type", .string("answer")), ("sdp", .string(sdp))])),
            ])
        case let .ice(to, from, candidate, sdpMid, sdpMLineIndex):
            json = .object([
                ("kind", .string("ice")), ("to", .string(to)), ("from", .string(from)),
                ("candidate", .object([
                    ("candidate", .string(candidate)),
                    ("sdpMid", .optional(sdpMid)),
                    ("sdpMLineIndex", sdpMLineIndex.map { .int(Int64($0)) } ?? .null),
                ])),
            ])
        case let .lookupResult(requestId, directId, present, bundle):
            json = .object([
                ("kind", .string("lookup")), ("requestId", .string(requestId)), ("directId", .string(directId)),
                ("present", .bool(present)), ("bundle", .optional(bundle)),
            ])
        case let .unreachable(to):
            json = .object([("kind", .string("unreachable")), ("to", .string(to))])
        case let .presence(directId, online):
            json = .object([("kind", .string("presence")), ("directId", .string(directId)), ("online", .bool(online))])
        case let .suggest(requestId):
            json = .object([("kind", .string("suggest")), ("requestId", .string(requestId))])
        case let .suggestions(requestId, people):
            json = .object([
                ("kind", .string("suggestions")),
                ("requestId", .string(requestId)),
                ("people", .array(people.map { person in
                    .object([
                        ("directId", .string(person.directId)),
                        ("name", .string(person.name)),
                        ("bundle", .string(person.bundle)),
                        ("online", .bool(person.online)),
                    ])
                })),
            ])
        }
        return json.serialized()
    }

    /// Decodes a frame from either direction. Unknown or malformed frames return nil.
    public static func decode(_ text: String) -> SignalFrame? {
        guard text.utf16.count <= maxSignalChars + 8192, let json = JSON.parse(text), json.objectPairs != nil else { return nil }
        let to = json["to"]?.string
        let from = json["from"]?.string
        switch json["kind"]?.string {
        case "hello":
            guard let from, let bundle = json["bundle"]?.string else { return nil }
            return .hello(from: from, bundle: bundle, nonce: json["nonce"]?.string, proof: json["proof"]?.string, discoverable: json["discoverable"]?.bool == true)
        case "challenge":
            guard let nonce = json["nonce"]?.string else { return nil }
            return .challenge(nonce: nonce)
        case "lookup":
            guard let requestId = json["requestId"]?.string, let directId = json["directId"]?.string else { return nil }
            if let present = json["present"]?.bool {
                return .lookupResult(requestId: requestId, directId: directId, present: present, bundle: json["bundle"]?.string)
            }
            return .lookup(requestId: requestId, directId: directId)
        case "watch":
            guard let ids = json["ids"]?.array else { return nil }
            return .watch(ids: ids.compactMap(\.string))
        case "offer", "answer":
            guard let to, let from, let sdp = json["description"]?["sdp"]?.string else { return nil }
            return json["kind"]?.string == "offer" ? .offer(to: to, from: from, sdp: sdp) : .answer(to: to, from: from, sdp: sdp)
        case "ice":
            guard let to, let from, let candidate = json["candidate"], let line = candidate["candidate"]?.string else { return nil }
            return .ice(to: to, from: from, candidate: line, sdpMid: candidate["sdpMid"]?.string, sdpMLineIndex: candidate["sdpMLineIndex"]?.int64.map { Int($0) })
        case "unreachable":
            guard let to else { return nil }
            return .unreachable(to: to)
        case "presence":
            guard let directId = json["directId"]?.string, let online = json["online"]?.bool else { return nil }
            return .presence(directId: directId, online: online)
        case "suggest":
            guard let requestId = json["requestId"]?.string else { return nil }
            return .suggest(requestId: requestId)
        case "suggestions":
            guard let requestId = json["requestId"]?.string, let people = json["people"]?.array else { return nil }
            return .suggestions(requestId: requestId, people: people.compactMap { item in
                guard let directId = item["directId"]?.string, let bundle = item["bundle"]?.string else { return nil }
                return SuggestedPerson(
                    directId: directId,
                    name: item["name"]?.string ?? "",
                    bundle: bundle,
                    online: item["online"]?.bool ?? true
                )
            })
        default:
            return nil
        }
    }
}

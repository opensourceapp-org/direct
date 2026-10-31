import Foundation

public struct EnvelopeError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum EnvelopeType: String, Codable, CaseIterable {
    case message
    case ack
    case read
}

/// Signed, sealed unit that moves between devices over the data channel.
/// Field order, canonical string, and AAD match packages/protocol/src/envelope.ts.
public struct Envelope: Equatable {
    public let id: String
    public let type: EnvelopeType
    public let from: String
    public let to: String
    public let deviceId: String
    public let createdAt: Int64
    public let expiresAt: Int64
    public let ciphertext: String
    public var signature: String

    public var v: Int { 1 }

    public func canonical() -> Data {
        Encoding.utf8(["\(v)", id, type.rawValue, from, to, deviceId, "\(createdAt)", "\(expiresAt)", ciphertext].joined(separator: "|"))
    }

    public func encode() -> String {
        JSON.object([
            ("v", .int(Int64(v))),
            ("id", .string(id)),
            ("type", .string(type.rawValue)),
            ("from", .string(from)),
            ("to", .string(to)),
            ("deviceId", .string(deviceId)),
            ("createdAt", .int(createdAt)),
            ("expiresAt", .int(expiresAt)),
            ("ciphertext", .string(ciphertext)),
            ("signature", .string(signature)),
        ]).serialized()
    }

    public static func aad(id: String, type: EnvelopeType, from: String, to: String, createdAt: Int64) -> Data {
        Encoding.utf8("1|\(type.rawValue)|\(id)|\(from)|\(to)|\(createdAt)")
    }
}

public struct EnvelopeHeader: Equatable {
    public let id: String
    public let type: EnvelopeType
    public let from: String
    public let to: String
}

public enum Envelopes {
    public static let maxBytes = 256 * 1024
    public static let clockSkewMs: Int64 = 60_000

    public static func seal(
        sender: IdentityKeys,
        deviceId: String,
        recipientId: String,
        recipientAgreementPublic: Data,
        id: String,
        type: EnvelopeType,
        plaintext: Data,
        createdAt: Int64,
        ttlMs: Int64
    ) throws -> Envelope {
        let aad = Envelope.aad(id: id, type: type, from: sender.directId, to: recipientId, createdAt: createdAt)
        let ciphertext = Encoding.base64Url(try Seal.seal(recipientAgreementPublic: recipientAgreementPublic, plaintext: plaintext, aad: aad))
        var envelope = Envelope(
            id: id, type: type, from: sender.directId, to: recipientId, deviceId: deviceId,
            createdAt: createdAt, expiresAt: createdAt + ttlMs, ciphertext: ciphertext, signature: ""
        )
        envelope.signature = Encoding.base64Url(sender.sign(envelope.canonical()))
        return envelope
    }

    public static func open(recipient: IdentityKeys, envelope: Envelope) throws -> Data {
        guard let sealed = Encoding.fromBase64Url(envelope.ciphertext) else { throw EnvelopeError("Envelope ciphertext is not base64url.") }
        return try Seal.open(
            agreementSecret: recipient.agreementSecret,
            payload: sealed,
            aad: Envelope.aad(id: envelope.id, type: envelope.type, from: envelope.from, to: envelope.to, createdAt: envelope.createdAt)
        )
    }

    private static func parse(_ bytes: Data) throws -> JSON {
        guard bytes.count <= maxBytes else { throw EnvelopeError("Envelope is too large.") }
        guard let text = String(data: bytes, encoding: .utf8), let json = JSON.parse(text), json.objectPairs != nil else {
            throw EnvelopeError("Envelope is not valid JSON.")
        }
        return json
    }

    public static func peek(_ bytes: Data) -> EnvelopeHeader? {
        guard let json = try? parse(bytes),
              let type = json["type"]?.string.flatMap(EnvelopeType.init(rawValue:)),
              let id = json["id"]?.string,
              let from = json["from"]?.string,
              let to = json["to"]?.string
        else { return nil }
        return EnvelopeHeader(id: id, type: type, from: from, to: to)
    }

    /// Parses and verifies the sender signature and time window. Does not decrypt.
    public static func decode(_ bytes: Data, senderSigningPublic: Data, now: Int64) throws -> Envelope {
        let json = try parse(bytes)
        guard json["v"]?.int64 == 1,
              let type = json["type"]?.string.flatMap(EnvelopeType.init(rawValue:)),
              let id = json["id"]?.string, !id.isEmpty,
              let from = json["from"]?.string,
              let to = json["to"]?.string,
              let deviceId = json["deviceId"]?.string,
              let createdAt = json["createdAt"]?.int64,
              let expiresAt = json["expiresAt"]?.int64,
              let ciphertext = json["ciphertext"]?.string,
              let signature = json["signature"]?.string, !signature.isEmpty
        else { throw EnvelopeError("Envelope is malformed.") }
        guard createdAt <= now + clockSkewMs else { throw EnvelopeError("Envelope is too far in the future.") }
        guard expiresAt + clockSkewMs >= now else { throw EnvelopeError("Envelope has expired.") }
        let envelope = Envelope(
            id: id, type: type, from: from, to: to, deviceId: deviceId,
            createdAt: createdAt, expiresAt: expiresAt, ciphertext: ciphertext, signature: signature
        )
        guard let signatureBytes = Encoding.fromBase64Url(signature),
              Signatures.verify(signingPublic: senderSigningPublic, message: envelope.canonical(), signature: signatureBytes)
        else { throw EnvelopeError("Envelope signature is not valid.") }
        return envelope
    }
}

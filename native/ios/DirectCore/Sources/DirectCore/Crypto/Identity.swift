import Crypto
import Foundation

public struct IdentityError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum DirectIds {
    public static func fromSigningPublic(_ signingPublic: Data) -> String {
        "dir_" + Encoding.crockford(Encoding.sha256(signingPublic).prefix(10))
    }

    public static func did(_ directId: String) -> String { "did:direct:\(directId)" }

    public static func isValid(_ id: String) -> Bool {
        guard id.count == 20, id.hasPrefix("dir_") else { return false }
        let allowed = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        return id.dropFirst(4).allSatisfy { allowed.contains($0) }
    }

    /// Accepts `dir_` in any case and returns the canonical form, or nil when it is not a DIRECT ID.
    public static func normalize(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 20, trimmed.lowercased().hasPrefix("dir_") else { return nil }
        let id = "dir_" + trimmed.dropFirst(4).uppercased()
        return isValid(id) ? id : nil
    }
}

enum Hkdf {
    static func sha256(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info, outputByteCount: length)
        return key.withUnsafeBytes { Data($0) }
    }
}

public enum Signatures {
    public static func verify(signingPublic: Data, message: Data, signature: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signingPublic) else { return false }
        return key.isValidSignature(signature, for: message)
    }
}

/// The 32-byte seed is the Ed25519 signing secret. The X25519 agreement secret is
/// HKDF-SHA256(seed, info = "DIRECT-X25519-v1"). Same derivation as packages/crypto and the Kotlin core.
public final class IdentityKeys {
    public private(set) var seed: Data
    public let signingPublic: Data
    public private(set) var agreementSecret: Data
    public let agreementPublic: Data
    public let directId: String
    private let signing: Curve25519.Signing.PrivateKey

    private init(seed: Data) throws {
        guard seed.count == 32 else { throw IdentityError("Identity seed must be 32 bytes.") }
        self.seed = seed
        signing = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        signingPublic = signing.publicKey.rawRepresentation
        agreementSecret = Hkdf.sha256(ikm: seed, salt: Data(), info: Encoding.utf8("DIRECT-X25519-v1"), length: 32)
        agreementPublic = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreementSecret).publicKey.rawRepresentation
        directId = DirectIds.fromSigningPublic(signingPublic)
    }

    public static func fromSeed(_ seed: Data) throws -> IdentityKeys { try IdentityKeys(seed: Data(seed)) }

    public static func generate() -> IdentityKeys {
        // A 32-byte random seed is always a valid Ed25519 and X25519 secret.
        try! IdentityKeys(seed: Encoding.randomBytes(32))
    }

    public func sign(_ message: Data) -> Data {
        // Apple CryptoKit adds randomness to Ed25519 signatures; they verify the same everywhere.
        (try? signing.signature(for: message)) ?? Data()
    }

    public func wipe() {
        seed.wipe()
        agreementSecret.wipe()
    }
}

public struct PublicBundle: Equatable {
    public let name: String
    public let directId: String
    public let did: String
    public let deviceId: String
    public let signingKey: String
    public let agreementKey: String
    public let agreementSig: String
    public let fingerprint: String

    public var signingPublic: Data { Encoding.fromBase64Url(signingKey) ?? Data() }
    public var agreementPublic: Data { Encoding.fromBase64Url(agreementKey) ?? Data() }

    /// Compact JSON in the field order of packages/crypto encodeBundle, so the bootstrap's directId check matches.
    public func encode() -> String {
        JSON.object([
            ("v", .int(1)),
            ("name", .string(name)),
            ("directId", .string(directId)),
            ("did", .string(did)),
            ("deviceId", .string(deviceId)),
            ("signingKey", .string(signingKey)),
            ("agreementKey", .string(agreementKey)),
            ("agreementSig", .string(agreementSig)),
            ("fingerprint", .string(fingerprint)),
        ]).serialized()
    }
}

public enum Bundles {
    public static let maxNameUtf16 = 32

    public static func fingerprint(signingPublic: Data, agreementPublic: Data) -> String {
        let hex = Encoding.hex(Encoding.sha256(signingPublic, agreementPublic).prefix(16)).uppercased()
        return stride(from: 0, to: hex.count, by: 4).map { offset -> String in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return String(hex[start..<hex.index(start, offsetBy: 4)])
        }.joined(separator: " ")
    }

    static func agreementPayload(name: String, agreementPublic: Data) -> Data {
        Encoding.utf8(name) + Data([0]) + agreementPublic
    }

    public static func create(keys: IdentityKeys, displayName: String, deviceId: String) throws -> PublicBundle {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.utf16.count <= maxNameUtf16 else { throw IdentityError("Display name is too long.") }
        return PublicBundle(
            name: name,
            directId: keys.directId,
            did: DirectIds.did(keys.directId),
            deviceId: deviceId,
            signingKey: Encoding.base64Url(keys.signingPublic),
            agreementKey: Encoding.base64Url(keys.agreementPublic),
            agreementSig: Encoding.base64Url(keys.sign(agreementPayload(name: name, agreementPublic: keys.agreementPublic))),
            fingerprint: fingerprint(signingPublic: keys.signingPublic, agreementPublic: keys.agreementPublic)
        )
    }

    /// Verifies the DIRECT ID, DID, agreement signature, and fingerprint before returning the bundle.
    public static func parse(_ serialized: String) throws -> PublicBundle {
        guard let json = JSON.parse(serialized.trimmingCharacters(in: .whitespacesAndNewlines)), json.objectPairs != nil else {
            throw IdentityError("Identity bundle is not valid JSON.")
        }
        let name = json["name"]?.string ?? ""
        guard json["v"]?.int64 == 1,
              let directId = json["directId"]?.string,
              let signingKey = json["signingKey"]?.string,
              let agreementKey = json["agreementKey"]?.string,
              let agreementSig = json["agreementSig"]?.string
        else { throw IdentityError("Identity bundle is missing required fields.") }
        guard let signingPublic = Encoding.fromBase64Url(signingKey),
              let agreementPublic = Encoding.fromBase64Url(agreementKey),
              let signature = Encoding.fromBase64Url(agreementSig)
        else { throw IdentityError("Identity bundle keys are not base64url.") }
        guard signingPublic.count == 32, agreementPublic.count == 32 else { throw IdentityError("Identity bundle keys have the wrong length.") }
        let derived = DirectIds.fromSigningPublic(signingPublic)
        guard derived == directId, json["did"]?.string == DirectIds.did(derived) else {
            throw IdentityError("DIRECT ID does not match the signing key.")
        }
        guard Signatures.verify(signingPublic: signingPublic, message: agreementPayload(name: name, agreementPublic: agreementPublic), signature: signature) else {
            throw IdentityError("Agreement key signature is not valid.")
        }
        let fingerprint = fingerprint(signingPublic: signingPublic, agreementPublic: agreementPublic)
        guard json["fingerprint"]?.string == fingerprint else { throw IdentityError("Fingerprint does not match the published keys.") }
        guard name.utf16.count <= maxNameUtf16 else { throw IdentityError("Display name is too long.") }
        return PublicBundle(
            name: name, directId: directId, did: DirectIds.did(directId), deviceId: json["deviceId"]?.string ?? "",
            signingKey: signingKey, agreementKey: agreementKey, agreementSig: agreementSig, fingerprint: fingerprint
        )
    }
}

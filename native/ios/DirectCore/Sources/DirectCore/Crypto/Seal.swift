import Crypto
import Foundation

public struct SealError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

enum AesGcm {
    static func encrypt(key: Data, nonce: Data, aad: Data, plaintext: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
        return box.ciphertext + box.tag
    }

    static func decrypt(key: Data, nonce: Data, aad: Data, ciphertext: Data) throws -> Data {
        guard ciphertext.count >= 16 else { throw SealError("Ciphertext is too short.") }
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertext.prefix(ciphertext.count - 16),
            tag: ciphertext.suffix(16)
        )
        return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
    }
}

/// version(1) || ephemeral X25519 public(32) || nonce(12) || AES-256-GCM(ciphertext || tag).
/// key = HKDF-SHA256(X25519(ephemeral, recipient), salt = ephemeral public, info = "DIRECT-SEAL-v1").
/// This is a one-shot sealed box, not the Signal Double Ratchet.
public enum Seal {
    private static let version: UInt8 = 1
    private static let info = Encoding.utf8("DIRECT-SEAL-v1")
    private static let dbAad = Encoding.utf8("DIRECT-DB-v1")

    private static func shared(secret: Data, publicKey: Data) throws -> Data {
        let mine = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: secret)
        let theirs = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        return try mine.sharedSecretFromKeyAgreement(with: theirs).withUnsafeBytes { Data($0) }
    }

    public static func seal(recipientAgreementPublic: Data, plaintext: Data, aad: Data) throws -> Data {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublic = ephemeral.publicKey.rawRepresentation
        let theirs = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientAgreementPublic)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: theirs).withUnsafeBytes { Data($0) }
        let key = Hkdf.sha256(ikm: shared, salt: ephemeralPublic, info: info, length: 32)
        let nonce = Encoding.randomBytes(12)
        let ciphertext = try AesGcm.encrypt(key: key, nonce: nonce, aad: aad, plaintext: plaintext)
        return Data([version]) + ephemeralPublic + nonce + ciphertext
    }

    public static func open(agreementSecret: Data, payload: Data, aad: Data) throws -> Data {
        let bytes = Data(payload)
        guard bytes.count >= 1 + 32 + 12 + 16, bytes[0] == version else { throw SealError("Sealed payload is not a DIRECT envelope.") }
        let ephemeralPublic = bytes.subdata(in: 1..<33)
        let nonce = bytes.subdata(in: 33..<45)
        do {
            let key = Hkdf.sha256(ikm: try shared(secret: agreementSecret, publicKey: ephemeralPublic), salt: ephemeralPublic, info: info, length: 32)
            return try AesGcm.decrypt(key: key, nonce: nonce, aad: aad, ciphertext: bytes.subdata(in: 45..<bytes.count))
        } catch {
            throw SealError("Sealed payload failed authentication.")
        }
    }

    /// Same layout as packages/crypto sealDatabase: version || nonce || AES-256-GCM, aad "DIRECT-DB-v1".
    public static func sealAtRest(key: Data, plaintext: Data) throws -> Data {
        guard key.count == 32 else { throw SealError("Storage key must be 32 bytes.") }
        let nonce = Encoding.randomBytes(12)
        return Data([version]) + nonce + (try AesGcm.encrypt(key: key, nonce: nonce, aad: dbAad, plaintext: plaintext))
    }

    public static func openAtRest(key: Data, payload: Data) throws -> Data {
        let bytes = Data(payload)
        guard bytes.count >= 1 + 12 + 16, bytes[0] == version else { throw SealError("Encrypted store header is not recognized.") }
        do {
            return try AesGcm.decrypt(key: key, nonce: bytes.subdata(in: 1..<13), aad: dbAad, ciphertext: bytes.subdata(in: 13..<bytes.count))
        } catch {
            throw SealError("Storage key does not match this file.")
        }
    }
}

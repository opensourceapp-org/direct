import DirectCore
import Foundation
import Security

/// Identity seed and store key live in the Keychain as this-device-only items, readable after
/// the first unlock so background delivery works. On devices with a Secure Enclave each value is
/// additionally encrypted to a non-exportable P-256 enclave key (ECIES, X9.63 SHA-256, AES-GCM)
/// before it is written. Nothing is ever placed in UserDefaults or plain files.
final class KeychainSecretStore: SecretStore {
    struct KeychainError: Error, CustomStringConvertible {
        let status: OSStatus
        let action: String
        var description: String { "Keychain \(action) failed (\(status))." }
    }

    private enum Format: UInt8 {
        case keychainOnly = 0
        case enclaveWrapped = 1
    }

    private let service = "app.direct.messaging.secrets"
    private let wrapTag = Data("app.direct.messaging.enclave-wrap.v1".utf8)
    private let algorithm = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM
    private let lock = NSLock()

    func read(_ name: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        var query = item(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let stored = result as? Data else { throw KeychainError(status: status, action: "read") }
        return try unwrap(stored)
    }

    func write(_ name: String, _ value: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        let stored = try wrap(value)
        SecItemDelete(item(name) as CFDictionary)
        var attributes = item(name)
        attributes[kSecValueData as String] = stored
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status, action: "write") }
    }

    func delete(_ name: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let status = SecItemDelete(item(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status, action: "delete") }
    }

    private func item(_ name: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func wrap(_ value: Data) throws -> Data {
        guard let key = try enclaveKey(create: true), let publicKey = SecKeyCopyPublicKey(key) else {
            return Data([Format.keychainOnly.rawValue]) + value
        }
        var error: Unmanaged<CFError>?
        guard let sealed = SecKeyCreateEncryptedData(publicKey, algorithm, value as CFData, &error) as Data? else {
            throw error?.takeRetainedValue() ?? KeychainError(status: errSecParam, action: "wrap")
        }
        return Data([Format.enclaveWrapped.rawValue]) + sealed
    }

    private func unwrap(_ stored: Data) throws -> Data {
        guard let first = stored.first, let format = Format(rawValue: first) else { throw KeychainError(status: errSecDecode, action: "decode") }
        let body = Data(stored.dropFirst())
        switch format {
        case .keychainOnly:
            return body
        case .enclaveWrapped:
            guard let key = try enclaveKey(create: false) else { throw KeychainError(status: errSecItemNotFound, action: "find the Secure Enclave key") }
            var error: Unmanaged<CFError>?
            guard let plain = SecKeyCreateDecryptedData(key, algorithm, body as CFData, &error) as Data? else {
                throw error?.takeRetainedValue() ?? KeychainError(status: errSecDecode, action: "unwrap")
            }
            return plain
        }
    }

    /// The Secure Enclave key, or nil where there is no enclave (Simulator, very old devices).
    private func enclaveKey(create: Bool) throws -> SecKey? {
        #if targetEnvironment(simulator)
        return nil
        #else
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: wrapTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let found = result {
            return (found as! SecKey)
        }
        guard status == errSecItemNotFound else { throw KeychainError(status: status, action: "load the Secure Enclave key") }
        guard create else { return nil }
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, nil) else { return nil }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: wrapTag,
                kSecAttrAccessControl as String: access,
            ],
        ]
        var error: Unmanaged<CFError>?
        // No enclave on this hardware: the Keychain item alone still protects the value.
        return SecKeyCreateRandomKey(attributes as CFDictionary, &error)
        #endif
    }
}

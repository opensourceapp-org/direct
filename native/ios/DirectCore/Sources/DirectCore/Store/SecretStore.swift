import Foundation

/// Platform secret storage. iOS backs it with the Keychain (this-device-only) and, where
/// present, a Secure Enclave key that wraps each value. Android uses the Android Keystore.
/// Implementations must throw rather than fall back to UserDefaults or plain files.
public protocol SecretStore: AnyObject {
    func read(_ name: String) throws -> Data?
    func write(_ name: String, _ value: Data) throws
    func delete(_ name: String) throws
}

public final class MemorySecretStore: SecretStore {
    private var values: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func read(_ name: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[name]
    }

    public func write(_ name: String, _ value: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        values[name] = Data(value)
    }

    public func delete(_ name: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[name] = nil
    }

    public func names() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(values.keys)
    }
}

/// Identity seed and storage key, both held only in the platform secret store.
public final class IdentityVault {
    public static let seedName = "identity.seed"
    public static let storeKeyName = "store.key"

    private let secrets: SecretStore

    public init(_ secrets: SecretStore) {
        self.secrets = secrets
    }

    public func load() throws -> IdentityKeys? {
        guard var seed = try secrets.read(Self.seedName) else { return nil }
        defer { seed.wipe() }
        return try IdentityKeys.fromSeed(seed)
    }

    public func create() throws -> (IdentityKeys, String) {
        let keys = IdentityKeys.generate()
        try secrets.write(Self.seedName, keys.seed)
        return (keys, try Mnemonic.fromSeed(keys.seed))
    }

    public func restore(_ phrase: String) throws -> IdentityKeys {
        var seed = try Mnemonic.toSeed(phrase)
        defer { seed.wipe() }
        try secrets.write(Self.seedName, seed)
        return try IdentityKeys.fromSeed(seed)
    }

    public func recoveryPhrase() throws -> String? {
        guard let keys = try load() else { return nil }
        return try Mnemonic.fromSeed(keys.seed)
    }

    /// 32-byte key for the encrypted local store, created on first use.
    public func storageKey() throws -> Data {
        if let existing = try secrets.read(Self.storeKeyName) { return existing }
        let key = Encoding.randomBytes(32)
        try secrets.write(Self.storeKeyName, key)
        return key
    }

    public func erase() throws {
        try secrets.delete(Self.seedName)
        try secrets.delete(Self.storeKeyName)
    }
}

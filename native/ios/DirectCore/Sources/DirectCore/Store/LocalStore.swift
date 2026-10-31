import Foundation

public struct Profile: Codable, Equatable, Sendable {
    public var name: String
    public var deviceId: String
    public var directId: String
}

public struct Settings: Codable, Equatable, Sendable {
    public var bootstrapUrl: String?
}

public struct ContactRecord: Codable, Equatable, Identifiable, Sendable {
    public var directId: String
    public var name: String
    public var bundle: String
    public var fingerprint: String
    public var verified: Bool = false
    /// False while this contact is only a message request.
    public var accepted: Bool = true
    public var blocked: Bool = false
    public var createdAt: Int64

    public var id: String { directId }

    public init(directId: String, name: String, bundle: String, fingerprint: String, verified: Bool = false, accepted: Bool = true, blocked: Bool = false, createdAt: Int64) {
        self.directId = directId
        self.name = name
        self.bundle = bundle
        self.fingerprint = fingerprint
        self.verified = verified
        self.accepted = accepted
        self.blocked = blocked
        self.createdAt = createdAt
    }
}

public enum Direction: String, Codable, Sendable {
    case outgoing = "OUTGOING"
    case incoming = "INCOMING"
}

public struct MessageRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var peerId: String
    public var direction: Direction
    public var body: String
    public var createdAt: Int64
    /// Outgoing only.
    public var state: MessageState?
    /// Incoming only: a read receipt was queued.
    public var read: Bool = false
    public var lastError: String?
    public var updatedAt: Int64

    public init(id: String, peerId: String, direction: Direction, body: String, createdAt: Int64, state: MessageState? = nil, read: Bool = false, lastError: String? = nil, updatedAt: Int64? = nil) {
        self.id = id
        self.peerId = peerId
        self.direction = direction
        self.body = body
        self.createdAt = createdAt
        self.state = state
        self.read = read
        self.lastError = lastError
        self.updatedAt = updatedAt ?? createdAt
    }
}

public enum QueueKind: String, Codable {
    case message = "MESSAGE"
    case receipt = "RECEIPT"
}

public struct QueueItem: Codable, Equatable {
    /// Envelope id. For message items this is also the message id.
    public var id: String
    public var peerId: String
    public var kind: QueueKind
    /// Signed, sealed envelope JSON. Never plaintext.
    public var payload: String
    public var attempts: Int = 0
    public var nextAttemptAt: Int64
    public var expiresAt: Int64
    public var sentAt: Int64?
    public var lastError: String?

    public init(id: String, peerId: String, kind: QueueKind, payload: String, attempts: Int = 0, nextAttemptAt: Int64, expiresAt: Int64, sentAt: Int64? = nil, lastError: String? = nil) {
        self.id = id
        self.peerId = peerId
        self.kind = kind
        self.payload = payload
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.expiresAt = expiresAt
        self.sentAt = sentAt
        self.lastError = lastError
    }
}

struct Snapshot: Codable {
    var version = 1
    var profile: Profile?
    var settings = Settings()
    var contacts: [ContactRecord] = []
    var messages: [MessageRecord] = []
    var queue: [QueueItem] = []
}

/// The whole local database: profile, contacts, messages, and the outgoing queue.
/// It is written as one AES-256-GCM sealed file (same layout as packages/crypto sealDatabase)
/// with an atomic replace, so a crash leaves either the previous or the next complete state.
/// The key comes from `IdentityVault.storageKey()`, which lives in the Keychain.
/// Not thread-safe: DirectNode confines all access to `DirectActor`.
public final class LocalStore {
    public var profile: Profile?
    public var settings: Settings
    private var contactOrder: [String]
    private var contactMap: [String: ContactRecord]
    private var messageOrder: [String]
    private var messageMap: [String: MessageRecord]
    private var queueOrder: [String]
    private var queueMap: [String: QueueItem]
    private let file: URL?
    private let key: Data?

    private init(file: URL?, key: Data?, snapshot: Snapshot) {
        self.file = file
        self.key = key
        profile = snapshot.profile
        settings = snapshot.settings
        contactOrder = snapshot.contacts.map(\.directId)
        contactMap = Dictionary(snapshot.contacts.map { ($0.directId, $0) }, uniquingKeysWith: { _, last in last })
        messageOrder = snapshot.messages.map(\.id)
        messageMap = Dictionary(snapshot.messages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        queueOrder = snapshot.queue.map(\.id)
        queueMap = Dictionary(snapshot.queue.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func contact(_ directId: String) -> ContactRecord? { contactMap[directId] }
    public func contacts() -> [ContactRecord] { contactOrder.compactMap { contactMap[$0] } }
    public func putContact(_ contact: ContactRecord) {
        if contactMap[contact.directId] == nil { contactOrder.append(contact.directId) }
        contactMap[contact.directId] = contact
    }
    public func removeContact(_ directId: String) {
        contactMap[directId] = nil
        contactOrder.removeAll { $0 == directId }
    }

    public func message(_ id: String) -> MessageRecord? { messageMap[id] }
    public func messages() -> [MessageRecord] { messageOrder.compactMap { messageMap[$0] } }
    public func messagesWith(_ peerId: String) -> [MessageRecord] {
        messages().filter { $0.peerId == peerId }.sorted { $0.createdAt < $1.createdAt }
    }
    public func putMessage(_ message: MessageRecord) {
        if messageMap[message.id] == nil { messageOrder.append(message.id) }
        messageMap[message.id] = message
    }

    public func queued(_ id: String) -> QueueItem? { queueMap[id] }
    public func queue() -> [QueueItem] { queueOrder.compactMap { queueMap[$0] } }
    public func putQueued(_ item: QueueItem) {
        if queueMap[item.id] == nil { queueOrder.append(item.id) }
        queueMap[item.id] = item
    }
    public func removeQueued(_ id: String) {
        queueMap[id] = nil
        queueOrder.removeAll { $0 == id }
    }

    public func save() throws {
        guard let file, let key else { return }
        let snapshot = Snapshot(profile: profile, settings: settings, contacts: contacts(), messages: messages(), queue: queue())
        let sealed = try Seal.sealAtRest(key: key, plaintext: try JSONEncoder().encode(snapshot))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // .atomic writes a sibling temp file and renames it over the target.
        #if os(iOS)
        // Readable after the first unlock so background delivery can load the queue.
        try sealed.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try sealed.write(to: file, options: .atomic)
        #endif
    }

    /// Opens or creates the sealed file. A wrong key throws instead of wiping data.
    public static func open(file: URL, key: Data) throws -> LocalStore {
        guard key.count == 32 else { throw SealError("Storage key must be 32 bytes.") }
        guard FileManager.default.fileExists(atPath: file.path) else { return LocalStore(file: file, key: key, snapshot: Snapshot()) }
        let plain = try Seal.openAtRest(key: key, payload: try Data(contentsOf: file))
        return LocalStore(file: file, key: key, snapshot: try JSONDecoder().decode(Snapshot.self, from: plain))
    }

    public static func inMemory() -> LocalStore { LocalStore(file: nil, key: nil, snapshot: Snapshot()) }
}

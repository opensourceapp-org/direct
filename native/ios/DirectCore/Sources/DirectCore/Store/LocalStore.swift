import Foundation

public struct Profile: Codable, Equatable, Sendable {
    public var name: String
    public var deviceId: String
    public var directId: String
    /// A short line the user wrote. It is shared only on their QR or the share sheet.
    public var status: String
    /// Small JPEG, base64url. Nil until they choose a photo.
    public var avatarJpegBase64: String?

    private enum CodingKeys: String, CodingKey {
        case name, deviceId, directId, status, avatarJpegBase64
    }

    public init(name: String, deviceId: String, directId: String, status: String = "", avatarJpegBase64: String? = nil) {
        self.name = name
        self.deviceId = deviceId
        self.directId = directId
        self.status = status
        self.avatarJpegBase64 = avatarJpegBase64
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        directId = try container.decode(String.self, forKey: .directId)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        avatarJpegBase64 = try container.decodeIfPresent(String.self, forKey: .avatarJpegBase64)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(deviceId, forKey: .deviceId)
        try container.encode(directId, forKey: .directId)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(avatarJpegBase64, forKey: .avatarJpegBase64)
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var bootstrapUrl: String?
    public var bootstrapDefaultVersion: Int

    private enum CodingKeys: String, CodingKey {
        case bootstrapUrl, bootstrapDefaultVersion
    }

    public init(bootstrapUrl: String? = nil, bootstrapDefaultVersion: Int = 0) {
        self.bootstrapUrl = bootstrapUrl
        self.bootstrapDefaultVersion = bootstrapDefaultVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bootstrapUrl = try container.decodeIfPresent(String.self, forKey: .bootstrapUrl)
        bootstrapDefaultVersion = try container.decodeIfPresent(Int.self, forKey: .bootstrapDefaultVersion) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(bootstrapUrl, forKey: .bootstrapUrl)
        try container.encode(bootstrapDefaultVersion, forKey: .bootstrapDefaultVersion)
    }
}

public struct GroupRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var members: [String]
    public var createdBy: String
    public var createdAt: Int64

    public init(id: String, name: String, members: [String], createdBy: String, createdAt: Int64) {
        self.id = id
        self.name = name
        self.members = members
        self.createdBy = createdBy
        self.createdAt = createdAt
    }
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
    /// Status text copied from their QR. It is not signed.
    public var about: String
    public var avatarJpegBase64: String?

    public var id: String { directId }

    private enum CodingKeys: String, CodingKey {
        case directId, name, bundle, fingerprint, verified, accepted, blocked, createdAt, about, avatarJpegBase64
    }

    public init(directId: String, name: String, bundle: String, fingerprint: String, verified: Bool = false, accepted: Bool = true, blocked: Bool = false, createdAt: Int64, about: String = "", avatarJpegBase64: String? = nil) {
        self.directId = directId
        self.name = name
        self.bundle = bundle
        self.fingerprint = fingerprint
        self.verified = verified
        self.accepted = accepted
        self.blocked = blocked
        self.createdAt = createdAt
        self.about = about
        self.avatarJpegBase64 = avatarJpegBase64
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        directId = try container.decode(String.self, forKey: .directId)
        name = try container.decode(String.self, forKey: .name)
        bundle = try container.decode(String.self, forKey: .bundle)
        fingerprint = try container.decode(String.self, forKey: .fingerprint)
        verified = try container.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        accepted = try container.decodeIfPresent(Bool.self, forKey: .accepted) ?? true
        blocked = try container.decodeIfPresent(Bool.self, forKey: .blocked) ?? false
        createdAt = try container.decode(Int64.self, forKey: .createdAt)
        about = try container.decodeIfPresent(String.self, forKey: .about) ?? ""
        avatarJpegBase64 = try container.decodeIfPresent(String.self, forKey: .avatarJpegBase64)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(directId, forKey: .directId)
        try container.encode(name, forKey: .name)
        try container.encode(bundle, forKey: .bundle)
        try container.encode(fingerprint, forKey: .fingerprint)
        try container.encode(verified, forKey: .verified)
        try container.encode(accepted, forKey: .accepted)
        try container.encode(blocked, forKey: .blocked)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(about, forKey: .about)
        try container.encodeIfPresent(avatarJpegBase64, forKey: .avatarJpegBase64)
    }
}

public enum Direction: String, Codable, Sendable {
    case outgoing = "OUTGOING"
    case incoming = "INCOMING"
}

public struct MessageReaction: Codable, Equatable, Sendable {
    public var emoji: String
    public var fromId: String

    public init(emoji: String, fromId: String) {
        self.emoji = emoji
        self.fromId = fromId
    }
}

extension Array where Element == MessageReaction {
    public func toggling(fromId: String, emoji: String) -> [MessageReaction] {
        if first(where: { $0.fromId == fromId })?.emoji == emoji {
            return filter { $0.fromId != fromId }
        }
        return filter { $0.fromId != fromId } + [MessageReaction(emoji: emoji, fromId: fromId)]
    }
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
    /// image, video, gif, sticker, or audio. Nil for a text message.
    public var mediaKind: String?
    public var mediaMime: String?
    public var mediaName: String?
    /// File name inside the media directory. The bytes are not in this snapshot.
    public var mediaFile: String?
    /// Incoming group messages: the member who wrote it.
    public var senderId: String?
    public var edited: Bool
    public var deleted: Bool
    public var forwarded: Bool
    public var reactions: [MessageReaction]

    private enum CodingKeys: String, CodingKey {
        case id, peerId, direction, body, createdAt, state, read, lastError, updatedAt, mediaKind, mediaMime, mediaName, mediaFile, senderId, edited, deleted, forwarded, reactions
    }

    public init(id: String, peerId: String, direction: Direction, body: String, createdAt: Int64, state: MessageState? = nil, read: Bool = false, lastError: String? = nil, updatedAt: Int64? = nil, mediaKind: String? = nil, mediaMime: String? = nil, mediaName: String? = nil, mediaFile: String? = nil, senderId: String? = nil, edited: Bool = false, deleted: Bool = false, forwarded: Bool = false, reactions: [MessageReaction] = []) {
        self.id = id
        self.peerId = peerId
        self.direction = direction
        self.body = body
        self.createdAt = createdAt
        self.state = state
        self.read = read
        self.lastError = lastError
        self.updatedAt = updatedAt ?? createdAt
        self.mediaKind = mediaKind
        self.mediaMime = mediaMime
        self.mediaName = mediaName
        self.mediaFile = mediaFile
        self.senderId = senderId
        self.edited = edited
        self.deleted = deleted
        self.forwarded = forwarded
        self.reactions = reactions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        peerId = try container.decode(String.self, forKey: .peerId)
        direction = try container.decode(Direction.self, forKey: .direction)
        body = try container.decode(String.self, forKey: .body)
        createdAt = try container.decode(Int64.self, forKey: .createdAt)
        state = try container.decodeIfPresent(MessageState.self, forKey: .state)
        read = try container.decodeIfPresent(Bool.self, forKey: .read) ?? false
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        updatedAt = try container.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? createdAt
        mediaKind = try container.decodeIfPresent(String.self, forKey: .mediaKind)
        mediaMime = try container.decodeIfPresent(String.self, forKey: .mediaMime)
        mediaName = try container.decodeIfPresent(String.self, forKey: .mediaName)
        mediaFile = try container.decodeIfPresent(String.self, forKey: .mediaFile)
        senderId = try container.decodeIfPresent(String.self, forKey: .senderId)
        edited = try container.decodeIfPresent(Bool.self, forKey: .edited) ?? false
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        forwarded = try container.decodeIfPresent(Bool.self, forKey: .forwarded) ?? false
        reactions = try container.decodeIfPresent([MessageReaction].self, forKey: .reactions) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(peerId, forKey: .peerId)
        try container.encode(direction, forKey: .direction)
        try container.encode(body, forKey: .body)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(state, forKey: .state)
        try container.encode(read, forKey: .read)
        try container.encodeIfPresent(lastError, forKey: .lastError)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(mediaKind, forKey: .mediaKind)
        try container.encodeIfPresent(mediaMime, forKey: .mediaMime)
        try container.encodeIfPresent(mediaName, forKey: .mediaName)
        try container.encodeIfPresent(mediaFile, forKey: .mediaFile)
        try container.encodeIfPresent(senderId, forKey: .senderId)
        try container.encode(edited, forKey: .edited)
        try container.encode(deleted, forKey: .deleted)
        try container.encode(forwarded, forKey: .forwarded)
        try container.encode(reactions, forKey: .reactions)
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
    /// Group fan-out: the local message this envelope belongs to.
    public var messageId: String?

    public init(id: String, peerId: String, kind: QueueKind, payload: String, attempts: Int = 0, nextAttemptAt: Int64, expiresAt: Int64, sentAt: Int64? = nil, lastError: String? = nil, messageId: String? = nil) {
        self.id = id
        self.peerId = peerId
        self.kind = kind
        self.payload = payload
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.expiresAt = expiresAt
        self.sentAt = sentAt
        self.lastError = lastError
        self.messageId = messageId
    }

    public func logicalId() -> String { messageId ?? id }
}

struct Snapshot: Codable {
    var version = 1
    var profile: Profile?
    var settings = Settings()
    var contacts: [ContactRecord] = []
    var messages: [MessageRecord] = []
    var queue: [QueueItem] = []
    var groups: [GroupRecord] = []

    private enum CodingKeys: String, CodingKey {
        case version, profile, settings, contacts, messages, queue, groups
    }

    init(version: Int = 1, profile: Profile? = nil, settings: Settings = Settings(), contacts: [ContactRecord] = [], messages: [MessageRecord] = [], queue: [QueueItem] = [], groups: [GroupRecord] = []) {
        self.version = version
        self.profile = profile
        self.settings = settings
        self.contacts = contacts
        self.messages = messages
        self.queue = queue
        self.groups = groups
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        profile = try container.decodeIfPresent(Profile.self, forKey: .profile)
        settings = try container.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
        contacts = try container.decodeIfPresent([ContactRecord].self, forKey: .contacts) ?? []
        messages = try container.decodeIfPresent([MessageRecord].self, forKey: .messages) ?? []
        queue = try container.decodeIfPresent([QueueItem].self, forKey: .queue) ?? []
        groups = try container.decodeIfPresent([GroupRecord].self, forKey: .groups) ?? []
    }
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
    private var groupOrder: [String]
    private var groupMap: [String: GroupRecord]
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
        groupOrder = snapshot.groups.map(\.id)
        groupMap = Dictionary(snapshot.groups.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
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
    public func removeMessage(_ id: String) {
        messageMap[id] = nil
        messageOrder.removeAll { $0 == id }
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
    public func removeQueuedForMessage(_ messageId: String) {
        for item in queue() where item.logicalId() == messageId {
            removeQueued(item.id)
        }
    }

    public func group(_ id: String) -> GroupRecord? { groupMap[id] }
    public func groups() -> [GroupRecord] { groupOrder.compactMap { groupMap[$0] } }
    public func putGroup(_ group: GroupRecord) {
        if groupMap[group.id] == nil { groupOrder.append(group.id) }
        groupMap[group.id] = group
    }
    public func removeGroup(_ id: String) {
        groupMap[id] = nil
        groupOrder.removeAll { $0 == id }
    }

    public func save() throws {
        guard let file, let key else { return }
        let snapshot = Snapshot(profile: profile, settings: settings, contacts: contacts(), messages: messages(), queue: queue(), groups: groups())
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

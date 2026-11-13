import Foundation

public struct DirectError: Error, Equatable, CustomStringConvertible {
    public enum Reason: String, Sendable {
        case noIdentity, invalidId, selfId, noBootstrap, bootstrapOffline, notFound, badBundle, notAccepted, blocked, rejected, invalidBootstrap, storage
    }

    public let reason: Reason
    public let message: String

    public init(_ reason: Reason, _ message: String) {
        self.reason = reason
        self.message = message
    }

    public var description: String { message }
}

public struct Conversation: Equatable, Identifiable, Sendable {
    public let peerId: String
    public let name: String
    public let lastBody: String?
    public let lastAt: Int64
    public let unread: Int
    /// An unknown sender's message waiting for Accept or Decline.
    public let request: Bool
    public let blocked: Bool
    public let group: Bool
    public let memberCount: Int

    public var id: String { peerId }

    public init(peerId: String, name: String, lastBody: String?, lastAt: Int64, unread: Int, request: Bool, blocked: Bool, group: Bool = false, memberCount: Int = 0) {
        self.peerId = peerId
        self.name = name
        self.lastBody = lastBody
        self.lastAt = lastAt
        self.unread = unread
        self.request = request
        self.blocked = blocked
        self.group = group
        self.memberCount = memberCount
    }
}

public struct InboundAlert: Equatable, Sendable {
    public let threadId: String
    public let title: String
    public let body: String
    public let messageId: String

    public init(threadId: String, title: String, body: String, messageId: String) {
        self.threadId = threadId
        self.title = title
        self.body = body
        self.messageId = messageId
    }
}

public struct NodeState: Equatable, Sendable {
    public var ready = false
    public var profile: Profile?
    public var bundle: String?
    public var bootstrapUrl: String?
    public var bootstrap = BootstrapStatus(phase: .notConfigured, url: nil)
    public var contacts: [ContactRecord] = []
    public var groups: [GroupRecord] = []
    public var conversations: [Conversation] = []
    public var messages: [String: [MessageRecord]] = [:]
    public var online: Set<String> = []
    public var connected: Set<String> = []
    public var pending = 0
    public var foreground = true
    public var networkAvailable = true
    public var storageError: String?
    public var call: CallSnapshot? = nil
    public var feed: [FeedItem] = []
    public var savedPosts: [String] = []
    public var discoverable = false
    public var suggestions: [SuggestedPerson] = []

    public init() {}
}

/// Everything DIRECT does on one device, with no UI and no platform types.
/// iOS supplies the Keychain secret store, the URLSession WebSocket, and the WebRTC transport.
@DirectActor
public final class DirectNode {
    public typealias TransportFactory = @DirectActor (BootstrapClient, String) -> PeerTransport

    public struct Timing {
        public var connectWaitMs: Int64 = 3_000
        public var lookupRetryMs: Int64 = 2_500
        public var idleWakeMs: Int64 = 30_000
        public var minWakeMs: Int64 = 50
        public var bootstrap = BootstrapClient.Timing()
        public init() {}
    }

    public private(set) var state = NodeState() {
        didSet { if state != oldValue { onState?(state) } }
    }

    /// Called on `DirectActor` after every change. The UI hops to the main actor.
    public var onState: ((NodeState) -> Void)?

    /// Media (microphone, camera, and the call's own peer connection) listens here.
    public var onCallEvent: ((CallEvent) -> Void)?

    /// A new inbound chat item. The app shows a notification when the UI is not on screen.
    public var onInboundAlert: ((InboundAlert) -> Void)?

    private var callPlain: String?
    private lazy var board: CallBoard = {
        let board = CallBoard()
        board.clock = { [weak self] in self?.clock() ?? 0 }
        board.selfId = { [weak self] in self?.keys?.directId }
        board.send = { [weak self] peer, note in await self?.sendCall(peer, note) ?? false }
        board.record = { [weak self] peer, id, outgoing, label, missed in self?.recordCall(peer, id, outgoing, label, missed) }
        board.changed = { [weak self] in self?.publish() }
        board.signal = { [weak self] event in self?.onCallEvent?(event) }
        return board
    }()

    private let secrets: SecretStore
    private let storeFile: URL?
    private let transportFactory: TransportFactory
    private let clock: () -> Int64
    private let random: () -> Double
    private let ttlMs: Int64
    private let timing: Timing
    private let vault: IdentityVault
    private let bootstrap: BootstrapClient
    private let wake = WakeSignal()

    private var store = LocalStore.inMemory()
    private var keys: IdentityKeys?
    private var engine: DeliveryEngine?
    private var transport: PeerTransport?
    private var loop: Task<Void, Never>?
    private var closed = false
    private var online = Set<String>()
    private var foreground = true
    private var networkAvailable = true
    private var mediaDir: URL?
    private var cachedBundle: (key: String, value: String)?
    private var suggested: [SuggestedPerson] = []
    private lazy var links = Links(node: self)
    private lazy var listener = Listener(node: self)

    public init(
        secrets: SecretStore,
        storeFile: URL?,
        sockets: WebSocketFactory,
        transportFactory: @escaping TransportFactory,
        clock: @escaping () -> Int64 = wallClockMs,
        random: @escaping () -> Double = { Double.random(in: 0..<1) },
        ttlMs: Int64 = DeliveryEngine.defaultTtlMs,
        timing: Timing = Timing()
    ) {
        self.secrets = secrets
        self.storeFile = storeFile
        self.transportFactory = transportFactory
        self.clock = clock
        self.random = random
        self.ttlMs = ttlMs
        self.timing = timing
        vault = IdentityVault(secrets)
        bootstrap = BootstrapClient(sockets: sockets, timing: timing.bootstrap)
    }

    public func start() async {
        guard !state.ready else { return }
        let parent = storeFile?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
        let stem = storeFile?.deletingPathExtension().lastPathComponent ?? "memory"
        let directory = parent.appendingPathComponent("direct-media-\(stem)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        mediaDir = directory
        do {
            store = try storeFile.map { try LocalStore.open(file: $0, key: try vault.storageKey()) } ?? LocalStore.inMemory()
        } catch {
            state.ready = true
            state.storageError = "The local store could not be opened with this device's key. Nothing was erased."
            return
        }
        if let loaded = try? vault.load(), let profile = store.profile, profile.directId == loaded.directId {
            activate(loaded)
        }
        bootstrap.addStatusHandler { [weak self] status in
            if status.isOpen {
                self?.wake.fire()
                Task { @DirectActor in await self?.refreshSuggestions() }
            }
            self?.publish()
        }
        bootstrap.onPresence = { [weak self] id, isOnline in self?.presence(id, isOnline) }
        let chosen = BootstrapUrl.applyHostedDefault(stored: store.settings.bootstrapUrl, version: store.settings.bootstrapDefaultVersion)
        if store.settings.bootstrapUrl != chosen.url || store.settings.bootstrapDefaultVersion != chosen.version {
            store.settings.bootstrapUrl = chosen.url
            store.settings.bootstrapDefaultVersion = chosen.version
            try? store.save()
        }
        bootstrap.configure(chosen.url)
        bootstrap.start()
        state.ready = true
        loop = Task { @DirectActor [weak self] in await self?.runLoop() }
        publish()
    }

    /// Creates a new identity, stores the seed in the Keychain, and returns the recovery phrase.
    public func createIdentity(_ displayName: String) throws -> String {
        let name = try cleanName(displayName)
        let (created, phrase) = try vault.create()
        store.profile = Profile(name: name, deviceId: Encoding.newDeviceId(), directId: created.directId)
        try store.save()
        activate(created)
        publish()
        return phrase
    }

    public func restoreIdentity(_ phrase: String, displayName: String) throws {
        let name = try cleanName(displayName)
        let restored: IdentityKeys
        do {
            restored = try vault.restore(phrase)
        } catch let error as IdentityError {
            throw DirectError(.rejected, error.message)
        }
        store.profile = Profile(name: name, deviceId: Encoding.newDeviceId(), directId: restored.directId)
        try store.save()
        activate(restored)
        publish()
    }

    public func recoveryPhrase() throws -> String? { try vault.recoveryPhrase() }

    /// Normalizes and saves the bootstrap address. Both phones must end up with the same value.
    @discardableResult
    public func setBootstrap(_ input: String) throws -> String {
        switch BootstrapUrl.normalize(input) {
        case let .failure(error):
            throw DirectError(.invalidBootstrap, error.message)
        case let .success(url):
            store.settings.bootstrapUrl = url
            try store.save()
            bootstrap.configure(url)
            publish()
            return url
        }
    }

    /// Opt in to be findable on this bootstrap: suggested contacts and lookup by DIRECT ID. Off by default.
    public func setDiscoverable(_ on: Bool) throws {
        store.settings.discoverable = on
        try store.save()
        announceSelf()
        publish()
    }

    /// Reloads people who chose to be listed on this bootstrap.
    public func refreshSuggestions() async {
        suggested = await bootstrap.suggest()
        publish()
    }

    @discardableResult
    public func addContact(_ input: String) async throws -> ContactRecord {
        guard let me = keys else { throw DirectError(.noIdentity, "Create your identity first.") }
        guard let directId = DirectIds.normalize(input) else {
            throw DirectError(.invalidId, "A DIRECT ID looks like dir_ followed by 16 letters and numbers.")
        }
        guard directId != me.directId else { throw DirectError(.selfId, "This DIRECT ID belongs to this phone.") }
        if var existing = store.contact(directId) {
            existing.accepted = true
            existing.blocked = false
            store.putContact(existing)
            try store.save()
            refreshWatch()
            publish()
            return existing
        }
        guard let url = bootstrap.url else {
            throw DirectError(.noBootstrap, "Set the bootstrap first. Phones use \(BootstrapUrl.defaultUrl) unless you save a different address.")
        }
        if !bootstrap.status.isOpen {
            bootstrap.reconnectNow()
            _ = await bootstrap.waitUntilOpen(timeoutMs: timing.connectWaitMs)
        }
        guard bootstrap.status.isOpen else {
            throw DirectError(.bootstrapOffline, "This phone is not connected to the bootstrap at \(url). Check that the signaling server is running and that both phones use this address.")
        }
        var published: String?
        let deadline = clock() + timing.lookupRetryMs
        while published == nil {
            published = await bootstrap.lookup(directId)
            if published != nil || clock() >= deadline || !bootstrap.status.isOpen { break }
            await sleepMs(300)
        }
        guard let published else {
            throw DirectError(.notFound, "No phone on \(url) is publishing \(directId). Open DIRECT on the other phone with this same bootstrap address.")
        }
        return try saveContact(try verifiedBundle(published, expected: directId), accepted: true)
    }

    /// Adds a contact from the bundle in their QR code, with no bootstrap involved.
    @discardableResult
    public func addContactBundle(_ serialized: String) throws -> ContactRecord {
        guard let me = keys else { throw DirectError(.noIdentity, "Create your identity first.") }
        let bundle: PublicBundle
        do {
            bundle = try Bundles.parse(serialized)
        } catch {
            throw DirectError(.badBundle, (error as? IdentityError)?.message ?? "That identity bundle could not be verified.")
        }
        guard bundle.directId != me.directId else { throw DirectError(.selfId, "This DIRECT ID belongs to this phone.") }
        return try saveContact(bundle, accepted: true)
    }

    @discardableResult
    public func send(_ peerId: String, _ body: String) throws -> MessageRecord {
        let message: MessageRecord
        do {
            if GroupNotes.isGroupId(peerId) {
                guard let group = store.group(peerId) else { throw DirectError(.notFound, "That group is not on this phone.") }
                guard let selfId = keys?.directId else { throw DirectError(.noIdentity, "Create your identity first.") }
                message = try requireEngine().queueGroupText(group, selfId, body)
            } else {
                guard let contact = store.contact(peerId) else { throw DirectError(.notFound, "That contact is not on this phone.") }
                guard !contact.blocked else { throw DirectError(.blocked, "This contact is blocked.") }
                guard contact.accepted else { throw DirectError(.notAccepted, "Accept the message request before replying.") }
                message = try requireEngine().queueText(peerId, body)
            }
        } catch let error as DeliveryRejected {
            throw DirectError(.rejected, error.message)
        }
        publish()
        wake.fire()
        return message
    }

    /// Creates a group of accepted contacts and seals an invite to each member.
    @discardableResult
    public func createGroup(name: String, memberIds: [String]) throws -> GroupRecord {
        guard let selfKeys = keys else { throw DirectError(.noIdentity, "Create your identity first.") }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DirectError(.rejected, "Enter a group name.") }
        guard trimmed.utf16.count <= Bundles.maxNameUtf16 else { throw DirectError(.rejected, "Use 32 characters or fewer.") }
        var unique: [String] = [selfKeys.directId]
        var seen: Set<String> = [selfKeys.directId]
        for raw in memberIds {
            guard let id = DirectIds.normalize(raw) else { throw DirectError(.invalidId, "That DIRECT ID is not valid.") }
            if id == selfKeys.directId || !seen.insert(id).inserted { continue }
            guard let contact = store.contact(id) else { throw DirectError(.notFound, "Add each member as a contact first.") }
            if contact.blocked { throw DirectError(.blocked, "Unblock \(contact.name) before adding them.") }
            if !contact.accepted { throw DirectError(.notAccepted, "Accept \(contact.name) before adding them.") }
            unique.append(id)
        }
        guard unique.count >= 2 else { throw DirectError(.rejected, "Add at least one contact.") }
        guard unique.count <= GroupNotes.maxMembers else { throw DirectError(.rejected, "A group can have \(GroupNotes.maxMembers) people.") }
        let group = GroupRecord(
            id: Encoding.newId("grp"),
            name: trimmed,
            members: unique,
            createdBy: selfKeys.directId,
            createdAt: clock()
        )
        store.putGroup(group)
        try store.save()
        try requireEngine().queueGroupInvite(group, selfKeys.directId)
        publish()
        wake.fire()
        return group
    }

    /// Photo, video, GIF, sticker, or voice note. The bytes are sealed and queued on this phone.
    @discardableResult
    public func sendMedia(_ peerId: String, kind: String, mime: String, name: String, bytes: Data, caption: String) throws -> MessageRecord {
        let message: MessageRecord
        do {
            if GroupNotes.isGroupId(peerId) {
                guard let group = store.group(peerId) else { throw DirectError(.notFound, "That group is not on this phone.") }
                guard let selfId = keys?.directId else { throw DirectError(.noIdentity, "Create your identity first.") }
                message = try requireEngine().queueGroupMedia(group, selfId, kind: kind, mime: mime, name: name, bytes: bytes, caption: caption)
            } else {
                guard let contact = store.contact(peerId) else { throw DirectError(.notFound, "That contact is not on this phone.") }
                guard !contact.blocked else { throw DirectError(.blocked, "This contact is blocked.") }
                guard contact.accepted else { throw DirectError(.notAccepted, "Accept the message request before replying.") }
                message = try requireEngine().queueMedia(peerId, kind: kind, mime: mime, name: name, bytes: bytes, caption: caption)
            }
        } catch let error as DeliveryRejected {
            throw DirectError(.rejected, error.message)
        }
        publish()
        wake.fire()
        return message
    }

    /// Rewrites an outgoing text bubble. Recipients get a sealed edit note.
    @discardableResult
    public func editMessage(_ messageId: String, _ body: String) throws -> MessageRecord {
        let message: MessageRecord
        do {
            message = try requireEngine().editText(messageId, body)
        } catch let error as DeliveryRejected {
            throw DirectError(.rejected, error.message)
        }
        publish()
        wake.fire()
        return message
    }

    /// `forEveryone` replaces the bubble on every phone that has it. Otherwise it is removed only on this phone.
    @discardableResult
    public func deleteMessage(_ messageId: String, forEveryone: Bool) throws -> MessageRecord? {
        let message: MessageRecord?
        do {
            message = try requireEngine().deleteMessage(messageId, forEveryone: forEveryone)
        } catch let error as DeliveryRejected {
            throw DirectError(.rejected, error.message)
        }
        publish()
        wake.fire()
        return message
    }

    /// Sends a copy of a bubble into another conversation.
    @discardableResult
    public func forwardMessage(_ messageId: String, to toPeerId: String) throws -> MessageRecord {
        guard let selfId = keys?.directId else { throw DirectError(.noIdentity, "Create your identity first.") }
        if GroupNotes.isGroupId(toPeerId) {
            guard store.group(toPeerId) != nil else { throw DirectError(.notFound, "That group is not on this phone.") }
        } else {
            guard let contact = store.contact(toPeerId) else { throw DirectError(.notFound, "That contact is not on this phone.") }
            guard !contact.blocked else { throw DirectError(.blocked, "This contact is blocked.") }
            guard contact.accepted else { throw DirectError(.notAccepted, "Accept the message request before forwarding.") }
        }
        let message: MessageRecord
        do {
            message = try requireEngine().forward(messageId, to: toPeerId, selfId: selfId)
        } catch let error as DeliveryRejected {
            throw DirectError(.rejected, error.message)
        }
        publish()
        wake.fire()
        return message
    }

    /// Adds or clears an emoji on a bubble. Recipients get a sealed react note.
    @discardableResult
    public func react(_ messageId: String, _ emoji: String) throws -> MessageRecord {
        let message: MessageRecord
        do {
            message = try requireEngine().react(messageId, emoji)
        } catch let error as DeliveryRejected {
            throw DirectError(.rejected, error.message)
        }
        publish()
        wake.fire()
        return message
    }

    /// Rings an accepted contact. The invite is sealed and written now; it is not queued.
    public func placeCall(_ peerId: String, video: Bool) async throws {
        guard keys != nil else { throw DirectError(.noIdentity, "Create your identity first.") }
        do {
            if GroupNotes.isGroupId(peerId) {
                guard let group = store.group(peerId) else { throw DirectError(.notFound, "That group is not on this phone.") }
                let selfId = keys!.directId
                let members = group.members.filter { id in
                    id != selfId && store.contact(id).map { $0.accepted && !$0.blocked } == true
                }
                guard !members.isEmpty else { throw DirectError(.rejected, "No reachable members in this group.") }
                try await board.place(peerId: peerId, video: video, id: Encoding.newId("call"), members: members)
            } else {
                guard let contact = store.contact(peerId) else { throw DirectError(.notFound, "That contact is not on this phone.") }
                if contact.blocked { throw DirectError(.blocked, "This contact is blocked.") }
                if !contact.accepted { throw DirectError(.notAccepted, "Accept the message request before calling.") }
                try await board.place(peerId: peerId, video: video, id: Encoding.newId("call"))
            }
        } catch let error as CallRejected {
            throw DirectError(.rejected, error.message)
        }
    }

    public func acceptCall() async { await board.accept() }

    public func endCall() async { await board.end() }

    public func dismissCall() { board.dismiss() }

    public func relayOffer(_ sdp: String, peerId: String? = nil) async { await board.relayOffer(sdp, toPeer: peerId) }

    public func relayAnswer(_ sdp: String, peerId: String? = nil) async { await board.relayAnswer(sdp, toPeer: peerId) }

    public func relayIce(_ candidate: String, _ mid: String, _ line: Int, peerId: String? = nil) async { await board.relayIce(candidate, mid, line, toPeer: peerId) }

    public func markCallLive() { board.markLive() }

    public func setCallMuted(_ muted: Bool) { board.update(muted: muted) }

    public func setCallSpeaker(_ speaker: Bool) { board.update(speaker: speaker) }

    public func setCallCamera(_ enabled: Bool) { board.update(camera: enabled) }

    public func readMedia(_ messageId: String) -> Data? {
        guard let name = store.message(messageId)?.mediaFile, let mediaDir else { return nil }
        return try? Data(contentsOf: mediaDir.appendingPathComponent(name))
    }

    public func readFeed(_ id: String) -> Data? {
        guard let name = store.feed(id)?.mediaFile, let mediaDir else { return nil }
        return try? Data(contentsOf: mediaDir.appendingPathComponent(name))
    }

    @discardableResult
    public func publishFeed(channel: String, kind: String, mime: String, name: String, bytes: Data, caption: String = "", tags: [String] = []) throws -> FeedItem {
        let item: FeedItem
        do {
            item = try requireEngine().queueFeed(channel: channel, kind: kind, mime: mime, name: name, bytes: bytes, caption: caption, tags: tags)
        } catch let error as DeliveryRejected {
            throw DirectError(.rejected, error.message)
        }
        publish()
        wake.fire()
        return item
    }

    public func deleteFeed(_ id: String) throws {
        let item = store.feed(id)
        do {
            try requireEngine().deleteFeed(id)
        } catch let error as DeliveryRejected {
            throw DirectError(.rejected, error.message)
        }
        if let name = item?.mediaFile, let mediaDir {
            try? FileManager.default.removeItem(at: mediaDir.appendingPathComponent(name))
        }
        publish()
        wake.fire()
    }

    public func saveFeed(_ id: String) throws {
        do {
            try requireEngine().saveFeed(id)
        } catch let error as DeliveryRejected {
            throw DirectError(.rejected, error.message)
        }
        publish()
    }

    public func likeFeed(_ id: String) throws {
        try reactFeed(id, "❤️")
    }

    public func reactFeed(_ id: String, _ emoji: String) throws {
        do {
            try requireEngine().reactFeed(id, emoji)
        } catch let error as DeliveryRejected {
            throw DirectError(.rejected, error.message)
        }
        publish()
        wake.fire()
    }

    @discardableResult
    public func forwardFeed(_ id: String, to toPeerId: String) throws -> MessageRecord {
        guard keys?.directId != nil else { throw DirectError(.noIdentity, "Create your identity first.") }
        if GroupNotes.isGroupId(toPeerId) {
            guard store.group(toPeerId) != nil else { throw DirectError(.notFound, "That group is not on this phone.") }
        } else {
            guard let contact = store.contact(toPeerId) else { throw DirectError(.notFound, "That contact is not on this phone.") }
            guard !contact.blocked else { throw DirectError(.blocked, "This contact is blocked.") }
            guard contact.accepted else { throw DirectError(.notAccepted, "Accept the message request before forwarding.") }
        }
        let message: MessageRecord
        do {
            message = try requireEngine().forwardFeed(id, to: toPeerId)
        } catch let error as DeliveryRejected {
            throw DirectError(.rejected, error.message)
        }
        publish()
        wake.fire()
        return message
    }

    public func commentFeed(_ id: String, _ body: String) throws {
        do {
            try requireEngine().commentFeed(id, body)
        } catch let error as DeliveryRejected {
            throw DirectError(.rejected, error.message)
        }
        publish()
        wake.fire()
    }

    public func markStoriesSeen(_ ownerId: String) throws {
        try requireEngine().markFeedSeen(ownerId)
        publish()
    }

    public func setStatus(_ text: String) throws {
        guard var profile = store.profile else { throw DirectError(.noIdentity, "Create your identity first.") }
        profile.status = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        store.profile = profile
        try store.save()
        try? engine?.shareProfile()
        publish()
        wake.fire()
    }

    public func setAvatar(_ jpeg: Data) throws {
        guard var profile = store.profile else { throw DirectError(.noIdentity, "Create your identity first.") }
        guard jpeg.count >= 3, jpeg.count <= MediaNotes.maxAvatarBytes, jpeg[0] == 0xFF, jpeg[1] == 0xD8 else {
            throw DirectError(.rejected, "Choose a smaller JPEG photo.")
        }
        profile.avatarJpegBase64 = Encoding.base64Url(jpeg)
        store.profile = profile
        try store.save()
        try? engine?.shareProfile()
        publish()
        wake.fire()
    }

    public func clearAvatar() throws {
        guard var profile = store.profile else { return }
        profile.avatarJpegBase64 = nil
        store.profile = profile
        try store.save()
        try? engine?.shareProfile()
        publish()
        wake.fire()
    }

    /// Adds the signed bundle inside a QR or share card, keeps the unsigned status and photo, and saves the server address when the card includes one.
    @discardableResult
    public func addFromShare(_ text: String) throws -> ContactRecord {
        let card = ProfileCards.parse(text)
        let contact = try addContactBundle(card.bundle)
        if case let .success(url) = BootstrapUrl.normalize(card.bootstrap), url != store.settings.bootstrapUrl {
            store.settings.bootstrapUrl = url
            bootstrap.configure(url)
        }
        var updated = contact
        updated.about = String(card.status.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        if let avatar = card.avatarJpeg, avatar.count >= 3, avatar.count <= MediaNotes.maxAvatarBytes, avatar[0] == 0xFF, avatar[1] == 0xD8 {
            updated.avatarJpegBase64 = Encoding.base64Url(avatar)
        }
        store.putContact(updated)
        try store.save()
        refreshWatch()
        publish()
        return store.contact(contact.directId) ?? updated
    }

    public func acceptRequest(_ peerId: String) throws {
        guard var contact = store.contact(peerId) else { return }
        contact.accepted = true
        contact.blocked = false
        store.putContact(contact)
        try store.save()
        try requireEngine().markRead(peerId)
        refreshWatch()
        try? engine?.shareProfile(peerId: peerId)
        try? engine?.shareFeed(peerId: peerId)
        publish()
        wake.fire()
    }

    /// Declining blocks the sender. Later envelopes from that DIRECT ID are dropped unread.
    public func declineRequest(_ peerId: String) throws { try block(peerId) }

    public func block(_ peerId: String) throws {
        guard var contact = store.contact(peerId) else { return }
        contact.blocked = true
        store.putContact(contact)
        try store.save()
        try engine?.rejectPeer(peerId)
        transport?.close(peerId)
        refreshWatch()
        publish()
    }

    public func removeContact(_ peerId: String) throws {
        try engine?.rejectPeer(peerId)
        for item in store.feed() where item.ownerId == peerId {
            store.removeFeed(item.id)
            if let mediaDir {
                try? FileManager.default.removeItem(at: mediaDir.appendingPathComponent(item.mediaFile))
            }
        }
        store.removeContact(peerId)
        try store.save()
        transport?.close(peerId)
        refreshWatch()
        publish()
    }

    public func setVerified(_ peerId: String, _ verified: Bool) throws {
        guard var contact = store.contact(peerId) else { return }
        contact.verified = verified
        store.putContact(contact)
        try store.save()
        publish()
    }

    /// Opening an accepted conversation sends read receipts, which move the sender to acknowledged.
    public func openConversation(_ peerId: String) throws {
        if try requireEngine().markRead(peerId) > 0 { wake.fire() }
        publish()
    }

    public func retry(_ messageId: String) throws {
        if try requireEngine().retry(messageId) { wake.fire() }
        publish()
    }

    public func onForeground() {
        foreground = true
        if !bootstrap.status.isOpen { bootstrap.reconnectNow() }
        publish()
        wake.fire()
    }

    public func onBackground() {
        foreground = false
        try? store.save()
        publish()
    }

    public func onNetworkAvailable() {
        networkAvailable = true
        bootstrap.reconnectNow()
        publish()
        wake.fire()
    }

    public func onNetworkLost() {
        networkAvailable = false
        publish()
    }

    /// One bounded delivery pass for a background task (BGTaskScheduler or WorkManager).
    /// Waits for the bootstrap, flushes, then waits for receipts until `budgetMs` runs out.
    /// Returns the number of messages still waiting for a receipt.
    public func backgroundFlush(budgetMs: Int64) async -> Int {
        await start()
        let until = clock() + budgetMs
        _ = await bootstrap.waitUntilOpen(timeoutMs: budgetMs / 3)
        try? await engine?.flush()
        publish()
        while clock() < until, engine?.awaitingReceipt() == true { await sleepMs(500) }
        try? store.save()
        return engine?.pendingCount() ?? 0
    }

    public func close() {
        closed = true
        loop?.cancel()
        wake.fire()
        transport?.closeAll()
        bootstrap.stop()
        try? store.save()
    }

    private func activate(_ identity: IdentityKeys) {
        transport?.closeAll()
        keys = identity
        guard let profile = store.profile else { return }
        let deviceId = profile.deviceId
        engine = DeliveryEngine(
            store: store,
            identity: { [weak self] in self?.keys.map { ($0, deviceId) } },
            links: links, clock: clock, random: random, ttlMs: ttlMs, mediaDirectory: mediaDir
        )
        try? engine?.recover()
        engine?.onCall = { [weak self] text in self?.callPlain = text }
        engine?.onInbound = { [weak self] message in self?.notifyInbound(message) }
        let next = transportFactory(bootstrap, identity.directId)
        next.setListener(listener)
        transport = next
        announceSelf()
        refreshWatch()
        wake.fire()
    }

    @DirectActor
    private final class Links: PeerLinks {
        weak var node: DirectNode?
        init(node: DirectNode) { self.node = node }

        func isConnected(_ peerId: String) -> Bool { node?.transport?.isConnected(peerId) == true }

        func connect(_ peerId: String) async -> Bool {
            guard let node, node.networkAvailable, let transport = node.transport else { return false }
            if !node.bootstrap.status.isOpen, !transport.isConnected(peerId) { return false }
            return await transport.connect(peerId)
        }

        func send(_ peerId: String, _ payload: Data) async -> Bool {
            await node?.transport?.send(peerId, payload) == true
        }
    }

    @DirectActor
    private final class Listener: PeerListener {
        weak var node: DirectNode?
        init(node: DirectNode) { self.node = node }

        func onPeerConnected(_ peerId: String) { node?.presence(peerId, true) }

        func onPeerData(_ peerId: String, _ payload: Data) {
            Task { @DirectActor [weak node] in await node?.incoming(peerId, payload) }
        }

        func onPeerClosed(_ peerId: String) { node?.publish() }
    }

    private func incoming(_ peerId: String, _ payload: Data) async {
        guard let me = keys, let header = Envelopes.peek(payload), header.from == peerId, header.to == me.directId else { return }
        if store.contact(peerId) == nil {
            // Unknown sender: they are online right now, so their signed bundle is on the bootstrap.
            // Store the message as a request. If the lookup fails, no ack is sent and the sender retries.
            guard let published = await bootstrap.lookup(peerId), let bundle = try? verifiedBundle(published, expected: peerId) else { return }
            if store.contact(peerId) == nil { _ = try? saveContact(bundle, accepted: false) }
        }
        callPlain = nil
        _ = try? requireEngine().receive(peerId, payload)
        if let plain = callPlain { await board.onRemote(peerId, plain) }
        publish()
        wake.fire()
    }

    private func presence(_ peerId: String, _ isOnline: Bool) {
        if isOnline {
            online.insert(peerId)
            try? engine?.peerOnline(peerId)
            wake.fire()
        } else {
            online.remove(peerId)
        }
        publish()
    }

    private func runLoop() async {
        while !closed, !Task.isCancelled {
            try? await engine?.flush()
            await board.tick()
            publish()
            let engineWait: Int64
            if let next = engine?.nextWakeAt() {
                engineWait = min(max(next - clock(), timing.minWakeMs), timing.idleWakeMs)
            } else {
                engineWait = timing.idleWakeMs
            }
            let wait: Int64
            if let until = board.ringUntil {
                wait = min(engineWait, max(until - clock(), timing.minWakeMs))
            } else {
                wait = engineWait
            }
            await wake.wait(timeoutMs: wait)
        }
    }

    private func saveContact(_ bundle: PublicBundle, accepted: Bool) throws -> ContactRecord {
        let existing = store.contact(bundle.directId)
        let contact = ContactRecord(
            directId: bundle.directId,
            name: bundle.name.isEmpty ? bundle.directId : bundle.name,
            bundle: bundle.encode(),
            fingerprint: bundle.fingerprint,
            verified: existing?.verified == true && existing?.fingerprint == bundle.fingerprint,
            accepted: accepted || existing?.accepted == true,
            blocked: existing?.blocked == true,
            createdAt: existing?.createdAt ?? clock(),
            about: existing?.about ?? "",
            avatarJpegBase64: existing?.avatarJpegBase64
        )
        store.putContact(contact)
        try store.save()
        refreshWatch()
        if contact.accepted, !contact.blocked {
            try? engine?.shareProfile(peerId: contact.directId)
            try? engine?.shareFeed(peerId: contact.directId)
        }
        publish()
        wake.fire()
        return contact
    }

    private func verifiedBundle(_ serialized: String, expected: String) throws -> PublicBundle {
        let bundle: PublicBundle
        do {
            bundle = try Bundles.parse(serialized)
        } catch {
            throw DirectError(.badBundle, (error as? IdentityError)?.message ?? "That identity bundle could not be verified.")
        }
        guard bundle.directId == expected else { throw DirectError(.badBundle, "The bootstrap returned a bundle for a different DIRECT ID.") }
        return bundle
    }

    private func refreshWatch() {
        bootstrap.watch(store.contacts().filter { !$0.blocked }.map(\.directId))
    }

    private func requireEngine() throws -> DeliveryEngine {
        guard let engine else { throw DirectError(.noIdentity, "Create your identity first.") }
        return engine
    }

    private func cleanName(_ displayName: String) throws -> String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw DirectError(.rejected, "Enter a display name.") }
        guard name.utf16.count <= Bundles.maxNameUtf16 else { throw DirectError(.rejected, "Use 32 characters or fewer.") }
        return name
    }

    /// CryptoKit Ed25519 signatures are randomized, so the bundle is signed once per profile.
    private func currentBundle() -> String? {
        guard let identity = keys, let profile = store.profile else { return nil }
        let key = "\(identity.directId)|\(profile.name)|\(profile.deviceId)"
        if let cachedBundle, cachedBundle.key == key { return cachedBundle.value }
        guard let encoded = try? Bundles.create(keys: identity, displayName: profile.name, deviceId: profile.deviceId).encode() else { return nil }
        cachedBundle = (key, encoded)
        return encoded
    }

    private static func previewBody(_ message: MessageRecord) -> String? {
        if message.deleted { return "This message was deleted" }
        if message.feedPostId != nil {
            let caption = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
            return caption.isEmpty ? "Post" : "Post · \(caption)"
        }
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { return message.body }
        return MediaNotes.label(message.mediaKind)
    }

    private func publish() {
        let identity = keys
        let contacts = store.contacts()
        var byPeer: [String: [MessageRecord]] = [:]
        for message in store.messages() { byPeer[message.peerId, default: []].append(message) }
        for (peer, list) in byPeer { byPeer[peer] = list.sorted { $0.createdAt < $1.createdAt } }
        let contactConversations = contacts.compactMap { contact -> Conversation? in
            let thread = byPeer[contact.directId] ?? []
            if contact.blocked && !contact.accepted { return nil }
            if thread.isEmpty && !contact.accepted { return nil }
            return Conversation(
                peerId: contact.directId,
                name: contact.name,
                lastBody: thread.last.flatMap(Self.previewBody),
                lastAt: thread.last?.createdAt ?? contact.createdAt,
                unread: thread.filter { $0.direction == .incoming && !$0.read }.count,
                request: !contact.accepted && !contact.blocked,
                blocked: contact.blocked
            )
        }
        let groups = store.groups()
        let groupConversations = groups.map { group -> Conversation in
            let thread = byPeer[group.id] ?? []
            return Conversation(
                peerId: group.id,
                name: group.name,
                lastBody: thread.last.flatMap(Self.previewBody),
                lastAt: thread.last?.createdAt ?? group.createdAt,
                unread: thread.filter { $0.direction == .incoming && !$0.read }.count,
                request: false,
                blocked: false,
                group: true,
                memberCount: group.members.count
            )
        }
        let conversations = (contactConversations + groupConversations).sorted { $0.lastAt > $1.lastAt }
        let dropped = store.pruneFeed(clock())
        if !dropped.isEmpty {
            for item in dropped {
                if let mediaDir {
                    try? FileManager.default.removeItem(at: mediaDir.appendingPathComponent(item.mediaFile))
                }
            }
            try? store.save()
        }
        var next = state
        next.profile = identity != nil ? store.profile : nil
        next.bundle = identity != nil ? currentBundle() : nil
        next.bootstrapUrl = store.settings.bootstrapUrl
        next.bootstrap = bootstrap.status
        next.contacts = contacts.sorted { $0.name.lowercased() < $1.name.lowercased() }
        next.groups = groups
        next.conversations = conversations
        next.messages = byPeer
        next.online = online
        next.connected = transport?.connectedPeers() ?? []
        next.pending = engine?.pendingCount() ?? 0
        next.foreground = foreground
        next.networkAvailable = networkAvailable
        next.call = board.snapshot
        next.feed = store.feed().sorted { $0.createdAt > $1.createdAt }
        next.savedPosts = store.savedPosts()
        next.discoverable = store.settings.discoverable
        let known = Set(contacts.map(\.directId))
        next.suggestions = suggested.filter { person in
            person.directId != identity?.directId && !known.contains(person.directId)
        }
        state = next
    }

    private func announceSelf() {
        guard let identity = keys, let bundle = currentBundle() else { return }
        bootstrap.announce(directId: identity.directId, bundle: bundle, signProof: { [weak self] nonce in
            guard let keys = self?.keys else { return "" }
            return Encoding.base64Url(keys.sign(SignalProof.message(nonce: nonce, directId: keys.directId)))
        }, discoverable: store.settings.discoverable)
    }

    private func sendCall(_ peerId: String, _ note: CallNotes.Note) async -> Bool {
        guard let bytes = engine?.sealCall(peerId, CallNotes.encode(note)) else { return false }
        if links.isConnected(peerId) == false, await links.connect(peerId) == false { return false }
        return await links.send(peerId, bytes)
    }

    private func recordCall(_ peerId: String, _ id: String, _ outgoing: Bool, _ label: String, _ missed: Bool) {
        let now = clock()
        let message = MessageRecord(
            id: id, peerId: peerId, direction: outgoing ? .outgoing : .incoming,
            body: label, createdAt: now, read: !missed, mediaKind: "call"
        )
        store.putMessage(message)
        try? store.save()
        if !outgoing && missed { notifyInbound(message) }
    }

    private func notifyInbound(_ message: MessageRecord) {
        let threadId = message.peerId
        let group = store.group(threadId)
        let sender = store.contact(message.senderId ?? threadId)
        let title = group?.name ?? sender?.name ?? threadId
        let body: String
        if message.mediaKind == "group" || message.mediaKind == "call" {
            body = message.body
        } else if let kind = message.mediaKind, !kind.isEmpty {
            body = MediaNotes.label(kind) ?? "Attachment"
        } else {
            let trimmed = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
            body = String((trimmed.isEmpty ? "New message" : trimmed).prefix(140))
        }
        onInboundAlert?(InboundAlert(threadId: threadId, title: title, body: body, messageId: message.id))
    }
}

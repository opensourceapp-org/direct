import Foundation

/// Moves envelope bytes to a peer. Implemented by the WebRTC data channel on each platform.
@DirectActor
public protocol PeerLinks: AnyObject {
    func isConnected(_ peerId: String) -> Bool
    /// Opens a direct channel if needed. False when the peer cannot be reached now.
    func connect(_ peerId: String) async -> Bool
    /// Writes to an open channel. True means the bytes were handed to the channel, not that they arrived.
    func send(_ peerId: String, _ payload: Data) async -> Bool
}

public struct DeliveryRejected: Error, Equatable {
    public let message: String
}

public enum ReceiveOutcome: Equatable {
    case stored, duplicate, receipt, ignored
}

/// Outgoing envelopes are sealed and persisted before any network attempt, and stay in the
/// queue until a signed receipt arrives or they expire. Writing to a channel is `sent`, not delivered.
@DirectActor
public final class DeliveryEngine {
    nonisolated public static let defaultTtlMs: Int64 = 7 * 24 * 60 * 60 * 1000
    nonisolated public static let receiptTimeoutMsDefault: Int64 = 20_000
    nonisolated public static let maxBody = 8_000

    private let store: LocalStore
    private let identity: () -> (IdentityKeys, String)?
    private let links: PeerLinks
    private let clock: () -> Int64
    private let random: () -> Double
    public let ttlMs: Int64
    public let receiptTimeoutMs: Int64
    private let mediaDirectory: URL?
    private let mediaChunkBytes: Int
    private var flushing = false
    private var rerun = false
    private var bundles: [String: PublicBundle] = [:]

    /// Plaintext of a call signal, invoked on DirectActor before `receive` returns.
    public var onCall: ((String) -> Void)?

    /// A new incoming chat message, photo, or group invite the UI can turn into a notification.
    public var onInbound: ((MessageRecord) -> Void)?

    public init(
        store: LocalStore,
        identity: @escaping () -> (IdentityKeys, String)?,
        links: PeerLinks,
        clock: @escaping () -> Int64,
        random: @escaping () -> Double = { Double.random(in: 0..<1) },
        ttlMs: Int64 = DeliveryEngine.defaultTtlMs,
        receiptTimeoutMs: Int64 = DeliveryEngine.receiptTimeoutMsDefault,
        mediaDirectory: URL? = nil,
        mediaChunkBytes: Int = MediaNotes.defaultChunk
    ) {
        self.store = store
        self.identity = identity
        self.links = links
        self.clock = clock
        self.random = random
        self.ttlMs = ttlMs
        self.receiptTimeoutMs = receiptTimeoutMs
        self.mediaDirectory = mediaDirectory
        self.mediaChunkBytes = mediaChunkBytes
    }

    public func queueText(_ peerId: String, _ text: String) throws -> MessageRecord {
        guard let (keys, deviceId) = identity() else { throw DeliveryRejected(message: "Create an identity before sending.") }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw DeliveryRejected(message: "Message is empty.") }
        guard body.utf16.count <= Self.maxBody else { throw DeliveryRejected(message: "Message is too long.") }
        guard let contact = store.contact(peerId) else { throw DeliveryRejected(message: "That contact is not on this device.") }
        guard !contact.blocked else { throw DeliveryRejected(message: "This contact is blocked.") }
        let now = clock()
        let id = Encoding.newId("msg")
        let envelope = try Envelopes.seal(
            sender: keys, deviceId: deviceId, recipientId: peerId, recipientAgreementPublic: try bundleFor(contact).agreementPublic,
            id: id, type: .message, plaintext: Encoding.utf8(body), createdAt: now, ttlMs: ttlMs
        )
        let message = MessageRecord(id: id, peerId: peerId, direction: .outgoing, body: body, createdAt: now, state: .queued)
        store.putMessage(message)
        store.putQueued(QueueItem(id: id, peerId: peerId, kind: .message, payload: envelope.encode(), nextAttemptAt: now, expiresAt: envelope.expiresAt))
        try store.save()
        return message
    }

    /// Seals one copy of `body` to each group member. The thread shows a single local message.
    @discardableResult
    public func queueGroupText(_ group: GroupRecord, _ selfId: String, _ text: String) throws -> MessageRecord {
        guard let (keys, deviceId) = identity() else { throw DeliveryRejected(message: "Create an identity before sending.") }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw DeliveryRejected(message: "Message is empty.") }
        guard body.utf16.count <= Self.maxBody else { throw DeliveryRejected(message: "Message is too long.") }
        let members = group.members.filter { $0 != selfId }
        guard !members.isEmpty else { throw DeliveryRejected(message: "A group needs someone else in it.") }
        let now = clock()
        let id = Encoding.newId("msg")
        let plain = Encoding.utf8(GroupNotes.encodeText(groupId: group.id, mid: id, body: body))
        let message = MessageRecord(id: id, peerId: group.id, direction: .outgoing, body: body, createdAt: now, state: .queued, senderId: selfId)
        store.putMessage(message)
        for peerId in members {
            guard let contact = store.contact(peerId), !contact.blocked else { continue }
            let envelopeId = Encoding.newId("msg")
            let envelope = try Envelopes.seal(
                sender: keys, deviceId: deviceId, recipientId: peerId, recipientAgreementPublic: try bundleFor(contact).agreementPublic,
                id: envelopeId, type: .message, plaintext: plain, createdAt: now, ttlMs: ttlMs
            )
            store.putQueued(QueueItem(id: envelopeId, peerId: peerId, kind: .message, payload: envelope.encode(), nextAttemptAt: now, expiresAt: envelope.expiresAt, messageId: id))
        }
        guard store.queue().contains(where: { $0.logicalId() == id }) else {
            throw DeliveryRejected(message: "No reachable members in this group.")
        }
        try store.save()
        return message
    }

    public func queueGroupInvite(_ group: GroupRecord, _ selfId: String) throws {
        guard let (keys, deviceId) = identity() else { return }
        let members = group.members.filter { $0 != selfId }
        let now = clock()
        let plain = Encoding.utf8(GroupNotes.encode(GroupNotes.Note(op: "invite", groupId: group.id, name: group.name, members: group.members)))
        for peerId in members {
            guard let contact = store.contact(peerId), contact.accepted, !contact.blocked else { continue }
            let envelope = try Envelopes.seal(
                sender: keys, deviceId: deviceId, recipientId: peerId, recipientAgreementPublic: try bundleFor(contact).agreementPublic,
                id: Encoding.newId("grp"), type: .group, plaintext: plain, createdAt: now, ttlMs: ttlMs
            )
            store.putQueued(QueueItem(id: envelope.id, peerId: peerId, kind: .receipt, payload: envelope.encode(), nextAttemptAt: now, expiresAt: envelope.expiresAt))
        }
        if !members.isEmpty { try store.save() }
    }

    /// Seals `bytes` into chunked envelopes and queues them. The file stays on this device
    /// so the bubble can show it, and so a restart can send whatever has not been written yet.
    public func queueMedia(_ peerId: String, kind: String, mime: String, name: String, bytes: Data, caption: String) throws -> MessageRecord {
        guard identity() != nil else { throw DeliveryRejected(message: "Create an identity before sending.") }
        guard MediaNotes.kinds.contains(kind) else { throw DeliveryRejected(message: "That attachment is not supported.") }
        guard !bytes.isEmpty else { throw DeliveryRejected(message: "That file is empty.") }
        guard bytes.count <= MediaNotes.maxBytes else { throw DeliveryRejected(message: "That file is over 6 MB. Choose a shorter one.") }
        guard let directory = mediaDirectory else { throw DeliveryRejected(message: "Attachments need local storage.") }
        guard let contact = store.contact(peerId) else { throw DeliveryRejected(message: "That contact is not on this device.") }
        guard !contact.blocked else { throw DeliveryRejected(message: "This contact is blocked.") }
        let now = clock()
        let id = Encoding.newId("med")
        let fileName = "\(id).bin"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: directory.appendingPathComponent(fileName))
        let parts = MediaNotes.split(bytes, chunkBytes: mediaChunkBytes).count
        let cleanCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let job = MediaNotes.Job(kind: kind, mime: mime, name: name, caption: cleanCaption, parts: parts, nextPart: 0, fileName: fileName)
        let message = MessageRecord(
            id: id, peerId: peerId, direction: .outgoing, body: cleanCaption, createdAt: now, state: .queued,
            mediaKind: kind, mediaMime: mime, mediaName: name, mediaFile: fileName
        )
        store.putMessage(message)
        store.putQueued(QueueItem(id: id, peerId: peerId, kind: .message, payload: MediaNotes.encodeJob(job), nextAttemptAt: now, expiresAt: now + ttlMs))
        try store.save()
        return message
    }

    /// Seals one copy of an attachment to each group member. The file is stored once on this phone.
    @discardableResult
    public func queueGroupMedia(
        _ group: GroupRecord,
        _ selfId: String,
        kind: String,
        mime: String,
        name: String,
        bytes: Data,
        caption: String
    ) throws -> MessageRecord {
        guard identity() != nil else { throw DeliveryRejected(message: "Create an identity before sending.") }
        guard MediaNotes.kinds.contains(kind) else { throw DeliveryRejected(message: "That attachment is not supported.") }
        guard !bytes.isEmpty else { throw DeliveryRejected(message: "That file is empty.") }
        guard bytes.count <= MediaNotes.maxBytes else { throw DeliveryRejected(message: "That file is over 6 MB. Choose a shorter one.") }
        guard let directory = mediaDirectory else { throw DeliveryRejected(message: "Attachments need local storage.") }
        let members = group.members.filter { $0 != selfId }
        guard !members.isEmpty else { throw DeliveryRejected(message: "A group needs someone else in it.") }
        let now = clock()
        let id = Encoding.newId("med")
        let fileName = "\(id).bin"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: directory.appendingPathComponent(fileName))
        let parts = MediaNotes.split(bytes, chunkBytes: mediaChunkBytes).count
        let cleanCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let job = MediaNotes.Job(kind: kind, mime: mime, name: name, caption: cleanCaption, parts: parts, nextPart: 0, fileName: fileName)
        let message = MessageRecord(
            id: id, peerId: group.id, direction: .outgoing, body: cleanCaption, createdAt: now, state: .queued,
            mediaKind: kind, mediaMime: mime, mediaName: name, mediaFile: fileName, senderId: selfId
        )
        store.putMessage(message)
        guard enqueueGroupMedia(group, selfId, id, job, now) else {
            throw DeliveryRejected(message: "No reachable members in this group.")
        }
        try store.save()
        return message
    }

    /// Changes the body of an outgoing text bubble. Unsent copies are resealed; sent copies get an edit note.
    @discardableResult
    public func editText(_ messageId: String, _ body: String) throws -> MessageRecord {
        guard var message = store.message(messageId) else { throw DeliveryRejected(message: "That message is gone.") }
        guard message.direction == .outgoing else { throw DeliveryRejected(message: "You can only edit your own messages.") }
        guard !message.deleted else { throw DeliveryRejected(message: "That message was deleted.") }
        guard message.mediaKind == nil else { throw DeliveryRejected(message: "Only text messages can be edited.") }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DeliveryRejected(message: "Message is empty.") }
        guard text.utf16.count <= Self.maxBody else { throw DeliveryRejected(message: "Message is too long.") }
        let failed = message.state == .failed
        message.body = text
        message.edited = true
        message.updatedAt = clock()
        store.putMessage(message)
        let unsent = store.queue().contains { $0.logicalId() == message.id && $0.kind == .message && $0.sentAt == nil }
        if unsent {
            try resealQueuedText(message)
        } else if failed {
            _ = try retry(message.id)
        } else {
            try queueChatNote(message, ChatNotes.encode(ChatNotes.Note(op: "edit", messageId: message.id, body: text, groupId: store.group(message.peerId)?.id)))
        }
        try store.save()
        return message
    }

    /// `forEveryone` tombstones an outgoing message and tells the other phones.
    /// Otherwise the bubble is removed only on this phone.
    @discardableResult
    public func deleteMessage(_ messageId: String, forEveryone: Bool) throws -> MessageRecord? {
        guard let message = store.message(messageId) else { throw DeliveryRejected(message: "That message is gone.") }
        if message.mediaKind == "call" || message.mediaKind == "group", forEveryone {
            throw DeliveryRejected(message: "That item cannot be deleted for everyone.")
        }
        let unsent = store.queue().contains { $0.logicalId() == message.id && $0.kind == .message && $0.sentAt == nil }
        if forEveryone {
            guard message.direction == .outgoing else { throw DeliveryRejected(message: "You can only delete that for everyone if you sent it.") }
            store.removeQueuedForMessage(messageId)
            if unsent || message.deleted {
                store.removeMessage(messageId)
                try store.save()
                return nil
            }
            var tombstone = message
            tombstone.deleted = true
            tombstone.body = ""
            tombstone.mediaKind = nil
            tombstone.mediaMime = nil
            tombstone.mediaName = nil
            tombstone.mediaFile = nil
            tombstone.reactions = []
            tombstone.updatedAt = clock()
            store.putMessage(tombstone)
            try queueChatNote(message, ChatNotes.encode(ChatNotes.Note(op: "delete", messageId: message.id, groupId: store.group(message.peerId)?.id)))
            try store.save()
            return tombstone
        }
        store.removeQueuedForMessage(messageId)
        store.removeMessage(messageId)
        try store.save()
        return nil
    }

    /// Queues a new copy of `messageId` in another thread and marks it as forwarded.
    @discardableResult
    public func forward(_ messageId: String, to toPeerId: String, selfId: String) throws -> MessageRecord {
        guard let message = store.message(messageId) else { throw DeliveryRejected(message: "That message is gone.") }
        guard !message.deleted else { throw DeliveryRejected(message: "That message was deleted.") }
        guard message.mediaKind != "call", message.mediaKind != "group" else {
            throw DeliveryRejected(message: "That item cannot be forwarded.")
        }
        let created: MessageRecord
        if let kind = message.mediaKind {
            guard let directory = mediaDirectory else { throw DeliveryRejected(message: "Attachments need local storage.") }
            guard let file = message.mediaFile else { throw DeliveryRejected(message: "That attachment is gone.") }
            let bytes = (try? Data(contentsOf: directory.appendingPathComponent(file))) ?? Data()
            guard !bytes.isEmpty else { throw DeliveryRejected(message: "That attachment is gone.") }
            let mime = message.mediaMime ?? "application/octet-stream"
            let name = message.mediaName ?? "attachment"
            if GroupNotes.isGroupId(toPeerId) {
                guard let group = store.group(toPeerId) else { throw DeliveryRejected(message: "That group is not on this device.") }
                created = try queueGroupMedia(group, selfId, kind: kind, mime: mime, name: name, bytes: bytes, caption: message.body)
            } else {
                created = try queueMedia(toPeerId, kind: kind, mime: mime, name: name, bytes: bytes, caption: message.body)
            }
        } else if GroupNotes.isGroupId(toPeerId) {
            guard let group = store.group(toPeerId) else { throw DeliveryRejected(message: "That group is not on this device.") }
            created = try queueGroupText(group, selfId, message.body)
        } else {
            created = try queueText(toPeerId, message.body)
        }
        var marked = created
        marked.forwarded = true
        store.putMessage(marked)
        try store.save()
        return marked
    }

    /// One emoji per person. Tapping the same emoji again clears it; another emoji replaces it.
    @discardableResult
    public func react(_ messageId: String, _ emoji: String) throws -> MessageRecord {
        guard let (keys, _) = identity() else { throw DeliveryRejected(message: "Create an identity before sending.") }
        guard ChatNotes.emojis.contains(emoji) else { throw DeliveryRejected(message: "That reaction is not supported.") }
        guard var message = store.message(messageId) else { throw DeliveryRejected(message: "That message is gone.") }
        guard !message.deleted else { throw DeliveryRejected(message: "That message was deleted.") }
        guard message.mediaKind != "call", message.mediaKind != "group" else {
            throw DeliveryRejected(message: "That item cannot be reacted to.")
        }
        message.reactions = message.reactions.toggling(fromId: keys.directId, emoji: emoji)
        message.updatedAt = clock()
        store.putMessage(message)
        try queueChatNote(message, ChatNotes.encode(ChatNotes.Note(op: "react", messageId: message.id, body: emoji, groupId: store.group(message.peerId)?.id)))
        try store.save()
        return message
    }

    /// Requeues a failed message with a fresh envelope under the same id. The recipient deduplicates by id.
    @discardableResult
    public func retry(_ messageId: String) throws -> Bool {
        guard var message = store.message(messageId), let state = message.state,
              let next = DeliveryStateMachine.next(state, .retry)
        else { return false }
        if let group = store.group(message.peerId) {
            guard let (keys, deviceId) = identity() else { return false }
            let now = clock()
            message.state = next
            message.lastError = nil
            message.updatedAt = now
            store.putMessage(message)
            let remaining = store.queue().filter { $0.logicalId() == messageId && $0.kind == .message }
            if !remaining.isEmpty {
                for var item in remaining {
                    item.sentAt = nil
                    item.nextAttemptAt = now
                    item.lastError = nil
                    item.payload = rewind(item.payload)
                    store.putQueued(item)
                }
                try store.save()
                return true
            }
            if let mediaFile = message.mediaFile, let kind = message.mediaKind {
                guard let directory = mediaDirectory else { return false }
                let file = directory.appendingPathComponent(mediaFile)
                guard let bytes = try? Data(contentsOf: file), !bytes.isEmpty else { return false }
                let parts = MediaNotes.split(bytes, chunkBytes: mediaChunkBytes).count
                let job = MediaNotes.Job(
                    kind: kind, mime: message.mediaMime ?? "application/octet-stream", name: message.mediaName ?? "",
                    caption: message.body, parts: parts, nextPart: 0, fileName: mediaFile
                )
                guard enqueueGroupMedia(group, keys.directId, message.id, job, now) else { return false }
                try store.save()
                return true
            }
            let plain = Encoding.utf8(GroupNotes.encodeText(groupId: group.id, mid: message.id, body: message.body))
            var any = false
            for peerId in group.members where peerId != keys.directId {
                guard let contact = store.contact(peerId), !contact.blocked else { continue }
                let envelopeId = Encoding.newId("msg")
                let envelope = try Envelopes.seal(
                    sender: keys, deviceId: deviceId, recipientId: peerId, recipientAgreementPublic: try bundleFor(contact).agreementPublic,
                    id: envelopeId, type: .message, plaintext: plain, createdAt: now, ttlMs: ttlMs
                )
                store.putQueued(QueueItem(id: envelopeId, peerId: peerId, kind: .message, payload: envelope.encode(), nextAttemptAt: now, expiresAt: envelope.expiresAt, messageId: message.id))
                any = true
            }
            guard any else { return false }
            try store.save()
            return true
        }
        guard let (keys, deviceId) = identity(),
              let contact = store.contact(message.peerId), !contact.blocked
        else { return false }
        let now = clock()
        if let mediaFile = message.mediaFile, let kind = message.mediaKind {
            guard let directory = mediaDirectory else { return false }
            let file = directory.appendingPathComponent(mediaFile)
            guard let bytes = try? Data(contentsOf: file), !bytes.isEmpty else { return false }
            let parts = MediaNotes.split(bytes, chunkBytes: mediaChunkBytes).count
            let job = MediaNotes.Job(
                kind: kind, mime: message.mediaMime ?? "application/octet-stream", name: message.mediaName ?? "",
                caption: message.body, parts: parts, nextPart: 0, fileName: mediaFile
            )
            message.state = next
            message.lastError = nil
            message.updatedAt = now
            store.putMessage(message)
            store.putQueued(QueueItem(id: message.id, peerId: message.peerId, kind: .message, payload: MediaNotes.encodeJob(job), nextAttemptAt: now, expiresAt: now + ttlMs))
            try store.save()
            return true
        }
        let envelope = try Envelopes.seal(
            sender: keys, deviceId: deviceId, recipientId: message.peerId, recipientAgreementPublic: try bundleFor(contact).agreementPublic,
            id: message.id, type: .message, plaintext: Encoding.utf8(message.body), createdAt: now, ttlMs: ttlMs
        )
        message.state = next
        message.lastError = nil
        message.updatedAt = now
        store.putMessage(message)
        store.putQueued(QueueItem(id: message.id, peerId: message.peerId, kind: .message, payload: envelope.encode(), nextAttemptAt: now, expiresAt: envelope.expiresAt))
        try store.save()
        return true
    }

    /// After a restart nothing is in flight. Sending and sent go back to queued and retry now.
    public func recover() throws {
        let now = clock()
        for item in store.queue() {
            if item.kind == .message { transition(item.logicalId(), .recovered, nil) }
            if var current = store.queued(item.id) {
                current.sentAt = nil
                current.nextAttemptAt = min(current.nextAttemptAt, now)
                current.payload = rewind(current.payload)
                store.putQueued(current)
            }
        }
        try store.save()
    }

    /// Seals the current photo and status for each accepted contact.
    /// Queued like a receipt: it is not a chat message, and it leaves the queue once written.
    public func shareProfile(peerId: String? = nil) throws {
        guard let (keys, deviceId) = identity(), let profile = store.profile else { return }
        let jpeg = profile.avatarJpegBase64.flatMap(Encoding.fromBase64Url)
        let plain = Encoding.utf8(ProfileNotes.encode(status: profile.status, avatarJpeg: jpeg))
        let now = clock()
        let targets = store.contacts().filter { $0.accepted && !$0.blocked && (peerId == nil || $0.directId == peerId) }
        for contact in targets {
            let bundle = try bundleFor(contact)
            let id = "profile_\(contact.directId)"
            let envelope = try Envelopes.seal(
                sender: keys, deviceId: deviceId, recipientId: contact.directId, recipientAgreementPublic: bundle.agreementPublic,
                id: id, type: .profile, plaintext: plain, createdAt: now, ttlMs: ttlMs
            )
            store.putQueued(QueueItem(id: id, peerId: contact.directId, kind: .receipt, payload: envelope.encode(), nextAttemptAt: now, expiresAt: now + ttlMs))
        }
        if !targets.isEmpty { try store.save() }
    }

    /// Seals a story or profile photo/video to every accepted contact.
    @discardableResult
    public func queueFeed(channel: String, kind: String, mime: String, name: String, bytes: Data, caption: String) throws -> FeedItem {
        guard let (keys, _) = identity() else { throw DeliveryRejected(message: "Create an identity before sending.") }
        guard FeedNotes.channels.contains(channel) else { throw DeliveryRejected(message: "That post type is not supported.") }
        guard FeedNotes.kinds.contains(kind) else { throw DeliveryRejected(message: "Stories and posts take a photo or a video.") }
        guard !bytes.isEmpty else { throw DeliveryRejected(message: "That file is empty.") }
        guard bytes.count <= MediaNotes.maxBytes else { throw DeliveryRejected(message: "That file is over 6 MB. Choose a shorter one.") }
        guard let directory = mediaDirectory else { throw DeliveryRejected(message: "Attachments need local storage.") }
        let now = clock()
        store.pruneFeed(now)
        let live = store.feed().filter { $0.ownerId == keys.directId && $0.channel == channel }
        let limit = channel == FeedNotes.story ? FeedNotes.maxStories : FeedNotes.maxPosts
        guard live.count < limit else {
            throw DeliveryRejected(message: "Take some older \(channel == FeedNotes.story ? "stories" : "posts") down first.")
        }
        let id = Encoding.newId("fed")
        let fileName = "\(id).bin"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: directory.appendingPathComponent(fileName))
        let expiresAt = channel == FeedNotes.story ? now + FeedNotes.storyTtlMs : nil
        let captionText = String(caption.trimmingCharacters(in: .whitespacesAndNewlines).prefix(FeedNotes.maxCaption))
        let item = FeedItem(
            id: id, ownerId: keys.directId, channel: channel, kind: kind, mime: mime, name: name,
            caption: captionText, createdAt: now, expiresAt: expiresAt, mediaFile: fileName, seen: true
        )
        store.putFeed(item)
        enqueueFeed(item)
        try store.save()
        return item
    }

    public func shareFeed(peerId: String? = nil) throws {
        guard let selfId = identity()?.0.directId else { return }
        let now = clock()
        store.pruneFeed(now)
        let mine = store.feed().filter { $0.ownerId == selfId }
        guard !mine.isEmpty else { return }
        let targets = store.contacts().filter { $0.accepted && !$0.blocked && (peerId == nil || $0.directId == peerId) }
        guard !targets.isEmpty else { return }
        for item in mine { enqueueFeed(item, targets) }
        try store.save()
    }

    public func deleteFeed(_ id: String) throws {
        guard let (keys, deviceId) = identity() else { throw DeliveryRejected(message: "Create an identity first.") }
        guard let item = store.feed(id) else { throw DeliveryRejected(message: "That post is gone.") }
        guard item.ownerId == keys.directId else { throw DeliveryRejected(message: "You can only delete your own posts.") }
        store.removeFeed(id)
        let now = clock()
        let plain = Encoding.utf8(FeedNotes.encodeDelete(channel: item.channel, id: item.id))
        let targets = store.contacts().filter { $0.accepted && !$0.blocked }
        for contact in targets {
            let envelope = try Envelopes.seal(
                sender: keys, deviceId: deviceId, recipientId: contact.directId, recipientAgreementPublic: try bundleFor(contact).agreementPublic,
                id: Encoding.newId("fed"), type: .feed, plaintext: plain, createdAt: now, ttlMs: ttlMs
            )
            store.putQueued(QueueItem(id: envelope.id, peerId: contact.directId, kind: .receipt, payload: envelope.encode(), nextAttemptAt: now, expiresAt: envelope.expiresAt))
        }
        try store.save()
    }

    public func markFeedSeen(_ ownerId: String) throws {
        var changed = false
        for item in store.feed() where item.ownerId == ownerId && !item.seen {
            var copy = item
            copy.seen = true
            store.putFeed(copy)
            changed = true
        }
        if changed { try store.save() }
    }

    /// The peer just became reachable. Retry everything queued for it without waiting for backoff.
    public func peerOnline(_ peerId: String) throws {
        let now = clock()
        var changed = false
        for var item in store.queue() where item.peerId == peerId && item.sentAt == nil && item.nextAttemptAt > now {
            item.nextAttemptAt = now
            store.putQueued(item)
            changed = true
        }
        if changed { try store.save() }
    }

    /// Recipient blocked: fail its outgoing messages and drop pending receipts.
    public func rejectPeer(_ peerId: String) throws {
        for item in store.queue() where item.peerId == peerId {
            if item.kind == .message {
                let others = store.queue().contains { $0.id != item.id && $0.logicalId() == item.logicalId() && $0.kind == .message && $0.peerId != peerId }
                if !others { transition(item.logicalId(), .rejected, "Blocked on this device.") }
            }
            store.removeQueued(item.id)
        }
        try store.save()
    }

    /// Earliest time the queue needs attention: a retry, a receipt timeout, or an expiry.
    public func nextWakeAt() -> Int64? {
        store.queue().map { item in min(item.expiresAt, item.sentAt.map { $0 + receiptTimeoutMs } ?? item.nextAttemptAt) }.min()
    }

    public func pendingCount() -> Int { store.queue().filter { $0.kind == .message }.count }

    public func awaitingReceipt() -> Bool { store.queue().contains { $0.sentAt != nil } }

    public func flush() async throws {
        if flushing {
            rerun = true
            return
        }
        flushing = true
        defer { flushing = false }
        repeat {
            rerun = false
            try await flushOnce()
        } while rerun
    }

    private func flushOnce() async throws {
        guard identity() != nil else { return }
        let now = clock()
        expireAndTimeout(now)
        let due = store.queue().filter { $0.sentAt == nil && $0.nextAttemptAt <= now }.sorted { $0.nextAttemptAt < $1.nextAttemptAt }
        var peers: [String] = []
        var byPeer: [String: [QueueItem]] = [:]
        for item in due {
            if byPeer[item.peerId] == nil { peers.append(item.peerId) }
            byPeer[item.peerId, default: []].append(item)
        }
        for peerId in peers {
            let items = byPeer[peerId] ?? []
            guard let contact = store.contact(peerId), !contact.blocked else {
                try rejectPeer(peerId)
                continue
            }
            for var item in items {
                if item.kind == .message, !MediaNotes.isJob(item.payload) { transition(item.logicalId(), .attempt, nil) }
                item.attempts += 1
                store.putQueued(item)
            }
            try store.save()
            var connected = links.isConnected(peerId)
            if !connected { connected = await links.connect(peerId) }
            for item in items {
                guard let current = store.queued(item.id) else { continue }
                guard connected else {
                    unreachable(current, "Recipient unavailable")
                    continue
                }
                if MediaNotes.isJob(current.payload) {
                    try await sendMediaChunks(current)
                    continue
                }
                if FeedNotes.isJob(current.payload) {
                    try await sendFeedChunks(current)
                    continue
                }
                if await links.send(peerId, Encoding.utf8(current.payload)) {
                    guard var latest = store.queued(item.id) else { continue }
                    if latest.kind == .receipt {
                        store.removeQueued(latest.id)
                    } else {
                        transition(latest.logicalId(), .written, nil)
                        latest.sentAt = clock()
                        latest.lastError = nil
                        store.putQueued(latest)
                    }
                } else {
                    unreachable(current, "Channel closed before the write")
                }
            }
            try store.save()
        }
    }

    private func unreachable(_ item: QueueItem, _ reason: String) {
        let fanOut = item.messageId != nil && item.messageId != item.id
        if item.kind == .message {
            if !fanOut, transition(item.logicalId(), .unreachable, reason) == nil, MediaNotes.isJob(item.payload), var message = store.message(item.logicalId()) {
                message.lastError = reason
                message.updatedAt = clock()
                store.putMessage(message)
            } else if fanOut, var message = store.message(item.logicalId()) {
                message.lastError = reason
                message.updatedAt = clock()
                store.putMessage(message)
            }
        }
        if var current = store.queued(item.id) {
            current.nextAttemptAt = clock() + Backoff.delayMs(attempt: current.attempts, random: random)
            current.lastError = reason
            store.putQueued(current)
        }
    }

    private func expireAndTimeout(_ now: Int64) {
        for item in store.queue() {
            if item.expiresAt <= now {
                if item.kind == .message {
                    let others = store.queue().contains { $0.id != item.id && $0.logicalId() == item.logicalId() && $0.kind == .message }
                    if !others { transition(item.logicalId(), .expired, "Expired before the recipient confirmed it.") }
                }
                store.removeQueued(item.id)
                continue
            }
            guard let sentAt = item.sentAt, sentAt + receiptTimeoutMs <= now else { continue }
            let fanOut = item.messageId != nil && item.messageId != item.id
            if item.kind == .message, !fanOut { transition(item.logicalId(), .receiptTimeout, "No receipt yet") }
            if var current = store.queued(item.id) {
                current.sentAt = nil
                current.payload = rewind(current.payload)
                current.nextAttemptAt = now + Backoff.delayMs(attempt: current.attempts, random: random)
                current.lastError = "No receipt yet"
                store.putQueued(current)
            }
        }
    }

    /// Applies a state-machine event. Leaving the awaiting states drops the queue entry.
    @discardableResult
    private func transition(_ messageId: String, _ event: DeliveryEvent, _ error: String?) -> MessageState? {
        guard var message = store.message(messageId), let state = message.state, let next = DeliveryStateMachine.next(state, event) else { return nil }
        let settled = next == .accepted || next == .acknowledged
        message.state = next
        message.lastError = settled ? nil : (error ?? message.lastError)
        message.updatedAt = clock()
        store.putMessage(message)
        if !next.awaitingReceipt { store.removeQueuedForMessage(messageId) }
        return next
    }

    /// Verifies and stores one envelope from `peerId`. The caller must already have a contact
    /// for the sender (an unknown sender is saved as a request before this is called).
    public func receive(_ peerId: String, _ bytes: Data) throws -> ReceiveOutcome {
        guard let (keys, _) = identity(),
              let header = Envelopes.peek(bytes),
              header.to == keys.directId, header.from == peerId,
              let contact = store.contact(peerId), !contact.blocked,
              let bundle = try? bundleFor(contact),
              let envelope = try? Envelopes.decode(bytes, senderSigningPublic: bundle.signingPublic, now: clock()),
              let opened = try? Envelopes.open(recipient: keys, envelope: envelope)
        else { return .ignored }
        if let (header, chunk) = MediaNotes.decodePart(opened) {
            guard envelope.type == .message else { return .ignored }
            return try ingestMedia(peerId, contact, header, chunk, envelope.createdAt)
        }
        if envelope.type == .feed {
            guard contact.accepted else { return .ignored }
            return try ingestFeed(peerId, opened, String(data: opened, encoding: .utf8) ?? "")
        }
        guard let plaintext = String(data: opened, encoding: .utf8) else { return .ignored }
        if envelope.type == .call {
            guard contact.accepted else { return .ignored }
            onCall?(plaintext)
            return .receipt
        }
        if envelope.type == .group {
            return try ingestInvite(peerId, plaintext, envelope.createdAt)
        }
        if envelope.type == .profile {
            guard let note = ProfileNotes.parse(plaintext) else { return .ignored }
            var updated = contact
            updated.about = String(note.status.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            if note.clearAvatar {
                updated.avatarJpegBase64 = nil
            } else if let jpeg = note.avatarJpeg {
                updated.avatarJpegBase64 = Encoding.base64Url(jpeg)
            }
            store.putContact(updated)
            try store.save()
            return .stored
        }
        if envelope.type != .message {
            let parts = plaintext.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == envelope.type.rawValue,
                  let message = store.message(parts[1]), message.direction == .outgoing
            else { return .ignored }
            let inGroup = store.group(message.peerId)?.members.contains(peerId) == true
            guard message.peerId == peerId || inGroup else { return .ignored }
            if envelope.type == .ack {
                if let item = store.queue().first(where: { $0.logicalId() == message.id && $0.peerId == peerId }) {
                    store.removeQueued(item.id)
                }
                let remaining = store.queue().contains { $0.logicalId() == message.id && $0.kind == .message }
                if !remaining { transition(message.id, .deliveryReceipt, nil) }
            } else {
                transition(message.id, .readReceipt, nil)
            }
            try store.save()
            return .receipt
        }
        if let grouped = GroupNotes.parsePrefixed(plaintext) {
            return try ingestGroupText(peerId, contact, grouped, envelope.createdAt)
        }
        if let chat = ChatNotes.parsePrefixed(plaintext) {
            return try ingestChatNote(peerId, contact, chat, envelope.id)
        }
        if store.message(envelope.id) != nil {
            try queueReceipt(contact, .ack, envelope.id)
            try store.save()
            return .duplicate
        }
        let stored = MessageRecord(id: envelope.id, peerId: peerId, direction: .incoming, body: plaintext, createdAt: envelope.createdAt)
        store.putMessage(stored)
        try queueReceipt(contact, .ack, envelope.id)
        try store.save()
        onInbound?(stored)
        return .stored
    }

    /// Queues signed `read` receipts for unread incoming messages from `peerId`.
    @discardableResult
    public func markRead(_ peerId: String) throws -> Int {
        if store.group(peerId) != nil {
            let unread = store.messagesWith(peerId).filter { $0.direction == .incoming && !$0.read }
            for var message in unread {
                message.read = true
                message.updatedAt = clock()
                store.putMessage(message)
                if message.mediaKind == "call" || message.mediaKind == "group" { continue }
                guard let targetId = message.senderId, let target = store.contact(targetId), !target.blocked else { continue }
                try queueReceipt(target, .read, message.id)
            }
            if !unread.isEmpty { try store.save() }
            return unread.count
        }
        guard let contact = store.contact(peerId), !contact.blocked, contact.accepted else { return 0 }
        let unread = store.messagesWith(peerId).filter { $0.direction == .incoming && !$0.read }
        for var message in unread {
            message.read = true
            message.updatedAt = clock()
            store.putMessage(message)
            if message.mediaKind == "call" { continue }
            let targetId = message.senderId ?? peerId
            guard let target = store.contact(targetId), !target.blocked else { continue }
            try queueReceipt(target, .read, message.id)
        }
        if !unread.isEmpty { try store.save() }
        return unread.count
    }

    /// A call signal is sealed and returned. The caller writes it now. It is not queued.
    public func sealCall(_ peerId: String, _ plain: String) -> Data? {
        guard let (keys, deviceId) = identity(),
              let contact = store.contact(peerId), contact.accepted, !contact.blocked,
              let bundle = try? bundleFor(contact),
              let envelope = try? Envelopes.seal(
                sender: keys, deviceId: deviceId, recipientId: peerId, recipientAgreementPublic: bundle.agreementPublic,
                id: Encoding.newId("call"), type: .call, plaintext: Encoding.utf8(plain), createdAt: clock(), ttlMs: ttlMs
              )
        else { return nil }
        return Encoding.utf8(envelope.encode())
    }

    private func enqueueGroupMedia(_ group: GroupRecord, _ selfId: String, _ messageId: String, _ job: MediaNotes.Job, _ now: Int64) -> Bool {
        var any = false
        for peerId in group.members where peerId != selfId {
            guard let contact = store.contact(peerId), !contact.blocked else { continue }
            store.putQueued(QueueItem(
                id: Encoding.newId("med"), peerId: peerId, kind: .message, payload: MediaNotes.encodeJob(job),
                nextAttemptAt: now, expiresAt: now + ttlMs, messageId: messageId
            ))
            any = true
        }
        return any
    }

    private func ingestChatNote(_ peerId: String, _ contact: ContactRecord, _ note: ChatNotes.Note, _ envelopeId: String) throws -> ReceiveOutcome {
        let found = store.message(note.messageId)
        try queueReceipt(contact, .ack, envelopeId)
        guard var message = found else {
            try store.save()
            return .ignored
        }
        if let groupId = note.groupId, message.peerId != groupId {
            try store.save()
            return .ignored
        }
        let now = clock()
        switch note.op {
        case "edit":
            guard fromOriginalSender(message, peerId) else {
                try store.save()
                return .ignored
            }
            let body = note.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !body.isEmpty, !message.deleted, message.mediaKind == nil else {
                try store.save()
                return .ignored
            }
            message.body = body
            message.edited = true
            message.updatedAt = now
            store.putMessage(message)
        case "delete":
            guard fromOriginalSender(message, peerId) else {
                try store.save()
                return .ignored
            }
            message.deleted = true
            message.body = ""
            message.mediaKind = nil
            message.mediaMime = nil
            message.mediaName = nil
            message.mediaFile = nil
            message.reactions = []
            message.updatedAt = now
            store.putMessage(message)
        case "react":
            let inGroup = store.group(message.peerId)?.members.contains(peerId) == true
            guard let emoji = note.body, ChatNotes.emojis.contains(emoji), !message.deleted,
                  message.peerId == peerId || inGroup
            else {
                try store.save()
                return .ignored
            }
            message.reactions = message.reactions.toggling(fromId: peerId, emoji: emoji)
            message.updatedAt = now
            store.putMessage(message)
        default:
            try store.save()
            return .ignored
        }
        try store.save()
        return .stored
    }

    private func fromOriginalSender(_ message: MessageRecord, _ peerId: String) -> Bool {
        guard message.direction == .incoming else { return false }
        let expected = message.senderId ?? message.peerId
        return expected == peerId
    }

    private func queueChatNote(_ message: MessageRecord, _ plaintext: String) throws {
        guard let (keys, deviceId) = identity() else { return }
        let now = clock()
        let targets = store.group(message.peerId)?.members.filter { $0 != keys.directId } ?? [message.peerId]
        for peerId in targets {
            guard let contact = store.contact(peerId), !contact.blocked else { continue }
            let envelope = try Envelopes.seal(
                sender: keys, deviceId: deviceId, recipientId: peerId, recipientAgreementPublic: try bundleFor(contact).agreementPublic,
                id: Encoding.newId("msg"), type: .message, plaintext: Encoding.utf8(plaintext), createdAt: now, ttlMs: ttlMs
            )
            store.putQueued(QueueItem(id: envelope.id, peerId: peerId, kind: .receipt, payload: envelope.encode(), nextAttemptAt: now, expiresAt: envelope.expiresAt, messageId: message.id))
        }
    }

    private func resealQueuedText(_ message: MessageRecord) throws {
        guard let (keys, deviceId) = identity() else { return }
        let now = clock()
        let plain: Data
        if let group = store.group(message.peerId) {
            plain = Encoding.utf8(GroupNotes.encodeText(groupId: group.id, mid: message.id, body: message.body))
        } else {
            plain = Encoding.utf8(message.body)
        }
        for item in store.queue() where item.logicalId() == message.id && item.kind == .message && item.sentAt == nil {
            guard let contact = store.contact(item.peerId) else { continue }
            let envelope = try Envelopes.seal(
                sender: keys, deviceId: deviceId, recipientId: item.peerId, recipientAgreementPublic: try bundleFor(contact).agreementPublic,
                id: item.id, type: .message, plaintext: plain, createdAt: now, ttlMs: ttlMs
            )
            var updated = item
            updated.payload = envelope.encode()
            updated.attempts = 0
            updated.nextAttemptAt = now
            updated.lastError = nil
            updated.expiresAt = envelope.expiresAt
            store.putQueued(updated)
        }
    }

    private func queueReceipt(_ contact: ContactRecord, _ type: EnvelopeType, _ messageId: String) throws {
        guard let (keys, deviceId) = identity() else { return }
        let now = clock()
        let envelope = try Envelopes.seal(
            sender: keys, deviceId: deviceId, recipientId: contact.directId, recipientAgreementPublic: try bundleFor(contact).agreementPublic,
            id: Encoding.newId(type.rawValue), type: type, plaintext: Encoding.utf8("\(type.rawValue):\(messageId)"), createdAt: now, ttlMs: ttlMs
        )
        store.putQueued(QueueItem(id: envelope.id, peerId: contact.directId, kind: .receipt, payload: envelope.encode(), nextAttemptAt: now, expiresAt: envelope.expiresAt))
    }

    private func rewind(_ payload: String) -> String {
        if FeedNotes.isJob(payload) { return FeedNotes.rewind(payload) }
        return MediaNotes.rewind(payload)
    }

    private func enqueueFeed(_ item: FeedItem, _ targets: [ContactRecord]? = nil) {
        guard let directory = mediaDirectory else { return }
        let file = directory.appendingPathComponent(item.mediaFile)
        guard let bytes = try? Data(contentsOf: file), !bytes.isEmpty else { return }
        let now = clock()
        let parts = MediaNotes.split(bytes, chunkBytes: mediaChunkBytes).count
        let job = FeedNotes.Job(
            id: item.id, channel: item.channel, kind: item.kind, mime: item.mime, name: item.name,
            caption: item.caption, createdAt: item.createdAt, expiresAt: item.expiresAt,
            parts: parts, nextPart: 0, fileName: item.mediaFile
        )
        let contacts = targets ?? store.contacts().filter { $0.accepted && !$0.blocked }
        for contact in contacts {
            store.putQueued(QueueItem(
                id: Encoding.newId("fed"), peerId: contact.directId, kind: .receipt, payload: FeedNotes.encodeJob(job),
                nextAttemptAt: now, expiresAt: now + ttlMs, messageId: item.id
            ))
        }
    }

    /// Writes every remaining chunk. The message stays queued until the last chunk is on the channel.
    private func sendMediaChunks(_ item: QueueItem) async throws {
        guard let initial = MediaNotes.parseJob(item.payload),
              let (keys, deviceId) = identity(),
              let contact = store.contact(item.peerId)
        else { return }
        let logicalId = item.logicalId()
        guard let directory = mediaDirectory else { return }
        let file = directory.appendingPathComponent(initial.fileName)
        guard let bytes = try? Data(contentsOf: file), !bytes.isEmpty else {
            store.removeQueued(item.id)
            let others = store.queue().contains { $0.logicalId() == logicalId && $0.kind == .message }
            if !others { transition(logicalId, .expired, "The attachment is no longer on this phone.") }
            return
        }
        let groupId: String? = {
            guard let threadId = store.message(logicalId)?.peerId, GroupNotes.isGroupId(threadId) else { return nil }
            return threadId
        }()
        let parts = MediaNotes.split(bytes, chunkBytes: mediaChunkBytes)
        var part = min(max(initial.nextPart, 0), parts.count)
        var job = initial
        while part < parts.count {
            let plain = MediaNotes.encodePart(
                MediaNotes.Part(mediaId: logicalId, kind: job.kind, mime: job.mime, name: job.name, part: part, parts: parts.count, caption: job.caption, groupId: groupId),
                parts[part]
            )
            let envelope = try Envelopes.seal(
                sender: keys, deviceId: deviceId, recipientId: item.peerId, recipientAgreementPublic: try bundleFor(contact).agreementPublic,
                id: "\(item.id).\(part)", type: .message, plaintext: plain, createdAt: clock(), ttlMs: ttlMs
            )
            if await links.send(item.peerId, Encoding.utf8(envelope.encode())) == false {
                guard var latest = store.queued(item.id) else { return }
                job.nextPart = part
                latest.payload = MediaNotes.encodeJob(job)
                latest.nextAttemptAt = clock() + Backoff.delayMs(attempt: latest.attempts, random: random)
                latest.lastError = "Channel closed before the write"
                store.putQueued(latest)
                if var message = store.message(logicalId) {
                    message.lastError = "Channel closed before the write"
                    message.updatedAt = clock()
                    store.putMessage(message)
                }
                return
            }
            part += 1
            job.nextPart = part
            if var latest = store.queued(item.id) {
                latest.payload = MediaNotes.encodeJob(job)
                latest.lastError = nil
                store.putQueued(latest)
            }
        }
        transition(logicalId, .attempt, nil)
        transition(logicalId, .written, nil)
        if var latest = store.queued(item.id) {
            latest.sentAt = clock()
            latest.lastError = nil
            latest.payload = MediaNotes.encodeJob(job)
            store.putQueued(latest)
        }
    }

    private func sendFeedChunks(_ item: QueueItem) async throws {
        guard let initial = FeedNotes.parseJob(item.payload),
              let (keys, deviceId) = identity(),
              let contact = store.contact(item.peerId),
              let directory = mediaDirectory
        else { return }
        let file = directory.appendingPathComponent(initial.fileName)
        guard let bytes = try? Data(contentsOf: file), !bytes.isEmpty else {
            store.removeQueued(item.id)
            return
        }
        let parts = MediaNotes.split(bytes, chunkBytes: mediaChunkBytes)
        var part = min(max(initial.nextPart, 0), parts.count)
        var job = initial
        while part < parts.count {
            let plain = FeedNotes.encodePart(
                FeedNotes.Part(
                    id: job.id, channel: job.channel, kind: job.kind, mime: job.mime, name: job.name,
                    caption: job.caption, createdAt: job.createdAt, expiresAt: job.expiresAt,
                    part: part, parts: parts.count
                ),
                parts[part]
            )
            let envelope = try Envelopes.seal(
                sender: keys, deviceId: deviceId, recipientId: item.peerId, recipientAgreementPublic: try bundleFor(contact).agreementPublic,
                id: "\(item.id).\(part)", type: .feed, plaintext: plain, createdAt: clock(), ttlMs: ttlMs
            )
            if await links.send(item.peerId, Encoding.utf8(envelope.encode())) == false {
                guard var latest = store.queued(item.id) else { return }
                job.nextPart = part
                latest.payload = FeedNotes.encodeJob(job)
                latest.nextAttemptAt = clock() + Backoff.delayMs(attempt: latest.attempts, random: random)
                latest.lastError = "Channel closed before the write"
                store.putQueued(latest)
                return
            }
            part += 1
            job.nextPart = part
            if var latest = store.queued(item.id) {
                latest.payload = FeedNotes.encodeJob(job)
                latest.lastError = nil
                store.putQueued(latest)
            }
        }
        store.removeQueued(item.id)
    }

    private func ingestFeed(_ peerId: String, _ opened: Data, _ plaintext: String) throws -> ReceiveOutcome {
        guard let directory = mediaDirectory else { return .ignored }
        store.pruneFeed(clock())
        guard let (header, chunk) = FeedNotes.decodePart(opened) else {
            guard let deleted = FeedNotes.decodeDelete(plaintext) else { return .ignored }
            guard let existing = store.feed(deleted.id) else { return .duplicate }
            guard existing.ownerId == peerId else { return .ignored }
            store.removeFeed(deleted.id)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(existing.mediaFile))
            try store.save()
            return .stored
        }
        let partsDir = directory.appendingPathComponent("parts").appendingPathComponent("feed").appendingPathComponent(header.id)
        try FileManager.default.createDirectory(at: partsDir, withIntermediateDirectories: true)
        try chunk.write(to: partsDir.appendingPathComponent(String(header.part)))
        let complete = (0..<header.parts).allSatisfy { FileManager.default.fileExists(atPath: partsDir.appendingPathComponent(String($0)).path) }
        if !complete {
            try store.save()
            return .stored
        }
        var assembled = Data()
        for index in 0..<header.parts {
            assembled.append(try Data(contentsOf: partsDir.appendingPathComponent(String(index))))
        }
        let fileName = "\(header.id).bin"
        try assembled.write(to: directory.appendingPathComponent(fileName))
        try? FileManager.default.removeItem(at: partsDir)
        let already = store.feed(header.id)?.mediaFile != nil
        let seen = already && store.feed(header.id)?.seen == true
        store.putFeed(FeedItem(
            id: header.id, ownerId: peerId, channel: header.channel, kind: header.kind, mime: header.mime, name: header.name,
            caption: header.caption, createdAt: header.createdAt, expiresAt: header.expiresAt, mediaFile: fileName, seen: seen
        ))
        try store.save()
        return already ? .duplicate : .stored
    }

    private func ingestMedia(_ peerId: String, _ contact: ContactRecord, _ header: MediaNotes.Part, _ chunk: Data, _ createdAt: Int64) throws -> ReceiveOutcome {
        guard let directory = mediaDirectory else { return .ignored }
        let selfId = identity()?.0.directId
        let groupId = header.groupId
        if let groupId, let group = store.group(groupId) {
            let selfOk = selfId.map { group.members.contains($0) } ?? false
            if !group.members.contains(peerId) || !selfOk { return .ignored }
        }
        let threadId = groupId ?? peerId
        let senderId = groupId == nil ? nil : peerId
        let partsDir = directory.appendingPathComponent("parts").appendingPathComponent(header.mediaId)
        try FileManager.default.createDirectory(at: partsDir, withIntermediateDirectories: true)
        try chunk.write(to: partsDir.appendingPathComponent(String(header.part)))
        let have = (0..<header.parts).filter { FileManager.default.fileExists(atPath: partsDir.appendingPathComponent(String($0)).path) }.count
        let label = MediaNotes.label(header.kind) ?? "Attachment"
        if have < header.parts {
            let body = "Receiving \(label) (\(have)/\(header.parts))"
            if var existing = store.message(header.mediaId) {
                existing.body = body
                existing.updatedAt = clock()
                store.putMessage(existing)
            } else {
                store.putMessage(MessageRecord(
                    id: header.mediaId, peerId: threadId, direction: .incoming, body: body, createdAt: createdAt,
                    mediaKind: header.kind, mediaMime: header.mime, mediaName: header.name, senderId: senderId
                ))
            }
            try store.save()
            return .stored
        }
        var assembled = Data()
        for index in 0..<header.parts {
            assembled.append(try Data(contentsOf: partsDir.appendingPathComponent(String(index))))
        }
        let fileName = "\(header.mediaId).bin"
        try assembled.write(to: directory.appendingPathComponent(fileName))
        try? FileManager.default.removeItem(at: partsDir)
        let already = store.message(header.mediaId)?.mediaFile != nil
        let caption = header.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? label : header.caption
        let stored = MessageRecord(
            id: header.mediaId, peerId: threadId, direction: .incoming, body: caption, createdAt: createdAt,
            mediaKind: header.kind, mediaMime: header.mime, mediaName: header.name, mediaFile: fileName, senderId: senderId
        )
        store.putMessage(stored)
        try queueReceipt(contact, .ack, header.mediaId)
        try store.save()
        if !already { onInbound?(stored) }
        return already ? .duplicate : .stored
    }

    private func ingestInvite(_ peerId: String, _ plaintext: String, _ createdAt: Int64) throws -> ReceiveOutcome {
        guard let note = GroupNotes.parse(plaintext), note.op == "invite",
              let selfId = identity()?.0.directId,
              note.members.contains(selfId), note.members.contains(peerId),
              let name = note.name
        else { return .ignored }
        let existing = store.group(note.groupId)
        let group = GroupRecord(
            id: note.groupId,
            name: name,
            members: note.members,
            createdBy: existing?.createdBy ?? peerId,
            createdAt: existing?.createdAt ?? createdAt
        )
        store.putGroup(group)
        if existing == nil {
            let stored = MessageRecord(
                id: Encoding.newId("sys"),
                peerId: group.id,
                direction: .incoming,
                body: "\(store.contact(peerId)?.name ?? peerId) added you to \(group.name)",
                createdAt: createdAt,
                mediaKind: "group",
                senderId: peerId
            )
            store.putMessage(stored)
            onInbound?(stored)
        }
        try store.save()
        return .stored
    }

    private func ingestGroupText(_ peerId: String, _ contact: ContactRecord, _ note: GroupNotes.Note, _ createdAt: Int64) throws -> ReceiveOutcome {
        guard note.op == "text", let mid = note.mid, let body = note.body,
              let group = store.group(note.groupId), group.members.contains(peerId)
        else { return .ignored }
        if store.message(mid) != nil {
            try queueReceipt(contact, .ack, mid)
            try store.save()
            return .duplicate
        }
        let stored = MessageRecord(id: mid, peerId: group.id, direction: .incoming, body: body, createdAt: createdAt, senderId: peerId)
        store.putMessage(stored)
        try queueReceipt(contact, .ack, mid)
        try store.save()
        onInbound?(stored)
        return .stored
    }

    private func bundleFor(_ contact: ContactRecord) throws -> PublicBundle {
        if let cached = bundles[contact.bundle] { return cached }
        let parsed = try Bundles.parse(contact.bundle)
        bundles[contact.bundle] = parsed
        return parsed
    }
}

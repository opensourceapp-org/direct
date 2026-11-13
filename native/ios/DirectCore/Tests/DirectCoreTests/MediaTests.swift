import XCTest
@testable import DirectCore

final class MediaTests: XCTestCase {
    private final class Links: PeerLinks {
        var reachable = true
        var sent: [Data] = []
        func isConnected(_ peerId: String) -> Bool { reachable }
        func connect(_ peerId: String) async -> Bool { reachable }
        func send(_ peerId: String, _ payload: Data) async -> Bool {
            guard reachable else { return false }
            sent.append(payload)
            return true
        }
    }

    private final class Clock {
        var now: Int64 = 1_000
    }

    @DirectActor
    private final class Device {
        let keys = IdentityKeys.generate()
        let deviceId = Encoding.newDeviceId()
        let bundle: PublicBundle
        let store = LocalStore.inMemory()
        let media: URL
        let engine: DeliveryEngine

        init(_ name: String, _ clock: Clock, _ links: PeerLinks, chunk: Int) {
            bundle = try! Bundles.create(keys: keys, displayName: name, deviceId: deviceId)
            media = FileManager.default.temporaryDirectory.appendingPathComponent("direct-media-\(name)-\(UUID().uuidString)", isDirectory: true)
            let keys = self.keys
            let deviceId = self.deviceId
            engine = DeliveryEngine(
                store: store, identity: { (keys, deviceId) }, links: links,
                clock: { clock.now }, random: { 0 }, ttlMs: 60_000, receiptTimeoutMs: 5_000,
                mediaDirectory: media, mediaChunkBytes: chunk
            )
        }

        func know(_ other: Device) {
            store.putContact(ContactRecord(
                directId: other.keys.directId, name: other.bundle.name, bundle: other.bundle.encode(),
                fingerprint: other.bundle.fingerprint, createdAt: 0
            ))
        }
    }

    func testAMediaNoteRoundtripsAndAProfileCardKeepsTheBundle() {
        let bytes = Data([1, 2, 3, 9, 0xFF])
        let part = MediaNotes.Part(mediaId: "med_1", kind: "image", mime: "image/jpeg", name: "a.jpg", part: 0, parts: 2, caption: "see you")
        let encoded = MediaNotes.encodePart(part, bytes)
        let decoded = MediaNotes.decodePart(encoded)
        XCTAssertEqual(part, decoded?.0)
        XCTAssertEqual(bytes, decoded?.1)
        XCTAssertNil(MediaNotes.decodePart(Encoding.utf8("hello")))
        XCTAssertEqual([3, 3, 2], MediaNotes.split(Data(repeating: 0, count: 8), chunkBytes: 3).map(\.count))

        let bundle = #"{"v":1,"name":"Ada","directId":"dir_X"}"#
        let card = ProfileCards.encode(bundle: bundle, status: "In the garden", avatarJpeg: Data([0xFF, 0xD8, 1]), bootstrap: "ws://192.168.1.20:8787")
        let parsed = ProfileCards.parse(card)
        XCTAssertEqual(bundle, parsed.bundle)
        XCTAssertEqual("In the garden", parsed.status)
        XCTAssertEqual(3, parsed.avatarJpeg?.count)
        XCTAssertEqual("ws://192.168.1.20:8787", parsed.bootstrap)
        XCTAssertEqual("", ProfileCards.parse(ProfileCards.encode(bundle: bundle, status: "In the garden", avatarJpeg: nil)).bootstrap)
        XCTAssertEqual(bundle, ProfileCards.parse(bundle).bundle)
        XCTAssertEqual("", ProfileCards.parse(bundle).bootstrap)

        let groupId = "grp_" + String(repeating: "ab", count: 16)
        let grouped = MediaNotes.Part(mediaId: "med_1", kind: "image", mime: "image/jpeg", name: "a.jpg", part: 0, parts: 2, caption: "see you", groupId: groupId)
        let opened = MediaNotes.decodePart(MediaNotes.encodePart(grouped, bytes))
        XCTAssertEqual(grouped, opened?.0)
        XCTAssertEqual(groupId, opened?.0.groupId)
    }

    func testAnOlderSnapshotStillOpens() throws {
        let json = """
        {"version":1,"profile":{"name":"Ada","deviceId":"dev","directId":"dir_X"},"settings":{},"contacts":[{"directId":"dir_Y","name":"Bo","bundle":"b","fingerprint":"f","createdAt":1}],"messages":[{"id":"m","peerId":"dir_Y","direction":"OUTGOING","body":"hi","createdAt":1,"state":"QUEUED","updatedAt":1}],"queue":[]}
        """
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
        XCTAssertEqual("", snapshot.profile?.status)
        XCTAssertNil(snapshot.profile?.avatarJpegBase64)
        XCTAssertEqual("", snapshot.contacts.first?.about)
        XCTAssertNil(snapshot.messages.first?.mediaKind)
    }

    @DirectActor
    func testChunksAreSealedToThePeerAndReassembledOnce() async throws {
        let clock = Clock()
        let adaLinks = Links()
        let boLinks = Links()
        let ada = Device("Ada", clock, adaLinks, chunk: 4)
        let bo = Device("Bo", clock, boLinks, chunk: 4)
        ada.know(bo)
        bo.know(ada)
        let payload = Data([10, 11, 12, 13, 14, 15, 16])
        let message = try ada.engine.queueMedia(bo.keys.directId, kind: "image", mime: "image/jpeg", name: "pic.jpg", bytes: payload, caption: "sunset")
        XCTAssertEqual(.queued, ada.store.message(message.id)?.state)

        adaLinks.reachable = false
        try await ada.engine.flush()
        XCTAssertEqual(.queued, ada.store.message(message.id)?.state)
        XCTAssertEqual("Recipient unavailable", ada.store.message(message.id)?.lastError)
        XCTAssertTrue(adaLinks.sent.isEmpty)

        adaLinks.reachable = true
        clock.now += 1_000
        try await ada.engine.flush()
        XCTAssertEqual(.sent, ada.store.message(message.id)?.state)
        XCTAssertEqual(2, adaLinks.sent.count, "7 bytes at 4 per chunk")
        XCTAssertFalse(adaLinks.sent.contains { String(decoding: $0, as: UTF8.self).contains("sunset") })

        XCTAssertEqual(.stored, try bo.engine.receive(ada.keys.directId, adaLinks.sent[0]))
        XCTAssertNil(bo.store.message(message.id)?.mediaFile)
        XCTAssertEqual(.stored, try bo.engine.receive(ada.keys.directId, adaLinks.sent[1]))
        let file = try Data(contentsOf: bo.media.appendingPathComponent("\(message.id).bin"))
        XCTAssertEqual(payload, file)
        XCTAssertEqual("sunset", bo.store.message(message.id)?.body)
        try await bo.engine.flush()
        XCTAssertEqual(.receipt, try ada.engine.receive(bo.keys.directId, boLinks.sent.last!))
        XCTAssertEqual(.accepted, ada.store.message(message.id)?.state)
        XCTAssertFalse(bo.store.queue().contains { $0.id == message.id && MediaNotes.isJob($0.payload) })
    }

    @DirectActor
    func testAGroupPhotoIsSealedToEachMemberAndStoredOnTheGroupThread() async throws {
        let clock = Clock()
        let adaLinks = Links()
        let boLinks = Links()
        let ada = Device("Ada", clock, adaLinks, chunk: 8)
        let bo = Device("Bo", clock, boLinks, chunk: 8)
        ada.know(bo)
        bo.know(ada)
        let members = [ada.keys.directId, bo.keys.directId]
        let group = GroupRecord(id: "grp_" + String(repeating: "cd", count: 16), name: "Weekend", members: members, createdBy: ada.keys.directId, createdAt: clock.now)
        ada.store.putGroup(group)
        bo.store.putGroup(group)
        let payload = Data([1, 2, 3, 4, 5])
        let message = try ada.engine.queueGroupMedia(group, ada.keys.directId, kind: "image", mime: "image/jpeg", name: "pic.jpg", bytes: payload, caption: "pool")
        XCTAssertEqual(1, ada.store.queue().filter { $0.messageId == message.id }.count)
        try await ada.engine.flush()
        XCTAssertEqual(.sent, ada.store.message(message.id)?.state)
        XCTAssertFalse(adaLinks.sent.isEmpty)
        for bytes in adaLinks.sent {
            _ = try bo.engine.receive(ada.keys.directId, bytes)
        }
        let received = try XCTUnwrap(bo.store.messagesWith(group.id).first { $0.id == message.id })
        XCTAssertEqual(ada.keys.directId, received.senderId)
        XCTAssertEqual("pool", received.body)
        XCTAssertEqual("image", received.mediaKind)
        let file = try Data(contentsOf: bo.media.appendingPathComponent("\(message.id).bin"))
        XCTAssertEqual(payload, file)
        try await bo.engine.flush()
        XCTAssertEqual(.receipt, try ada.engine.receive(bo.keys.directId, boLinks.sent.last!))
        XCTAssertEqual(.accepted, ada.store.message(message.id)?.state)
        XCTAssertFalse(ada.store.queue().contains { $0.logicalId() == message.id })
    }

    @DirectActor
    func testAStoryIsSealedToAContactAndExpiresAfterADay() async throws {
        let clock = Clock()
        let adaLinks = Links()
        let boLinks = Links()
        let ada = Device("Ada", clock, adaLinks, chunk: 4)
        let bo = Device("Bo", clock, boLinks, chunk: 4)
        ada.know(bo)
        bo.know(ada)
        let payload = Data([10, 11, 12, 13, 14])
        let story = try ada.engine.queueFeed(channel: FeedNotes.story, kind: "image", mime: "image/jpeg", name: "story.jpg", bytes: payload, caption: "hi")
        XCTAssertEqual(FeedNotes.story, ada.store.feed(story.id)?.channel)
        XCTAssertEqual(clock.now + FeedNotes.storyTtlMs, ada.store.feed(story.id)?.expiresAt)
        try await ada.engine.flush()
        XCTAssertFalse(adaLinks.sent.isEmpty)
        for bytes in adaLinks.sent {
            _ = try bo.engine.receive(ada.keys.directId, bytes)
        }
        let received = try XCTUnwrap(bo.store.feed(story.id))
        XCTAssertEqual(ada.keys.directId, received.ownerId)
        XCTAssertEqual("hi", received.caption)
        XCTAssertEqual(payload, try Data(contentsOf: bo.media.appendingPathComponent("\(story.id).bin")))
        XCTAssertFalse(received.seen)
        try bo.engine.markFeedSeen(ada.keys.directId)
        XCTAssertEqual(true, bo.store.feed(story.id)?.seen)
        clock.now += FeedNotes.storyTtlMs + 1
        XCTAssertEqual(1, bo.store.pruneFeed(clock.now).count)
        XCTAssertNil(bo.store.feed(story.id))
    }

    @DirectActor
    func testAProfilePostReachesTheOtherPhoneAndDeleteRemovesIt() async throws {
        let clock = Clock()
        let adaLinks = Links()
        let boLinks = Links()
        let ada = Device("Ada", clock, adaLinks, chunk: 8)
        let bo = Device("Bo", clock, boLinks, chunk: 8)
        ada.know(bo)
        bo.know(ada)
        let payload = Data([1, 2, 3, 4, 5])
        let post = try ada.engine.queueFeed(channel: FeedNotes.post, kind: "image", mime: "image/jpeg", name: "pic.jpg", bytes: payload, caption: "")
        try await ada.engine.flush()
        for bytes in adaLinks.sent { _ = try bo.engine.receive(ada.keys.directId, bytes) }
        XCTAssertEqual(FeedNotes.post, bo.store.feed(post.id)?.channel)
        XCTAssertNil(bo.store.feed(post.id)?.expiresAt)
        adaLinks.sent.removeAll()
        try ada.engine.deleteFeed(post.id)
        XCTAssertNil(ada.store.feed(post.id))
        try await ada.engine.flush()
        XCTAssertFalse(adaLinks.sent.isEmpty)
        for bytes in adaLinks.sent { _ = try bo.engine.receive(ada.keys.directId, bytes) }
        XCTAssertNil(bo.store.feed(post.id))
    }

    @DirectActor
    func testALikeAndACommentOnAPostReachTheOtherPhone() async throws {
        let like = try XCTUnwrap(FeedNotes.decodeSocial(FeedNotes.encodeLike(id: "fed_abc")))
        XCTAssertEqual("like", like.op)
        XCTAssertEqual("fed_abc", like.id)
        let encoded = FeedNotes.encodeComment(id: "fed_abc", commentId: "cmt_1", body: "nice shot", createdAt: 42)
        let note = try XCTUnwrap(FeedNotes.decodeSocial(encoded))
        XCTAssertEqual("comment", note.op)
        XCTAssertEqual("nice shot", note.body)
        XCTAssertEqual("cmt_1", note.commentId)
        XCTAssertEqual(42, note.createdAt)
        XCTAssertNil(FeedNotes.decodeSocial(FeedNotes.encodeDelete(channel: FeedNotes.post, id: "fed_abc")))
        XCTAssertNil(FeedNotes.decodeDelete(encoded))

        let clock = Clock()
        let adaLinks = Links()
        let boLinks = Links()
        let ada = Device("Ada", clock, adaLinks, chunk: 8)
        let bo = Device("Bo", clock, boLinks, chunk: 8)
        ada.know(bo)
        bo.know(ada)
        let post = try ada.engine.queueFeed(channel: FeedNotes.post, kind: "image", mime: "image/jpeg", name: "pic.jpg", bytes: Data([1, 2, 3, 4, 5]), caption: "lake")
        try await ada.engine.flush()
        for bytes in adaLinks.sent { _ = try bo.engine.receive(ada.keys.directId, bytes) }
        XCTAssertEqual("lake", bo.store.feed(post.id)?.caption)

        adaLinks.sent.removeAll()
        boLinks.sent.removeAll()
        try bo.engine.likeFeed(post.id)
        XCTAssertEqual([bo.keys.directId], bo.store.feed(post.id)?.likes.map(\.fromId))
        try await bo.engine.flush()
        XCTAssertFalse(boLinks.sent.isEmpty)
        for bytes in boLinks.sent { _ = try ada.engine.receive(bo.keys.directId, bytes) }
        XCTAssertEqual([bo.keys.directId], ada.store.feed(post.id)?.likes.map(\.fromId))

        boLinks.sent.removeAll()
        try bo.engine.likeFeed(post.id)
        XCTAssertTrue(bo.store.feed(post.id)?.likes.isEmpty == true)
        try await bo.engine.flush()
        for bytes in boLinks.sent { _ = try ada.engine.receive(bo.keys.directId, bytes) }
        XCTAssertTrue(ada.store.feed(post.id)?.likes.isEmpty == true)

        boLinks.sent.removeAll()
        try bo.engine.commentFeed(post.id, "  looks great  ")
        let local = try XCTUnwrap(bo.store.feed(post.id)?.comments.first)
        XCTAssertEqual(bo.keys.directId, local.fromId)
        XCTAssertEqual("looks great", local.body)
        try await bo.engine.flush()
        for bytes in boLinks.sent { _ = try ada.engine.receive(bo.keys.directId, bytes) }
        let remote = try XCTUnwrap(ada.store.feed(post.id)?.comments.first)
        XCTAssertEqual(local.id, remote.id)
        XCTAssertEqual("looks great", remote.body)
        XCTAssertEqual(bo.keys.directId, remote.fromId)

        boLinks.sent.removeAll()
        try bo.engine.reactFeed(post.id, "🔥")
        XCTAssertEqual("🔥", bo.store.feed(post.id)?.likes.first?.emoji)
        try await bo.engine.flush()
        for bytes in boLinks.sent { _ = try ada.engine.receive(bo.keys.directId, bytes) }
        XCTAssertEqual("🔥", ada.store.feed(post.id)?.likes.first?.emoji)

        let fire = try XCTUnwrap(FeedNotes.decodeSocial(FeedNotes.encodeReact(id: "fed_abc", emoji: "🔥")))
        XCTAssertEqual("react", fire.op)
        XCTAssertEqual("🔥", fire.body)
        XCTAssertNil(FeedNotes.decodeSocial(FeedNotes.encodeReact(id: "fed_abc", emoji: "not-an-emoji")))

        adaLinks.sent.removeAll()
        boLinks.sent.removeAll()
        let forwarded = try bo.engine.forwardFeed(post.id, to: ada.keys.directId)
        XCTAssertEqual(true, forwarded.forwarded)
        XCTAssertEqual("lake", forwarded.body)
        XCTAssertEqual("image", forwarded.mediaKind)
        XCTAssertEqual(ada.keys.directId, forwarded.peerId)
        try await bo.engine.flush()
        XCTAssertFalse(boLinks.sent.isEmpty)
        for bytes in boLinks.sent { _ = try ada.engine.receive(bo.keys.directId, bytes) }
        let copy = try XCTUnwrap(ada.store.message(forwarded.id))
        XCTAssertEqual("lake", copy.body)
        XCTAssertEqual("image", copy.mediaKind)
    }
}
